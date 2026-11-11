using System.Text.RegularExpressions;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Services;
using Aurelia.Server.Services.Hls;

namespace Aurelia.Server.Endpoints;

/// <summary>
/// Adaptive streaming over HLS (docs/CLIENT_PROTOCOL.md): a master playlist with one variant per
/// quality, a video-on-demand playlist per quality, and init and media segments converted live.
/// Every request checks its playback ticket like any stream read. Segments are kept in memory
/// only, for the session's lifetime; nothing converted is stored.
/// </summary>
public static partial class HlsEndpoints
{
    public static void MapHls(this WebApplication app)
    {
        app.MapGet("/api/v1/streams/{ticket}/hls/master.m3u8", MasterAsync).RequireAuthorization().WithDisplayName("HLS master playlist");
        app.MapGet("/api/v1/streams/{ticket}/hls/{step}/index.m3u8", MediaAsync).RequireAuthorization().WithDisplayName("HLS media playlist");
        app.MapGet("/api/v1/streams/{ticket}/hls/{step}/init.mp4", InitAsync).RequireAuthorization().WithDisplayName("HLS init segment");
        app.MapGet("/api/v1/streams/{ticket}/hls/{step}/{segment:int}.m4s", SegmentAsync).RequireAuthorization().WithDisplayName("HLS media segment");
    }

    private sealed record Opened(PlaybackStreamSource Source, MediaProbeResult Probe, FfmpegTools Tools, ProbedVideo Video, ProbedAudio? Audio, double Duration);

    private static async Task<IResult> MasterAsync(HttpContext context, string ticket, int? audio, PlaybackService playback,
        LiveConversionService live, CatalogMutationGate mutations, CancellationToken cancellationToken)
    {
        var (opened, problem) = await OpenAsync(context, ticket, audio, playback, live, mutations, cancellationToken);
        if (opened is null) return problem!;
        await using (opened.Source.Stream)
        {
            // Qualities this server measured too slow to convert in time are left out.
            var steps = live.Pace.Offered(live.ChooseEncoder(opened.Tools)?.Kind, StreamingLadder.For(opened.Video, opened.Probe.BitRate));
            return Playlist(context, HlsPlaylists.Master(steps, opened.Audio?.Index));
        }
    }

    private static async Task<IResult> MediaAsync(HttpContext context, string ticket, string step, int? audio, PlaybackService playback,
        LiveConversionService live, CatalogMutationGate mutations, CancellationToken cancellationToken)
    {
        if (!StepName().IsMatch(step)) return QualityNotFound();
        var (opened, problem) = await OpenAsync(context, ticket, audio, playback, live, mutations, cancellationToken);
        if (opened is null) return problem!;
        await using (opened.Source.Stream)
        {
            if (StreamingLadder.Find(opened.Video, opened.Probe.BitRate, step) is null) return QualityNotFound();
            return Playlist(context, HlsPlaylists.Media(opened.Duration, opened.Audio?.Index));
        }
    }

    private static Task<IResult> InitAsync(HttpContext context, string ticket, string step, int? audio, PlaybackService playback,
        LiveConversionService live, CatalogMutationGate mutations, HlsSessionManager sessions, CancellationToken cancellationToken) =>
        ServeAsync(context, ticket, step, audio, playback, live, mutations, sessions,
            (session, token) => session.InitAsync(token), cancellationToken);

    private static Task<IResult> SegmentAsync(HttpContext context, string ticket, string step, int segment, int? audio, PlaybackService playback,
        LiveConversionService live, CatalogMutationGate mutations, HlsSessionManager sessions, CancellationToken cancellationToken) =>
        ServeAsync(context, ticket, step, audio, playback, live, mutations, sessions,
            (session, token) => segment >= 0 && segment < session.SegmentCount ? session.SegmentAsync(segment, token) : Task.FromResult<byte[]?>(null),
            cancellationToken, segment);

    private static async Task<IResult> ServeAsync(HttpContext context, string ticket, string step, int? audio, PlaybackService playback,
        LiveConversionService live, CatalogMutationGate mutations, HlsSessionManager sessions,
        Func<HlsSession, CancellationToken, Task<byte[]?>> read, CancellationToken cancellationToken, int? segment = null)
    {
        if (!StepName().IsMatch(step)) return QualityNotFound();
        var (opened, problem) = await OpenAsync(context, ticket, audio, playback, live, mutations, cancellationToken);
        if (opened is null) return problem!;
        var lease = context.Items["Aurelia.StreamLease"] as ActiveStreamRegistry.Lease;
        lease?.BindMedia(opened.Source.MediaId);
        var key = new HlsSessionKey(context.User.RequireUserId(), context.User.RequireProfileSessionId(), opened.Source.MediaId, step, opened.Audio?.Index);
        HlsSession session;
        try
        {
            if (sessions.Find(key) is { } running)
            {
                await opened.Source.Stream.DisposeAsync();
                session = running;
            }
            else
            {
                if (StreamingLadder.Find(opened.Video, opened.Probe.BitRate, step) is not { } quality)
                {
                    await opened.Source.Stream.DisposeAsync();
                    return QualityNotFound();
                }
                var toneMapping = opened.Video.IsHdr ? opened.Tools.ToneMapping : HdrToneMapping.Unavailable;
                if (opened.Video.IsHdr && toneMapping == HdrToneMapping.Unavailable)
                {
                    await opened.Source.Stream.DisposeAsync();
                    var unsupported = LiveHdr.Unsupported();
                    return Problem(unsupported.Code, unsupported.Message, unsupported.StatusCode);
                }
                LiveConversionService.EnsureInputMatchesHandle(opened.Source.Stream.SafeFileHandle, opened.Source.SourcePath);
                session = await sessions.AddAsync(sessions.Create(key, opened.Source.Stream, opened.Source.Stream, opened.Source.SourcePath,
                    Path.GetFileName(opened.Source.SourcePath), opened.Duration, quality, opened.Video, opened.Audio, toneMapping, opened.Tools));
            }
            var data = await read(session, cancellationToken);
            if (data is null)
            {
                return segment is { } index && (index < 0 || index >= session.SegmentCount)
                    ? Problem("segment_not_found", "This segment is not part of the title.", StatusCodes.Status404NotFound)
                    : Problem("conversion_failed", "The server couldn’t convert this part of the title.", StatusCodes.Status500InternalServerError);
            }
            lease?.MarkRead();
            context.Response.Headers.CacheControl = "private, no-store";
            context.Response.Headers.XContentTypeOptions = "nosniff";
            return Results.Bytes(data, "video/mp4");
        }
        catch (HlsBusyException)
        {
            context.Response.Headers.RetryAfter = "5";
            return Problem("conversion_busy", "The server is converting as many titles as it can. Try again shortly.", StatusCodes.Status429TooManyRequests);
        }
        catch (IOException)
        {
            return Problem("conversion_failed", "The server couldn’t read this title.", StatusCodes.Status500InternalServerError);
        }
    }

    /// <summary>Checks the ticket and opens the title like a stream read, then reads its header description.</summary>
    private static async Task<(Opened? Opened, IResult? Problem)> OpenAsync(HttpContext context, string ticket, int? audio,
        PlaybackService playback, LiveConversionService live, CatalogMutationGate mutations, CancellationToken cancellationToken)
    {
        if (await live.ToolsAsync() is not { } tools || live.ChooseEncoder(tools) is null)
            return (null, Problem("conversion_unavailable", "This server can’t convert titles for adaptive streaming.", StatusCodes.Status409Conflict));
        PlaybackStreamSource? source;
        var mutationLease = await mutations.EnterAsync(cancellationToken);
        try
        {
            source = await playback.OpenStreamAsync(ticket, context.User.RequireUserId(), context.User.RequireSessionId(), cancellationToken,
                context.User.RequireProfileSessionId());
        }
        catch (PlaybackException exception)
        {
            if (exception.StatusCode == StatusCodes.Status503ServiceUnavailable) context.Response.Headers.RetryAfter = "2";
            return (null, Problem(exception.Code, exception.Message, exception.StatusCode));
        }
        finally { mutationLease.Dispose(); }
        if (source is null) return (null, Results.NotFound());

        try
        {
            var probe = await live.ProbeAsync(tools, new OpenMediaFile(source.Stream, source.ContentType, source.ContentLength, source.LastModified),
                source.SourcePath, source.MediaId, cancellationToken);
            if (probe.Video is not { Width: > 0, Height: > 0 } video)
                return await FailAsync(source, Problem("conversion_not_possible", "This title has no picture to convert.", StatusCodes.Status422UnprocessableEntity));
            if (probe.DurationSeconds is not { } duration || duration <= 0)
                return await FailAsync(source, Problem("stream_length_unknown", "The server can’t tell how long this title is, so it can’t offer it in qualities.", StatusCodes.Status422UnprocessableEntity));
            ProbedAudio? sound;
            if (audio is { } index)
            {
                sound = probe.Audio.FirstOrDefault(track => track.Index == index);
                if (sound is null) return await FailAsync(source, Problem("invalid_audio_track", "The sound track was not found.", StatusCodes.Status400BadRequest));
            }
            else sound = probe.Audio.FirstOrDefault(track => track.IsDefault) ?? (probe.Audio.Count > 0 ? probe.Audio[0] : null);
            return (new Opened(source, probe, tools, video, sound, duration), null);
        }
        catch (PlaybackException exception)
        {
            return await FailAsync(source, Problem(exception.Code, exception.Message, exception.StatusCode));
        }
    }

    private static async Task<(Opened?, IResult?)> FailAsync(PlaybackStreamSource source, IResult problem)
    {
        await source.Stream.DisposeAsync();
        return (null, problem);
    }

    private static IResult Playlist(HttpContext context, string text)
    {
        context.Response.Headers.CacheControl = "private, no-store";
        context.Response.Headers.XContentTypeOptions = "nosniff";
        return Results.Text(text, HlsPlaylists.ContentType);
    }

    private static IResult QualityNotFound() =>
        Problem("stream_quality_not_found", "This title isn’t offered in that quality.", StatusCodes.Status404NotFound);

    private static IResult Problem(string code, string message, int statusCode) =>
        Results.Json(new ApiProblem(code, message), statusCode: statusCode);

    [GeneratedRegex("^[1-9][0-9]{2,3}p$", RegexOptions.CultureInvariant)]
    private static partial Regex StepName();
}
