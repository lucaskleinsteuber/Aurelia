using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

public static partial class LiveConversionEndpoints
{
    private static async Task<IResult> ListSubtitlesAsync(
        HttpContext context,
        string ticket,
        PlaybackService playback,
        LiveConversionService live,
        CatalogMutationGate mutations,
        CancellationToken cancellationToken)
    {
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

            var tracks = new List<LiveSubtitleTrack>();
            if (await live.ToolsAsync() is { } tools)
            {
                var file = new OpenMediaFile(stream, source.ContentType, source.ContentLength, source.LastModified);
                var probe = await live.ProbeAsync(tools, file, source.SourcePath, source.MediaId, cancellationToken);
                if (probe.Subtitles is not null)
                {
                    tracks.AddRange(probe.Subtitles.Select(track => new LiveSubtitleTrack(
                        track.Index, track.Codec, track.Language, track.Title, track.IsDefault, track.IsForced,
                        LiveSubtitles.CanConvert(track.Codec), IsSidecar: false)));
                }
            }

            var sidecars = SidecarSubtitles.Discover(source.SourcePath);
            for (var i = 0; i < sidecars.Count; i++)
            {
                var sc = sidecars[i];
                tracks.Add(new LiveSubtitleTrack(
                    1000 + i, sc.Format, sc.Language, sc.Title, sc.IsDefault, sc.IsForced, sc.Supported,
                    IsSidecar: true, IsSdh: sc.IsSdh));
            }

            return Results.Ok(tracks);
        }
        catch (PlaybackException exception)
        {
            if (exception.StatusCode == StatusCodes.Status503ServiceUnavailable) context.Response.Headers.RetryAfter = "2";
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }

    private static async Task<IResult> SubtitlesAsync(
        HttpContext context,
        string ticket,
        int index,
        PlaybackService playback,
        LiveConversionService live,
        CatalogMutationGate mutations,
        CancellationToken cancellationToken)
    {
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

            // Sidecar subtitle stream indices are mapped to 1000+
            if (index >= 1000)
            {
                var sidecars = SidecarSubtitles.Discover(source.SourcePath);
                var sidecarIndex = index - 1000;
                if (sidecarIndex < 0 || sidecarIndex >= sidecars.Count)
                    return Problem("invalid_subtitle_track", "The subtitle track was not found.", StatusCodes.Status404NotFound);

                var sidecar = sidecars[sidecarIndex];
                if (!sidecar.Supported)
                    return Problem("subtitle_not_supported", "Bitmap subtitles are not supported in this browser.", StatusCodes.Status422UnprocessableEntity);

                var content = await SidecarSubtitles.ReadAsWebVttAsync(sidecar.FilePath, cancellationToken);
                context.Response.Headers.CacheControl = "private, no-store";
                context.Response.Headers.XContentTypeOptions = "nosniff";
                return Results.Bytes(content, "text/vtt; charset=utf-8");
            }

            // Embedded subtitle stream
            if (await live.ToolsAsync() is not { } tools) return Unavailable();
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
            var embeddedContent = await live.ExtractSubtitlesAsync(tools, file, source.SourcePath, track.Index, cancellationToken);
            context.Response.Headers.CacheControl = "private, no-store";
            context.Response.Headers.XContentTypeOptions = "nosniff";
            return Results.Bytes(embeddedContent, "text/vtt; charset=utf-8");
        }
        catch (PlaybackException exception)
        {
            if (exception.StatusCode == StatusCodes.Status503ServiceUnavailable) context.Response.Headers.RetryAfter = "2";
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }
}
