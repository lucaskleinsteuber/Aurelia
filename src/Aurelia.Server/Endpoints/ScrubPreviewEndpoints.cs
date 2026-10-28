using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using EntityTagHeaderValue = Microsoft.Net.Http.Headers.EntityTagHeaderValue;

namespace Aurelia.Server.Endpoints;

public static class ScrubPreviewEndpoints
{
    private const int LongestTitleSeconds = 48 * 3600;

    public static void MapScrubPreviews(this WebApplication app)
    {
        var server = app.MapGroup("/api/v1/server").RequireAuthorization("Owner");
        server.MapGet("/scrub-previews", (ScrubPreviewService scrubPreviews) => scrubPreviews.ReadSettingsAsync());
        server.MapPut("/scrub-previews", (UpdateScrubPreviewSettingsRequest request, ScrubPreviewService scrubPreviews, CancellationToken token) =>
            scrubPreviews.UpdateSettingsAsync(request, token));
        server.MapDelete("/scrub-previews", (ScrubPreviewService scrubPreviews) => scrubPreviews.DeleteAllPreviewsAsync());

        var media = app.MapGroup("/api/v1/media/{mediaId:guid}/scrub-previews").RequireAuthorization();
        media.MapGet(string.Empty, GetManifestAsync);
        media.MapMethods("/{seconds:int}", [HttpMethods.Get, HttpMethods.Head], GetFrameAsync)
            .WithDisplayName("Scrub preview frame");
    }

    private static async Task<IResult> GetManifestAsync(
        HttpContext context,
        Guid mediaId,
        AureliaDbContext database,
        ScrubPreviewService scrubPreviews,
        CancellationToken cancellationToken)
    {
        var media = await database.MediaItems
            .AsNoTracking()
            .Include(candidate => candidate.LibraryRoot)
            .SingleOrDefaultAsync(candidate => candidate.Id == mediaId, cancellationToken);
        if (media is null)
            return Problem("media_not_found", "The media item was not found.", StatusCodes.Status404NotFound);
        if (media.Kind == MediaKind.Series)
            return Problem("media_not_playable", "This media item is a container and has no scrub previews.", StatusCodes.Status409Conflict);

        var manifest = await scrubPreviews.GetManifestAsync(media, cancellationToken);
        context.Response.Headers.CacheControl = "private, no-cache";
        var entityTag = new EntityTagHeaderValue($"\"spm-{mediaId:N}-{manifest.Revision}\"");
        if (IsUnchanged(context, entityTag))
        {
            context.Response.Headers.ETag = entityTag.ToString();
            return Results.StatusCode(StatusCodes.Status304NotModified);
        }

        context.Response.Headers.ETag = entityTag.ToString();
        return Results.Ok(manifest);
    }

    private static async Task<IResult> GetFrameAsync(
        HttpContext context,
        Guid mediaId,
        int seconds,
        AureliaDbContext database,
        ScrubPreviewService scrubPreviews,
        CancellationToken cancellationToken)
    {
        if (seconds is < 0 or > LongestTitleSeconds)
            return Problem("invalid_preview_seconds", "The preview timestamp is outside the supported range.", StatusCodes.Status400BadRequest);

        var media = await database.MediaItems
            .AsNoTracking()
            .Include(candidate => candidate.LibraryRoot)
            .SingleOrDefaultAsync(candidate => candidate.Id == mediaId, cancellationToken);
        if (media is null)
            return Problem("media_not_found", "The media item was not found.", StatusCodes.Status404NotFound);
        if (media.Kind == MediaKind.Series)
            return Problem("media_not_playable", "This media item is a container and has no scrub previews.", StatusCodes.Status409Conflict);

        try
        {
            var frame = await scrubPreviews.GetFrameAsync(media, seconds, cancellationToken);
            if (frame is null)
                return Problem("scrub_preview_unavailable", "Scrub preview images are not available for this title right now.", StatusCodes.Status503ServiceUnavailable);

            context.Response.Headers.CacheControl = "private, max-age=86400";
            context.Response.Headers.XContentTypeOptions = "nosniff";
            var entityTag = new EntityTagHeaderValue(frame.EntityTag);
            if (IsUnchanged(context, entityTag))
            {
                context.Response.Headers.ETag = entityTag.ToString();
                return Results.StatusCode(StatusCodes.Status304NotModified);
            }

            return Results.Bytes(
                frame.Data,
                contentType: "image/jpeg",
                lastModified: frame.LastModified,
                entityTag: entityTag);
        }
        catch (PlaybackException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }

    private static bool IsUnchanged(HttpContext context, EntityTagHeaderValue entityTag) =>
        context.Request.GetTypedHeaders().IfNoneMatch is { Count: > 0 } candidates
        && candidates.Any(candidate => candidate.Equals(EntityTagHeaderValue.Any) || candidate.Compare(entityTag, useStrongComparison: false));

    private static IResult Problem(string code, string message, int statusCode) =>
        Results.Json(new ApiProblem(code, message), statusCode: statusCode);
}
