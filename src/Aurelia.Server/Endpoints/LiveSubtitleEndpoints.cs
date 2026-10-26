using Aurelia.Server.Authentication;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

public static partial class LiveConversionEndpoints
{
    private static async Task<IResult> SubtitlesAsync(
        HttpContext context,
        string ticket,
        int index,
        PlaybackService playback,
        LiveConversionService live,
        CatalogMutationGate mutations,
        CancellationToken cancellationToken)
    {
        if (await live.ToolsAsync() is not { } tools) return Unavailable();
        try
        {
            PlaybackStreamSource? source;
            using (await mutations.EnterAsync(cancellationToken))
            {
                source = await playback.OpenStreamAsync(ticket, context.User.RequireUserId(), context.User.RequireSessionId(),
                    cancellationToken, context.User.RequireProfileSessionId());
            }
            if (source is null) return Results.NotFound();
            await using var stream = source.Stream;
            (context.Items["Aurelia.StreamLease"] as ActiveStreamRegistry.Lease)?.BindMedia(source.MediaId);
            var file = new OpenMediaFile(stream, source.ContentType, source.ContentLength, source.LastModified);
            var probe = await live.ProbeAsync(tools, file, source.SourcePath, source.MediaId, cancellationToken);
            var track = probe.Subtitles?.FirstOrDefault(candidate => candidate.Index == index);
            if (track is null) return Problem("invalid_subtitle_track", "The subtitle track was not found.", StatusCodes.Status404NotFound);
            if (!LiveSubtitles.CanConvert(track.Codec))
                return Problem("subtitle_not_supported", "Bitmap subtitles are not supported in this browser.", StatusCodes.Status422UnprocessableEntity);
            using var slot = await live.EnterAsync(encodesVideo: false, cancellationToken);
            if (slot is null)
            {
                context.Response.Headers.RetryAfter = "5";
                return Problem("conversion_busy", "The server is converting other titles. Try again shortly.", StatusCodes.Status429TooManyRequests);
            }
            var content = await live.ExtractSubtitlesAsync(tools, file, source.SourcePath, track.Index, cancellationToken);
            context.Response.Headers.CacheControl = "private, no-store";
            context.Response.Headers.XContentTypeOptions = "nosniff";
            return Results.Bytes(content, "text/vtt; charset=utf-8");
        }
        catch (PlaybackException exception)
        {
            if (exception.StatusCode == StatusCodes.Status503ServiceUnavailable) context.Response.Headers.RetryAfter = "2";
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }
}
