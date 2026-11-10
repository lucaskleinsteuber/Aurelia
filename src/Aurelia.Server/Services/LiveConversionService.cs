using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Aurelia.Server.Services;

/// <param name="Ffmpeg">The converter.</param>
/// <param name="Ffprobe">The header reader next to it.</param>
/// <param name="Encoder">The preferred H.264 encoder for pictures a player cannot decode, or null.</param>
public sealed record FfmpegTools(string Ffmpeg, string Ffprobe, LiveVideoEncoder? Encoder)
{
    /// <summary>The video chip that passed its trial encode, or null to encode on the processor.</summary>
    public HardwareEncoder? Hardware { get; init; }

    /// <summary>Whether libx264 is there to fall back on when the chip fails.</summary>
    public bool HasSoftwareEncoder { get; init; }

    /// <summary>Whether encoding uses a video chip: a Linux chip or Apple's VideoToolbox.</summary>
    public bool EncodesOnChip => Hardware is not null || Encoder == LiveVideoEncoder.VideoToolbox;

    /// <summary>Whether this ffmpeg can hand out a sound track as plain PCM for speech subtitles.</summary>
    public SpeechAudioSupport Speech { get; init; }

    private readonly Lazy<HdrToneMapping> toneMapping = new(() => HdrToneMapping.Unavailable);
    public HdrToneMapping ToneMapping => toneMapping.Value;

    public FfmpegTools(string Ffmpeg, string Ffprobe, LiveVideoEncoder? Encoder, HdrToneMapping ToneMapping)
        : this(Ffmpeg, Ffprobe, Encoder) => toneMapping = new(() => ToneMapping);

    public FfmpegTools(string Ffmpeg, string Ffprobe, LiveVideoEncoder? Encoder, Func<HdrToneMapping> discoverToneMapping)
        : this(Ffmpeg, Ffprobe, Encoder)
    {
        ArgumentNullException.ThrowIfNull(discoverToneMapping);
        toneMapping = new(discoverToneMapping, LazyThreadSafetyMode.ExecutionAndPublication);
    }
}

/// <summary>What an ffmpeg offers for reading speech: nothing, a plain mono mix, or a mix leaning on the center channel.</summary>
public enum SpeechAudioSupport
{
    None,
    Plain,
    CenterMix,
}

/// <summary>
/// Converts titles live with ffmpeg for players that cannot open the original file. ffmpeg reads
/// only the file this server already checked and opened, and writes only to its standard output,
/// which goes straight into the HTTP response. Nothing converted is ever stored: there is no cache,
/// no segment and no temporary file. Only small header descriptions stay in memory.
/// </summary>
public sealed partial class LiveConversionService : IDisposable
{
    public const int MaximumConversions = 3;
    /// <summary>Picture encodes at a time on the processor; a video chip takes <see cref="MaximumChipConversions"/>.</summary>
    public const int MaximumVideoConversions = 1;
    public const int MaximumChipConversions = 3;
    private const int ProbeCacheSize = 256;
    private const int ErrorTailCharacters = 4096;
    private const int MaximumProbeBytes = 256 * 1024;
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan SubtitleTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan SlotWait = TimeSpan.FromSeconds(5);

    private readonly ILogger<LiveConversionService> logger;
    private readonly Task<FfmpegTools?> tools;
    private readonly string quietDirectory;
    private readonly string? hardwareSetting;
    private readonly int? configuredVideoLimit;
    private readonly Lazy<Task<Slots>> slots;

    private sealed record Slots(SemaphoreSlim All, int AllLimit, SemaphoreSlim Video, int VideoLimit);
    private readonly SemaphoreSlim probes = new(2, 2);
    private readonly ConcurrentDictionary<string, MediaProbeResult> probeCache = new(StringComparer.Ordinal);

    public LiveConversionService(IConfiguration configuration, ServerRuntimeOptions runtime, ILogger<LiveConversionService> logger)
    {
        this.logger = logger;
        quietDirectory = Path.Combine(runtime.DataDirectory, "Converter");
        var configured = configuration["Aurelia:Ffmpeg"];
        hardwareSetting = configuration["Aurelia:HardwareEncoding"];
        configuredVideoLimit = int.TryParse(configuration["Aurelia:MaximumVideoConversions"], System.Globalization.NumberStyles.Integer,
            System.Globalization.CultureInfo.InvariantCulture, out var limit) && limit is > 0 and <= 16 ? limit : null;
        tools = Task.Run(() => Discover(configured));
        slots = new(async () =>
        {
            var video = VideoConversionLimit(await tools, configuredVideoLimit);
            var all = Math.Max(MaximumConversions, video + 2);
            return new Slots(new SemaphoreSlim(all, all), all, new SemaphoreSlim(video, video), video);
        }, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public Task<FfmpegTools?> ToolsAsync() => tools;

    /// <summary>Remembers a chip that failed during a conversion, so the next ones use the processor for a while.</summary>
    public HardwareHealth Health { get; } = new();

    /// <summary>How many pictures may be encoded at once: one on the processor, three on a chip, or the owner's number.</summary>
    public static int VideoConversionLimit(FfmpegTools? tools, int? configured = null) =>
        configured ?? (tools?.EncodesOnChip == true ? MaximumChipConversions : MaximumVideoConversions);

    /// <summary>
    /// The encoder for the next conversion: the chip unless it failed lately and x264 can step in,
    /// then x264, then whatever the server has. Null when it cannot encode pictures at all.
    /// </summary>
    public static (LiveVideoEncoder Kind, HardwareEncoder? Chip)? ChooseEncoder(FfmpegTools tools, bool chipResting)
    {
        ArgumentNullException.ThrowIfNull(tools);
        if (tools.Hardware is { } chip && (!chipResting || !tools.HasSoftwareEncoder)) return (chip.Kind, chip);
        if (tools.HasSoftwareEncoder) return (LiveVideoEncoder.Libx264, null);
        return tools.Encoder is { } other && other is LiveVideoEncoder.VideoToolbox or LiveVideoEncoder.Libx264 ? (other, null) : null;
    }

    /// <summary>The encoder for the next conversion with this server's tools and chip health.</summary>
    public (LiveVideoEncoder Kind, HardwareEncoder? Chip)? ChooseEncoder(FfmpegTools tools) => ChooseEncoder(tools, Health.IsResting);

    /// <summary>Conversions running now.</summary>
    public int Running => slots.IsValueCreated && slots.Value.IsCompletedSuccessfully
        ? slots.Value.Result.AllLimit - slots.Value.Result.All.CurrentCount
        : 0;

    /// <summary>Picture encodes running now.</summary>
    public int RunningVideo => slots.IsValueCreated && slots.Value.IsCompletedSuccessfully
        ? slots.Value.Result.VideoLimit - slots.Value.Result.Video.CurrentCount
        : 0;

    public async Task<bool> IsAvailableAsync() => await tools is not null;

    /// <summary>Whether sound tracks can be read for subtitles from speech.</summary>
    public async Task<bool> SpeechAudioAvailableAsync() => (await tools)?.Speech is SpeechAudioSupport.Plain or SpeechAudioSupport.CenterMix;

    /// <summary>The ffmpeg to use: the configured one, the Mac app's own, then the system's on Linux.</summary>
    public static IEnumerable<string> Candidates(string? configured)
    {
        if (!string.IsNullOrWhiteSpace(configured))
        {
            if (!string.Equals(configured, "off", StringComparison.OrdinalIgnoreCase)) yield return configured;
            yield break;
        }
        var name = OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg";
        // The Mac app keeps the server in Resources/Server/<runtime> and ffmpeg in Resources/Server/ffmpeg.
        yield return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "ffmpeg", name));
        yield return Path.Combine(AppContext.BaseDirectory, "ffmpeg", name);
        if (OperatingSystem.IsLinux()) yield return "/usr/bin/ffmpeg";
    }

    private FfmpegTools? Discover(string? configured)
    {
        foreach (var ffmpeg in Candidates(configured))
        {
            try
            {
                var ffprobe = Path.Combine(Path.GetDirectoryName(ffmpeg) ?? ".", OperatingSystem.IsWindows() ? "ffprobe.exe" : "ffprobe");
                if (!File.Exists(ffmpeg) || !File.Exists(ffprobe)) continue;
                PrepareQuietDirectory();
                var encoders = RunForOutput(ffmpeg, ["-hide_banner", "-encoders"], TimeSpan.FromSeconds(10));
                // Sound always becomes AAC when a player cannot decode it, so that encoder is required.
                if (encoders is null || !HasEncoder(encoders, "aac")) continue;
                RunForOutput(ffprobe, ["-hide_banner", "-version"], TimeSpan.FromSeconds(10));
                HardwareEncoder? hardware = null;
                if (OperatingSystem.IsLinux())
                {
                    var accelerations = RunForOutput(ffmpeg, ["-hide_banner", "-hwaccels"], TimeSpan.FromSeconds(10));
                    hardware = HardwareEncoding.Detect(arguments => RunForOutput(ffmpeg, arguments, TimeSpan.FromSeconds(15)),
                        encoders, accelerations, hardwareSetting, HardwareEncoding.RenderDevices());
                }
                var software = HasEncoder(encoders, "libx264");
                LiveVideoEncoder? encoder = hardware?.Kind ?? (OperatingSystem.IsMacOS() && HasEncoder(encoders, "h264_videotoolbox")
                    ? LiveVideoEncoder.VideoToolbox
                    : software ? LiveVideoEncoder.Libx264 : null);
                LogFound(logger, ffmpeg, encoder is { } found ? HardwareEncoding.DisplayName(found) + (hardware?.Device is { } device ? " on " + device : "") : "none");
                var speech = SpeechAudioSupport.None;
                if (HasEncoder(encoders, "pcm_s16le")
                    && RunForOutput(ffmpeg, ["-hide_banner", "-muxers"], TimeSpan.FromSeconds(10)) is { } muxers && HasEncoder(muxers, "s16le"))
                {
                    var filters = RunForOutput(ffmpeg, ["-hide_banner", "-filters"], TimeSpan.FromSeconds(10));
                    speech = filters is not null && HasEncoder(filters, "pan") ? SpeechAudioSupport.CenterMix : SpeechAudioSupport.Plain;
                }
                // Mapper discovery starts only when HDR picture encoding actually needs it.
                // Startup, direct delivery, repackaging and SDR conversion pay no extra process cost.
                return new FfmpegTools(ffmpeg, ffprobe, encoder, () => DiscoverToneMapping(ffmpeg))
                {
                    Speech = speech,
                    Hardware = hardware,
                    HasSoftwareEncoder = software,
                };
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                                                  or InvalidOperationException or System.ComponentModel.Win32Exception)
            {
                LogUnusable(logger, ffmpeg, exception.Message);
            }
        }
        return null;
    }

    private HdrToneMapping DiscoverToneMapping(string ffmpeg)
    {
        try
        {
            var scaleHelp = RunForOutput(ffmpeg, ["-hide_banner", "-h", "filter=scale"], TimeSpan.FromSeconds(10));
            var mapping = LiveHdr.Detect(scaleHelp, null);
            return mapping != HdrToneMapping.Unavailable ? mapping
                : LiveHdr.Detect(null, RunForOutput(ffmpeg, ["-hide_banner", "-filters"], TimeSpan.FromSeconds(10)));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                                              or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            LogUnusable(logger, ffmpeg, exception.Message);
            return HdrToneMapping.Unavailable;
        }
    }

    private static bool HasEncoder(string list, string name) =>
        list.Split('\n').Any(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries) is [_, var encoder, ..] && encoder == name);

    /// <summary>
    /// ffmpeg's working and home folder: empty and read-only, so nothing it might try to write
    /// there (a log, a cache) can ever land on disk.
    /// </summary>
    private void PrepareQuietDirectory()
    {
        Directory.CreateDirectory(quietDirectory);
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(quietDirectory, UnixFileMode.UserRead | UnixFileMode.UserExecute);
    }

    public static void EnsureInputMatchesHandle(SafeFileHandle handle, string checkedPath)
    {
        if (OperatingSystem.IsWindows()) return;
        if (!UnixFileIdentity.Matches(handle, checkedPath))
        {
            throw new IOException("The media file at the checked path has changed, been replaced, or is no longer the pinned file.");
        }
    }

    /// <summary>The path under which ffmpeg reads the open file.</summary>
    /// <remarks>
    /// On Linux this is the server's own descriptor in /proc, so ffmpeg reaches exactly the file
    /// that was checked and opened, even if the path changed meanwhile. Elsewhere it is the checked
    /// path, which the server keeps open while ffmpeg runs, failing closed if its identity or symlink
    /// state differs from the pinned descriptor.
    /// </remarks>
    public static string InputPath(FileStream stream, string checkedPath)
    {
        EnsureInputMatchesHandle(stream.SafeFileHandle, checkedPath);
        return OperatingSystem.IsLinux()
            ? $"/proc/{Environment.ProcessId}/fd/{stream.SafeFileHandle.DangerousGetHandle()}"
            : checkedPath;
    }

    /// <summary>The file's header description, from memory while size and modification time are unchanged.</summary>
    public async Task<MediaProbeResult> ProbeAsync(FfmpegTools tools, OpenMediaFile file, string checkedPath, Guid mediaId, CancellationToken cancellationToken)
    {
        var key = $"{mediaId:N}:{file.Length}:{file.LastModified.UtcTicks}";
        if (probeCache.TryGetValue(key, out var cached)) return cached;
        await probes.WaitAsync(cancellationToken);
        try
        {
            if (probeCache.TryGetValue(key, out cached)) return cached;
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(ProbeTimeout);
            using var process = Start(tools.Ffprobe, MediaProbe.Arguments(InputPath(file.Stream, checkedPath)), lowPriority: false);
            var errors = ReadTailAsync(process.StandardError);
            string json;
            try
            {
                json = Encoding.UTF8.GetString(await ReadLimitedAsync(process.StandardOutput.BaseStream, MaximumProbeBytes, timeout.Token));
                await process.WaitForExitAsync(timeout.Token);
                EnsureInputMatchesHandle(file.Stream.SafeFileHandle, checkedPath);
            }
            catch (OperationCanceledException)
            {
                if (cancellationToken.IsCancellationRequested) throw;
                throw new PlaybackException("media_probe_failed", "The server couldn’t read this title’s format in time.", StatusCodes.Status422UnprocessableEntity);
            }
            catch (InvalidDataException)
            {
                throw new PlaybackException("media_probe_failed", "This title’s format description is too large.", StatusCodes.Status422UnprocessableEntity);
            }
            finally { Stop(process); }
            if (process.ExitCode != 0)
            {
                LogFailed(logger, "ffprobe", process.ExitCode, await errors, checkedPath);
                throw new PlaybackException("media_probe_failed", "The server couldn’t read this title’s format.", StatusCodes.Status422UnprocessableEntity);
            }
            MediaProbeResult result;
            try { result = MediaProbe.Parse(json); }
            catch (System.Text.Json.JsonException)
            {
                throw new PlaybackException("media_probe_failed", "The server couldn’t read this title’s format.", StatusCodes.Status422UnprocessableEntity);
            }
            if (probeCache.Count >= ProbeCacheSize) probeCache.Clear();
            probeCache[key] = result;
            return result;
        }
        finally { probes.Release(); }
    }

    /// <summary>Extracts one text track to bounded request memory, never to a temporary file or cache.</summary>
    public async Task<byte[]> ExtractSubtitlesAsync(FfmpegTools tools, OpenMediaFile file, string checkedPath, int index, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(SubtitleTimeout);
        using var process = Start(tools.Ffmpeg, LiveSubtitles.Arguments(InputPath(file.Stream, checkedPath), index));
        var errors = ReadTailAsync(process.StandardError);
        using var stopOnAbort = timeout.Token.Register(() => Kill(process));
        try
        {
            var output = await ReadLimitedAsync(process.StandardOutput.BaseStream, LiveSubtitles.MaximumBytes, timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            EnsureInputMatchesHandle(file.Stream.SafeFileHandle, checkedPath);
            if (process.ExitCode == 0 && output.AsSpan().StartsWith("WEBVTT"u8)) return output;
            LogFailed(logger, "ffmpeg subtitles", process.ExitCode, await errors, checkedPath);
            throw new PlaybackException("subtitle_conversion_failed", "The server couldn’t read this subtitle track.", StatusCodes.Status422UnprocessableEntity);
        }
        catch (InvalidDataException)
        {
            throw new PlaybackException("subtitle_too_large", "This subtitle track is too large to open in a browser.", StatusCodes.Status422UnprocessableEntity);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new PlaybackException("subtitle_conversion_failed", "The server couldn’t read this subtitle track in time.", StatusCodes.Status422UnprocessableEntity);
        }
        finally { Stop(process); }
    }

    /// <summary>Reads at most the configured byte limit, including output from untrusted media metadata.</summary>
    public static async Task<byte[]> ReadLimitedAsync(Stream stream, int maximumBytes, CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumBytes);
        using var output = new MemoryStream();
        var buffer = new byte[16 * 1024];
        int read;
        while ((read = await stream.ReadAsync(buffer, cancellationToken)) > 0)
        {
            if (read > maximumBytes - output.Length) throw new InvalidDataException("The converter output exceeds its byte limit.");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    /// <summary>
    /// A place among the running conversions: three at a time, of which one may re-encode the
    /// picture. A seek replaces a stream, so a full server waits briefly for the old one to end.
    /// </summary>
    public async Task<IDisposable?> EnterAsync(bool encodesVideo, CancellationToken cancellationToken)
    {
        var limits = await slots.Value;
        if (!await limits.All.WaitAsync(SlotWait, cancellationToken)) return null;
        if (encodesVideo && !await WaitOrRelease(limits, cancellationToken)) return null;
        return new Slot(limits, encodesVideo);
    }

    private static async Task<bool> WaitOrRelease(Slots limits, CancellationToken cancellationToken)
    {
        try
        {
            if (await limits.Video.WaitAsync(SlotWait, cancellationToken)) return true;
        }
        catch (OperationCanceledException)
        {
            limits.All.Release();
            throw;
        }
        limits.All.Release();
        return false;
    }

    private sealed class Slot(Slots limits, bool encodesVideo) : IDisposable
    {
        private int released;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref released, 1) != 0) return;
            if (encodesVideo) limits.Video.Release();
            limits.All.Release();
        }
    }

    /// <summary>Starts ffmpeg or ffprobe without a shell, in the empty read-only folder, at low priority.</summary>
    public Process Start(string program, IReadOnlyList<string> arguments, bool lowPriority = true)
    {
        var start = new ProcessStartInfo(program)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardErrorEncoding = Encoding.UTF8,
            StandardOutputEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        if (Directory.Exists(quietDirectory)) start.WorkingDirectory = quietDirectory;
        if (!OperatingSystem.IsWindows())
        {
            start.Environment.Clear();
            start.Environment["PATH"] = "/usr/bin:/bin";
            start.Environment["HOME"] = quietDirectory;
            start.Environment["TMPDIR"] = quietDirectory;
        }
        var process = Process.Start(start) ?? throw new InvalidOperationException("ffmpeg did not start.");
        process.StandardInput.Close();
        if (lowPriority)
        {
            try { process.PriorityClass = ProcessPriorityClass.BelowNormal; }
            catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
        return process;
    }

    /// <summary>Ends ffmpeg and anything it started, and waits until it is gone.</summary>
    public static void Stop(Process process)
    {
        Kill(process);
        try { process.WaitForExit(5000); }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }

    /// <summary>Ends ffmpeg and anything it started without waiting.</summary>
    public static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }

    /// <summary>Keeps only the last few kilobytes of ffmpeg's messages, for a failure's log line.</summary>
    public static async Task<string> ReadTailAsync(StreamReader reader)
    {
        var tail = new StringBuilder();
        var buffer = new char[1024];
        try
        {
            int read;
            while ((read = await reader.ReadAsync(buffer)) > 0)
            {
                tail.Append(buffer, 0, read);
                if (tail.Length > ErrorTailCharacters) tail.Remove(0, tail.Length - ErrorTailCharacters);
            }
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException) { }
        return tail.ToString().Trim();
    }

    /// <summary>
    /// Reads ffmpeg's messages line by line when it also writes -progress to them: the progress
    /// lines report the speed against real time, everything else is kept as the failure tail.
    /// Lines are cut at 1024 characters, so a long message cannot grow memory.
    /// </summary>
    public static async Task<string> ReadDiagnosticsAsync(StreamReader reader, Action<double>? speed)
    {
        ArgumentNullException.ThrowIfNull(reader);
        var tail = new StringBuilder();
        var line = new StringBuilder();
        var buffer = new char[1024];
        void Finish()
        {
            var text = line.ToString().Trim();
            line.Clear();
            if (text.Length == 0) return;
            if (ProgressLine().Match(text) is { Success: true } progress)
            {
                if (progress.Groups[1].Value == "speed" && double.TryParse(progress.Groups[2].Value.TrimEnd('x'),
                        System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value)
                    && double.IsFinite(value) && value >= 0) speed?.Invoke(value);
                return;
            }
            tail.Append(text).Append('\n');
            if (tail.Length > ErrorTailCharacters) tail.Remove(0, tail.Length - ErrorTailCharacters);
        }
        try
        {
            int read;
            while ((read = await reader.ReadAsync(buffer)) > 0)
            {
                foreach (var character in buffer.AsSpan(0, read))
                {
                    if (character == '\n') Finish();
                    else if (line.Length < 1024) line.Append(character);
                }
            }
            Finish();
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException) { }
        return tail.ToString().Trim();
    }

    [System.Text.RegularExpressions.GeneratedRegex(@"^(frame|fps|stream_\d+_\d+_q|bitrate|total_size|out_time_us|out_time_ms|out_time|dup_frames|drop_frames|speed|progress)=(.*)$")]
    private static partial System.Text.RegularExpressions.Regex ProgressLine();

    private string? RunForOutput(string program, IReadOnlyList<string> arguments, TimeSpan timeout)
    {
        using var process = Start(program, arguments, lowPriority: false);
        var output = process.StandardOutput.ReadToEndAsync();
        _ = ReadTailAsync(process.StandardError);
        if (!process.WaitForExit(timeout))
        {
            Stop(process);
            return null;
        }
        return process.ExitCode == 0 ? output.GetAwaiter().GetResult() : null;
    }

    [LoggerMessage(LogLevel.Information, "Live conversion uses ffmpeg at {Path}; picture encoder: {Encoder}.")]
    private static partial void LogFound(ILogger logger, string path, string encoder);

    [LoggerMessage(LogLevel.Warning, "ffmpeg at {Path} could not be used: {Message}")]
    private static partial void LogUnusable(ILogger logger, string path, string message);

    /// <summary>Logs ffmpeg's last messages after a failure. They name the input, which on a Mac is the
    /// media file's full path, so it is replaced: full media paths stay out of logs.</summary>
    public static void LogFailed(ILogger logger, string program, int code, string detail, string inputPath) =>
        LogFailedMessage(logger, program, code,
            inputPath.Length == 0 ? detail : detail.Replace(inputPath, "<media>", StringComparison.Ordinal));

    [LoggerMessage(LogLevel.Warning, "{Program} ended with status {Code}: {Detail}")]
    private static partial void LogFailedMessage(ILogger logger, string program, int code, string detail);

    public void Dispose()
    {
        if (slots.IsValueCreated && slots.Value.IsCompletedSuccessfully)
        {
            slots.Value.Result.All.Dispose();
            slots.Value.Result.Video.Dispose();
        }
        probes.Dispose();
    }
}
