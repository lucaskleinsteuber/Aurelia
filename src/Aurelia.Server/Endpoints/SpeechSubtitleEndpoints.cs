using System.Globalization;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Http.Features;

namespace Aurelia.Server.Endpoints;

/// <summary>
/// Subtitles written from speech: a device with a speech recognizer (the Mac app) reads one sound
/// track as plain PCM through a playback ticket, writes the subtitles itself and hands them back
/// as SubRip text. The server only decodes sound live and keeps the finished text in its data
/// folder beside downloaded subtitles; nothing converted is stored.
/// </summary>
public static class SpeechSubtitleEndpoints
{
    /// <summary>A long film's subtitles are about 150 KB; this leaves room for any title.</summary>
    public const int MaximumSubtitleBytes = 2 * 1024 * 1024;
    public const string UploadSuffix = "/subtitles/speech";

    public static void MapSpeechSubtitles(this WebApplication app)
    {
        app.MapGet("/api/v1/streams/{ticket}/speech-audio/tracks", TracksAsync).RequireAuthorization();
        app.MapGet("/api/v1/streams/{ticket}/speech-audio", StreamAsync).RequireAuthorization();
        app.MapPost("/api/v1/media/{mediaId:guid}" + UploadSuffix, SaveAsync).RequireAuthorization("Administrator");
    }

    /// <summary>Whether a request uploads speech subtitles, which may be larger than JSON.</summary>
    public static bool IsUpload(HttpRequest request) =>
        HttpMethods.IsPost(request.Method)
        && (request.Path.Value ?? "").EndsWith(UploadSuffix, StringComparison.OrdinalIgnoreCase);

    private static async Task<IResult> TracksAsync(
        HttpContext context, string ticket, PlaybackService playback, LiveConversionService live,
        CatalogMutationGate mutations, CancellationToken cancellationToken)
    {
        if (await live.ToolsAsync() is not { Speech: not SpeechAudioSupport.None } tools) return Unavailable();
        var opened = await OpenAsync(context, ticket, playback, mutations, cancellationToken);
        if (opened.Problem is { } problem) return problem;
        var source = opened.Source!;
        await using var file = source.Stream;
        try
        {
            var probe = await live.ProbeAsync(tools, new OpenMediaFile(file, source.ContentType, source.ContentLength, source.LastModified),
                source.SourcePath, source.MediaId, cancellationToken);
            return Results.Ok(new SpeechAudioTracksResponse(probe.DurationSeconds, probe.Audio
                .Select(track => new SpeechAudioTrack(track.Index, track.Codec, track.Channels, track.Language, track.Title, track.IsDefault))
                .ToList()));
        }
        catch (PlaybackException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }

    private static async Task<IResult> StreamAsync(
        HttpContext context, string ticket, int? audio, PlaybackService playback, LiveConversionService live,
        CatalogMutationGate mutations, ILogger<LiveConversionService> logger, CancellationToken cancellationToken)
    {
        if (await live.ToolsAsync() is not { Speech: not SpeechAudioSupport.None } tools) return Unavailable();
        var opened = await OpenAsync(context, ticket, playback, mutations, cancellationToken);
        if (opened.Problem is { } problem) return problem;
        var source = opened.Source!;
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
        if (LiveSpeechAudio.Choose(probe.Audio, audio) is not { } track)
            return Problem("invalid_audio_track", "The sound track was not found.", StatusCodes.Status400BadRequest);

        using var slot = await live.EnterAsync(encodesVideo: false, cancellationToken);
        if (slot is null)
        {
            context.Response.Headers.RetryAfter = "5";
            return Problem("conversion_busy", "The server is converting as many titles as it can. Try again shortly.", StatusCodes.Status429TooManyRequests);
        }
        using var process = live.Start(tools.Ffmpeg, LiveSpeechAudio.Arguments(LiveConversionService.InputPath(file, source.SourcePath), track,
            centerMix: tools.Speech == SpeechAudioSupport.CenterMix));
        var errors = LiveConversionService.ReadTailAsync(process.StandardError);
        var output = process.StandardOutput.BaseStream;
        using var stopOnAbort = cancellationToken.Register(() => LiveConversionService.Kill(process));
        try
        {
            var buffer = new byte[64 * 1024];
            var read = await output.ReadAsync(buffer, cancellationToken);
            if (read == 0)
            {
                await process.WaitForExitAsync(cancellationToken);
                LiveConversionService.LogFailed(logger, "ffmpeg speech audio", process.ExitCode, await errors);
                return Problem("conversion_failed", "The server couldn’t read this title’s sound.", StatusCodes.Status500InternalServerError);
            }
            context.Response.StatusCode = StatusCodes.Status200OK;
            context.Response.ContentType = LiveSpeechAudio.ContentType;
            context.Response.Headers.CacheControl = "private, no-store";
            context.Response.Headers.XContentTypeOptions = "nosniff";
            if (probe.DurationSeconds is { } seconds)
                context.Response.Headers["X-Aurelia-Duration"] = seconds.ToString("0.###", CultureInfo.InvariantCulture);
            context.Features.Get<IHttpResponseBodyFeature>()?.DisableBuffering();
            // Writing waits while the device is busy, so ffmpeg waits on its full pipe too.
            do
            {
                await context.Response.Body.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                lease?.MarkRead();
            }
            while ((read = await output.ReadAsync(buffer, cancellationToken)) > 0);
            await process.WaitForExitAsync(cancellationToken);
            if (process.ExitCode != 0)
                LiveConversionService.LogFailed(logger, "ffmpeg speech audio", process.ExitCode, await errors);
        }
        catch (Exception exception) when (exception is OperationCanceledException or IOException)
        {
            // The device stopped listening or its session was revoked.
        }
        finally
        {
            LiveConversionService.Stop(process);
        }
        return Results.Empty;
    }

    private static async Task<IResult> SaveAsync(
        HttpContext context, Guid mediaId, string? language, SubtitleDownloadService subtitles,
        CancellationToken cancellationToken)
    {
        byte[] bytes;
        try
        {
            bytes = await LiveConversionService.ReadLimitedAsync(context.Request.Body, MaximumSubtitleBytes, cancellationToken);
        }
        catch (InvalidDataException)
        {
            return Problem("request_too_large", "The subtitles are larger than the server accepts.", StatusCodes.Status413PayloadTooLarge);
        }
        try
        {
            var text = Encoding.UTF8.GetString(bytes);
            return Results.Ok(await subtitles.AddFromSpeechAsync(mediaId, language ?? "", text, cancellationToken));
        }
        catch (MetadataException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }

    private sealed record Opened(PlaybackStreamSource? Source, IResult? Problem);

    private static async Task<Opened> OpenAsync(
        HttpContext context, string ticket, PlaybackService playback, CatalogMutationGate mutations,
        CancellationToken cancellationToken)
    {
        var mutationLease = await mutations.EnterAsync(cancellationToken);
        try
        {
            var source = await playback.OpenStreamAsync(ticket, context.User.RequireUserId(), context.User.RequireSessionId(),
                cancellationToken, context.User.RequireProfileSessionId());
            return source is null ? new Opened(null, Results.NotFound()) : new Opened(source, null);
        }
        catch (PlaybackException exception)
        {
            if (exception.StatusCode == StatusCodes.Status503ServiceUnavailable)
                context.Response.Headers.RetryAfter = "2";
            return new Opened(null, Problem(exception.Code, exception.Message, exception.StatusCode));
        }
        finally
        {
            mutationLease.Dispose();
        }
    }

    private static IResult Unavailable() =>
        Problem("conversion_unavailable", "This server can’t read sound tracks.", StatusCodes.Status409Conflict);

    private static IResult Problem(string code, string message, int statusCode) =>
        Results.Json(new ApiProblem(code, message), statusCode: statusCode);
}
