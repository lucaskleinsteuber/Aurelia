using System.Globalization;
using System.Runtime.InteropServices;

namespace Aurelia.Server.Services;

/// <summary>
/// Reads a short stretch of one sound track as mono 16-bit PCM, or of the picture as small grey
/// pictures, for intro and credits detection. ffmpeg reads only the file the server checked and
/// opened and writes only to its standard output; sound and pictures stay in memory until they
/// are reduced to fingerprints and are never stored.
/// </summary>
public sealed class SegmentAudioReader(LiveConversionService live, ILogger<SegmentAudioReader> logger)
{
    public const int SampleRate = Segments.AudioFingerprint.SampleRate;
    private static readonly TimeSpan Timeout = TimeSpan.FromMinutes(5);

    /// <summary>
    /// ffmpeg arguments for <paramref name="length"/> seconds of sound from <paramref name="start"/>.
    /// All channels are mixed evenly, because theme music sits in the side channels. Gaps in the
    /// track are filled with silence so times keep matching the file.
    /// </summary>
    public static IReadOnlyList<string> Arguments(string input, ProbedAudio track, double start, double length)
    {
        ArgumentNullException.ThrowIfNull(track);
        var arguments = new List<string> { "-hide_banner", "-nostdin", "-loglevel", "error", "-protocol_whitelist", "file", "-threads", "1" };
        if (start > 0) arguments.AddRange(["-ss", start.ToString("0.###", CultureInfo.InvariantCulture)]);
        arguments.AddRange([
            "-t", length.ToString("0.###", CultureInfo.InvariantCulture),
            "-i", "file:" + input, "-map", string.Create(CultureInfo.InvariantCulture, $"0:{track.Index}"),
            "-map_metadata", "-1", "-map_chapters", "-1", "-vn", "-sn", "-dn",
            "-af", string.Create(CultureInfo.InvariantCulture, $"aresample={SampleRate}:async=1:first_pts=0"),
            "-ac", "1", "-ar", SampleRate.ToString(CultureInfo.InvariantCulture),
            "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1",
        ]);
        return arguments;
    }

    /// <summary>
    /// ffmpeg arguments for <paramref name="length"/> seconds of the picture from
    /// <paramref name="start"/>, as two 320 × 180 grey pictures a second.
    /// </summary>
    public static IReadOnlyList<string> PictureArguments(string input, int videoIndex, double start, double length)
    {
        var arguments = new List<string> { "-hide_banner", "-nostdin", "-loglevel", "error", "-protocol_whitelist", "file", "-threads", "2" };
        if (start > 0) arguments.AddRange(["-ss", start.ToString("0.###", CultureInfo.InvariantCulture)]);
        arguments.AddRange([
            "-t", length.ToString("0.###", CultureInfo.InvariantCulture),
            "-i", "file:" + input, "-map", string.Create(CultureInfo.InvariantCulture, $"0:{videoIndex}"),
            "-map_metadata", "-1", "-map_chapters", "-1", "-an", "-sn", "-dn",
            "-vf", string.Create(CultureInfo.InvariantCulture,
                $"fps={Segments.CreditsPictures.FramesPerSecond},scale={Segments.CreditsPictures.Width}:{Segments.CreditsPictures.Height}:flags=area,format=gray"),
            "-f", "rawvideo", "pipe:1",
        ]);
        return arguments;
    }

    /// <summary>
    /// The pictures of a stretch reduced to what credits detection needs, or null when ffmpeg could
    /// not read it. Each picture is measured as it arrives and then dropped.
    /// </summary>
    public async Task<Segments.PictureWindow?> ReadPicturesAsync(
        FfmpegTools tools, OpenMediaFile file, string checkedPath, int videoIndex, double start, double length, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(tools);
        ArgumentNullException.ThrowIfNull(file);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        // Decoding the picture is slow on small servers; an hour covers six minutes of 4K.
        timeout.CancelAfter(TimeSpan.FromHours(1));
        using var process = live.Start(tools.Ffmpeg, PictureArguments(LiveConversionService.InputPath(file.Stream, checkedPath), videoIndex, start, length), lowPriority: true);
        try { process.PriorityClass = System.Diagnostics.ProcessPriorityClass.Idle; }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        var errors = LiveConversionService.ReadTailAsync(process.StandardError);
        using var stopOnAbort = timeout.Token.Register(() => LiveConversionService.Kill(process));
        var builder = new Segments.CreditsPictures.Builder(start);
        var limit = (int)Math.Ceiling(length * Segments.CreditsPictures.FramesPerSecond) + 4;
        var buffer = new byte[Segments.CreditsPictures.FrameBytes];
        try
        {
            var output = process.StandardOutput.BaseStream;
            while (await output.ReadAtLeastAsync(buffer, buffer.Length, throwOnEndOfStream: false, timeout.Token) == buffer.Length)
            {
                if (builder.Count >= limit) return null;
                builder.Add(buffer);
            }
            await process.WaitForExitAsync(timeout.Token);
            LiveConversionService.EnsureInputMatchesHandle(file.Stream.SafeFileHandle, checkedPath);
            if (process.ExitCode != 0)
            {
                LiveConversionService.LogFailed(logger, "ffmpeg segment pictures", process.ExitCode, await errors, checkedPath);
                return null;
            }
            return builder.Build();
        }
        catch (IOException)
        {
            return null;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        finally
        {
            LiveConversionService.Stop(process);
        }
    }

    /// <summary>The samples, or null when ffmpeg could not read this stretch.</summary>
    public async Task<short[]?> ReadAsync(
        FfmpegTools tools, OpenMediaFile file, string checkedPath, ProbedAudio track, double start, double length, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(tools);
        ArgumentNullException.ThrowIfNull(file);
        var maximumBytes = (int)Math.Min(int.MaxValue / 2, (length * 1.1 + 2) * SampleRate * sizeof(short));
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(Timeout);
        using var process = live.Start(tools.Ffmpeg, Arguments(LiveConversionService.InputPath(file.Stream, checkedPath), track, start, length), lowPriority: true);
        var errors = LiveConversionService.ReadTailAsync(process.StandardError);
        using var stopOnAbort = timeout.Token.Register(() => LiveConversionService.Kill(process));
        try
        {
            var bytes = await LiveConversionService.ReadLimitedAsync(process.StandardOutput.BaseStream, maximumBytes, timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            LiveConversionService.EnsureInputMatchesHandle(file.Stream.SafeFileHandle, checkedPath);
            if (process.ExitCode != 0)
            {
                LiveConversionService.LogFailed(logger, "ffmpeg segment audio", process.ExitCode, await errors, checkedPath);
                return null;
            }
            var samples = new short[bytes.Length / sizeof(short)];
            if (BitConverter.IsLittleEndian)
            {
                bytes.AsSpan(0, samples.Length * sizeof(short)).CopyTo(MemoryMarshal.AsBytes(samples.AsSpan()));
            }
            else
            {
                for (var index = 0; index < samples.Length; index++)
                {
                    samples[index] = System.Buffers.Binary.BinaryPrimitives.ReadInt16LittleEndian(bytes.AsSpan(index * sizeof(short)));
                }
            }
            return samples;
        }
        catch (InvalidDataException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        finally
        {
            LiveConversionService.Stop(process);
        }
    }
}
