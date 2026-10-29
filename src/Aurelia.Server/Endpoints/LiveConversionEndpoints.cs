using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Endpoints;

/// <summary>
/// Live conversion for players that cannot open a file themselves (docs/CLIENT_PROTOCOL.md). The
/// plan says what will be repackaged or converted; the stream runs ffmpeg for one playback ticket
/// and sends its fragmented MP4 straight into the response. Nothing converted is stored.
/// </summary>
public static partial class LiveConversionEndpoints
{
    private const double LongestTitleSeconds = 48 * 3600;

    public static void MapLiveConversion(this WebApplication app)
    {
        app.MapPost("/api/v1/media/{mediaId:guid}/conversion", PlanAsync).RequireAuthorization();
        app.MapGet("/api/v1/streams/{ticket}/live", StreamAsync)
            .RequireAuthorization()
            .WithDisplayName("Stream converted media");
        app.MapGet("/api/v1/streams/{ticket}/subtitles", ListSubtitlesAsync)
            .RequireAuthorization()
            .WithDisplayName("List available subtitle tracks");
        app.MapGet("/api/v1/streams/{ticket}/subtitles/{index:int}", SubtitlesAsync)
            .RequireAuthorization()
            .WithDisplayName("Read embedded or sidecar subtitles");
    }

    private static async Task<IResult> PlanAsync(
        Guid mediaId,
        LiveConversionRequest request,
        AureliaDbContext database,
        LiveConversionService live,
        CancellationToken cancellationToken)
    {
        if (await live.ToolsAsync() is not { } tools) return Unavailable();
        // The catalog's access rules filter this lookup, as for a playback ticket.
        var media = await database.MediaItems
            .AsNoTracking()
            .Include(candidate => candidate.LibraryRoot)
            .SingleOrDefaultAsync(candidate => candidate.Id == mediaId, cancellationToken);
        if (media is null) return Problem("media_not_found", "The media item was not found.", StatusCodes.Status404NotFound);
        if (media.Kind == MediaKind.Series)
            return Problem("media_not_playable", "This media item is a container and cannot be played directly.", StatusCodes.Status409Conflict);
        try
        {
            var file = MediaFileAccess.OpenRead(media);
            await using var stream = file.Stream;
            var probe = await live.ProbeAsync(tools, file, Path.GetFullPath(media.SourcePath), media.Id, cancellationToken);
            var sidecars = SidecarSubtitles.Discover(Path.GetFullPath(media.SourcePath));
            return LiveConversionPlanner.Plan(probe, request, tools.Encoder is not null, () => tools.ToneMapping, sidecars) is { } plan
                ? Results.Ok(plan)
                : NotPossible();
        }
        catch (PlaybackException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }

    private static async Task<IResult> StreamAsync(
        HttpContext context,
        string ticket,
        string? start,
        int? audio,
        string? audioMode,
        string? video,
        PlaybackService playback,
        LiveConversionService live,
        CatalogMutationGate mutations,
        ILogger<LiveConversionService> logger,
        CancellationToken cancellationToken)
    {
        if (await live.ToolsAsync() is not { } tools) return Unavailable();
        var startSeconds = 0.0;
        if (!string.IsNullOrEmpty(start)
            && (!double.TryParse(start, NumberStyles.Float, CultureInfo.InvariantCulture, out startSeconds)
                || !double.IsFinite(startSeconds) || startSeconds is < 0 or > LongestTitleSeconds))
            return Problem("invalid_start", "The start position is not valid.", StatusCodes.Status400BadRequest);
        var encodeVideo = video switch
        {
            null or "" or "copy" => false,
            "h264" => true,
            _ => (bool?)null,
        };
        var copyAudio = audioMode switch
        {
            null or "" or "aac" => false,
            "copy" => true,
            _ => (bool?)null,
        };
        if (encodeVideo is null || copyAudio is null)
            return Problem("invalid_conversion", "The conversion options are not valid.", StatusCodes.Status400BadRequest);

        PlaybackStreamSource? source;
        var mutationLease = await mutations.EnterAsync(cancellationToken);
        try
        {
            source = await playback.OpenStreamAsync(
                ticket,
                context.User.RequireUserId(),
                context.User.RequireSessionId(),
                cancellationToken,
                context.User.RequireProfileSessionId());
        }
        catch (PlaybackException exception)
        {
            if (exception.StatusCode == StatusCodes.Status503ServiceUnavailable)
                context.Response.Headers.RetryAfter = "2";
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
        finally
        {
            mutationLease.Dispose();
        }
        if (source is null) return Results.NotFound();

        await using var file = source.Stream;
        var lease = context.Items["Aurelia.StreamLease"] as ActiveStreamRegistry.Lease;
        lease?.BindMedia(source.MediaId);

        MediaProbeResult probe;
        try
        {
            probe = await live.ProbeAsync(tools, new OpenMediaFile(file, source.ContentType, source.ContentLength, source.LastModified),
                source.SourcePath, source.MediaId, cancellationToken);
        }
        catch (PlaybackException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }

        if (probe.Video is not { } picture) return NotPossible();
        if (encodeVideo.Value ? tools.Encoder is null : !LiveConversionPlanner.CopyableVideo.Contains(picture.Codec))
            return NotPossible();
        var toneMapping = encodeVideo.Value && picture.IsHdr ? tools.ToneMapping : HdrToneMapping.Unavailable;
        if (encodeVideo.Value && picture.IsHdr && toneMapping == HdrToneMapping.Unavailable)
        {
            var unsupported = LiveHdr.Unsupported();
            return Problem(unsupported.Code, unsupported.Message, unsupported.StatusCode);
        }
        ProbedAudio? sound = null;
        if (audio is { } index)
        {
            sound = probe.Audio.FirstOrDefault(track => track.Index == index);
            if (sound is null) return Problem("invalid_audio_track", "The sound track was not found.", StatusCodes.Status400BadRequest);
            if (copyAudio.Value && !LiveConversionPlanner.CopyableAudio.Contains(sound.Codec))
                return Problem("invalid_conversion", "This sound track has to be converted.", StatusCodes.Status400BadRequest);
        }

        using var slot = await live.EnterAsync(encodeVideo.Value, cancellationToken);
        if (slot is null)
        {
            context.Response.Headers.RetryAfter = "5";
            return Problem("conversion_busy", "The server is converting as many titles as it can. Try again shortly.", StatusCodes.Status429TooManyRequests);
        }

        var options = new LiveStreamOptions(startSeconds, picture, encodeVideo.Value ? tools.Encoder : null, sound, copyAudio.Value, toneMapping);
        using var process = live.Start(tools.Ffmpeg, LiveConversionPlanner.Arguments(LiveConversionService.InputPath(file, source.SourcePath), options));
        var errors = LiveConversionService.ReadTailAsync(process.StandardError);
        var output = process.StandardOutput.BaseStream;
        // A pipe read may not notice a closed connection; ending ffmpeg ends the read at once.
        using var stopOnAbort = cancellationToken.Register(() => LiveConversionService.Kill(process));
        try
        {
            var buffer = new byte[64 * 1024];
            var read = await output.ReadAsync(buffer, cancellationToken);
            if (read == 0)
            {
                await process.WaitForExitAsync(cancellationToken);
                LiveConversionService.LogFailed(logger, "ffmpeg", process.ExitCode, await errors);
                return Problem("conversion_failed", "The server couldn’t convert this title.", StatusCodes.Status500InternalServerError);
            }

            context.Response.StatusCode = StatusCodes.Status200OK;
            context.Response.ContentType = "video/mp4";
            context.Response.Headers.CacheControl = "private, no-store";
            context.Response.Headers.XContentTypeOptions = "nosniff";
            context.Features.Get<IHttpResponseBodyFeature>()?.DisableBuffering();
            // Writing waits while the player's buffer is full, so ffmpeg waits on its full pipe too.
            do
            {
                await context.Response.Body.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                lease?.MarkRead();
            }
            while ((read = await output.ReadAsync(buffer, cancellationToken)) > 0);
            await process.WaitForExitAsync(cancellationToken);
            if (process.ExitCode != 0)
                LiveConversionService.LogFailed(logger, "ffmpeg", process.ExitCode, await errors);
        }
        catch (Exception exception) when (exception is OperationCanceledException or IOException)
        {
            // The player went away, sought elsewhere or its session was revoked.
        }
        finally
        {
            LiveConversionService.Stop(process);
        }
        return Results.Empty;
    }

    private static IResult Unavailable() =>
        Problem("conversion_unavailable", "This server can’t convert titles live.", StatusCodes.Status409Conflict);

    private static IResult NotPossible() =>
        Problem("conversion_not_possible", "This title’s picture can’t be converted on this server.", StatusCodes.Status422UnprocessableEntity);

    private static IResult Problem(string code, string message, int statusCode) =>
        Results.Json(new ApiProblem(code, message), statusCode: statusCode);
}
