using Aurelia.Contracts;
using Aurelia.Server.Services.FileChecks;

namespace Aurelia.Server.Endpoints;

/// <summary>
/// The file watch ("file-checks-v1", docs/CLIENT_PROTOCOL.md): the owner turns it on and chooses
/// how thoroughly files are examined; administrators see the problems and the drives' health in
/// Library Health and examine a title again or set its problem aside.
/// </summary>
public static class FileCheckEndpoints
{
    public static void MapFileChecks(this WebApplication app)
    {
        var server = app.MapGroup("/api/v1/server/file-checks").RequireAuthorization("Owner");
        server.MapGet(string.Empty, (FileCheckService checks, CancellationToken token) => checks.ReadSettingsAsync(token));
        server.MapPut(string.Empty, (UpdateFileCheckSettingsRequest request, FileCheckService checks, CancellationToken token) =>
            checks.UpdateSettingsAsync(request, token));

        var health = app.MapGroup("/api/v1/library/health").RequireAuthorization("Administrator");
        health.MapGet("/files", async (HttpContext context, bool? ignored, int? offset, int? limit, FileCheckService checks, CancellationToken token) =>
        {
            var (items, total) = await checks.ProblemsPageAsync(ignored ?? false, offset ?? 0, limit ?? 50, token);
            context.Response.Headers["X-Total-Count"] = total.ToString(System.Globalization.CultureInfo.InvariantCulture);
            return items;
        });
        health.MapPost("/files/{mediaId:guid}/recheck", (Guid mediaId, FileCheckService checks, CancellationToken token) =>
            RunNoContent(() => checks.RecheckAsync(mediaId, token)));
        health.MapPost("/files/{mediaId:guid}/ignore", (Guid mediaId, FileCheckService checks, CancellationToken token) =>
            RunNoContent(() => checks.SetIgnoredAsync(mediaId, true, token)));
        health.MapDelete("/files/{mediaId:guid}/ignore", (Guid mediaId, FileCheckService checks, CancellationToken token) =>
            RunNoContent(() => checks.SetIgnoredAsync(mediaId, false, token)));
        health.MapGet("/drives", (DriveHealthService drives, CancellationToken token) => drives.ReadAsync(token));
        health.MapPost("/drives/refresh", (DriveHealthService drives, CancellationToken token) => drives.RefreshAsync(token));
    }

    private static async Task<IResult> RunNoContent(Func<Task> action)
    {
        await action();
        return Results.NoContent();
    }
}
