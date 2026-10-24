using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;

namespace Aurelia.Server.Services;

/// <param name="Ffmpeg">The converter.</param>
/// <param name="Ffprobe">The header reader next to it.</param>
/// <param name="Encoder">The H.264 encoder for pictures a player cannot decode, or null.</param>
public sealed record FfmpegTools(string Ffmpeg, string Ffprobe, LiveVideoEncoder? Encoder);

/// <summary>
/// Converts titles live with ffmpeg for players that cannot open the original file. ffmpeg reads
/// only the file this server already checked and opened, and writes only to its standard output,
/// which goes straight into the HTTP response. Nothing converted is ever stored: there is no cache,
/// no segment and no temporary file. Only small header descriptions stay in memory.
/// </summary>
public sealed partial class LiveConversionService : IDisposable
{
    public const int MaximumConversions = 3;
    public const int MaximumVideoConversions = 1;
    private const int ProbeCacheSize = 256;
    private const int ErrorTailCharacters = 4096;
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan SlotWait = TimeSpan.FromSeconds(5);

    private readonly ILogger<LiveConversionService> logger;
    private readonly Task<FfmpegTools?> tools;
    private readonly string quietDirectory;
    private readonly SemaphoreSlim conversions = new(MaximumConversions, MaximumConversions);
    private readonly SemaphoreSlim videoConversions = new(MaximumVideoConversions, MaximumVideoConversions);
    private readonly SemaphoreSlim probes = new(2, 2);
    private readonly ConcurrentDictionary<string, MediaProbeResult> probeCache = new(StringComparer.Ordinal);

    public LiveConversionService(IConfiguration configuration, ServerRuntimeOptions runtime, ILogger<LiveConversionService> logger)
    {
        this.logger = logger;
        quietDirectory = Path.Combine(runtime.DataDirectory, "Converter");
        var configured = configuration["Aurelia:Ffmpeg"];
        tools = Task.Run(() => Discover(configured));
    }

    public Task<FfmpegTools?> ToolsAsync() => tools;

    /// <summary>Conversions running now.</summary>
    public int Running => MaximumConversions - conversions.CurrentCount;

    public async Task<bool> IsAvailableAsync() => await tools is not null;

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
                LiveVideoEncoder? encoder = OperatingSystem.IsMacOS() && HasEncoder(encoders, "h264_videotoolbox")
                    ? LiveVideoEncoder.VideoToolbox
                    : HasEncoder(encoders, "libx264") ? LiveVideoEncoder.Libx264 : null;
                LogFound(logger, ffmpeg, encoder is { } found ? found.ToString() : "none");
                return new FfmpegTools(ffmpeg, ffprobe, encoder);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                                                  or InvalidOperationException or System.ComponentModel.Win32Exception)
            {
                LogUnusable(logger, ffmpeg, exception.Message);
            }
        }
        return null;
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

    /// <summary>The path under which ffmpeg reads the open file.</summary>
    /// <remarks>
    /// On Linux this is the server's own descriptor in /proc, so ffmpeg reaches exactly the file
    /// that was checked and opened, even if the path changed meanwhile. Elsewhere it is the checked
    /// path, which the server keeps open while ffmpeg runs.
    /// </remarks>
    public static string InputPath(FileStream stream, string checkedPath) =>
        OperatingSystem.IsLinux()
            ? $"/proc/{Environment.ProcessId}/fd/{stream.SafeFileHandle.DangerousGetHandle()}"
            : checkedPath;

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
            var output = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var errors = ReadTailAsync(process.StandardError);
            string json;
            try
            {
                json = await output;
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                Stop(process);
                if (cancellationToken.IsCancellationRequested) throw;
                throw new PlaybackException("media_probe_failed", "The server couldn’t read this title’s format in time.", StatusCodes.Status422UnprocessableEntity);
            }
            if (process.ExitCode != 0)
            {
                LogFailed(logger, "ffprobe", process.ExitCode, await errors);
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

    /// <summary>
    /// A place among the running conversions: three at a time, of which one may re-encode the
    /// picture. A seek replaces a stream, so a full server waits briefly for the old one to end.
    /// </summary>
    public async Task<IDisposable?> EnterAsync(bool encodesVideo, CancellationToken cancellationToken)
    {
        if (!await conversions.WaitAsync(SlotWait, cancellationToken)) return null;
        if (encodesVideo && !await WaitOrRelease(videoConversions, cancellationToken)) return null;
        return new Slot(this, encodesVideo);
    }

    private async Task<bool> WaitOrRelease(SemaphoreSlim semaphore, CancellationToken cancellationToken)
    {
        try
        {
            if (await semaphore.WaitAsync(SlotWait, cancellationToken)) return true;
        }
        catch (OperationCanceledException)
        {
            conversions.Release();
            throw;
        }
        conversions.Release();
        return false;
    }

    private sealed class Slot(LiveConversionService owner, bool encodesVideo) : IDisposable
    {
        private int released;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref released, 1) != 0) return;
            if (encodesVideo) owner.videoConversions.Release();
            owner.conversions.Release();
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

    [LoggerMessage(LogLevel.Warning, "{Program} ended with status {Code}: {Detail}")]
    public static partial void LogFailed(ILogger logger, string program, int code, string detail);

    public void Dispose()
    {
        conversions.Dispose();
        videoConversions.Dispose();
        probes.Dispose();
    }
}
