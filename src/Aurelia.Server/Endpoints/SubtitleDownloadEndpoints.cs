using Aurelia.Contracts;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

/// <summary>
/// Subtitle downloads: the owner sets them up; administrators search, download and remove
/// subtitles for a title. Players find downloaded subtitles in the stream's subtitle list.
/// </summary>
public static class SubtitleDownloadEndpoints
{
    public static void MapSubtitleDownloads(this WebApplication app)
    {
        var settings = app.MapGroup("/api/v1/metadata/subtitles").RequireAuthorization("Administrator");
        settings.MapGet(string.Empty, (SubtitleDownloadService service) => Run(() => Task.FromResult(service.Status())));
        settings.MapPut(string.Empty, (UpdateSubtitleProviderRequest request, SubtitleDownloadService service) =>
            Run(() => Task.FromResult(service.Configure(request)))).RequireAuthorization("Owner");
        settings.MapDelete("/key", (SubtitleDownloadService service) => Run(() => Task.FromResult(service.RemoveKey()))).RequireAuthorization("Owner");
        settings.MapDelete("/account", (SubtitleDownloadService service) => Run(() => Task.FromResult(service.RemoveAccount()))).RequireAuthorization("Owner");

        var media = app.MapGroup("/api/v1/media/{mediaId:guid}/subtitles").RequireAuthorization("Administrator");
        media.MapGet(string.Empty, (Guid mediaId, SubtitleDownloadService service, CancellationToken token) =>
            Run(() => service.ListAsync(mediaId, token)));
        media.MapGet("/search", (Guid mediaId, string? language, SubtitleDownloadService service, CancellationToken token) =>
            Run(() => service.SearchAsync(mediaId, language, token)));
        media.MapPost(string.Empty, (Guid mediaId, DownloadSubtitleRequest request, SubtitleDownloadService service, CancellationToken token) =>
            Run(() => service.DownloadAsync(mediaId, request, token)));
        media.MapDelete("/{subtitleId:guid}", async (Guid mediaId, Guid subtitleId, SubtitleDownloadService service, CancellationToken token) =>
        {
            try
            {
                await service.RemoveAsync(mediaId, subtitleId, token);
                return Results.NoContent();
            }
            catch (MetadataException exception)
            {
                return Results.Json(new ApiProblem(exception.Code, exception.Message), statusCode: exception.StatusCode);
            }
        });
    }

    private static async Task<IResult> Run<T>(Func<Task<T>> action)
    {
        try
        {
            return Results.Ok(await action());
        }
        catch (MetadataException exception)
        {
            return Results.Json(new ApiProblem(exception.Code, exception.Message), statusCode: exception.StatusCode);
        }
    }
}
