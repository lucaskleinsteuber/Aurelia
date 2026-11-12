using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Aurelia.Server.Services.Speech;

/// <summary>Hears words in 16 kHz mono sound; the server uses whisper.cpp, tests a fake.</summary>
public interface ISpeechRecognizer
{
    /// <summary>Whether recognition can run at all (the program is installed).</summary>
    bool Available { get; }

    /// <summary>
    /// The words in <paramref name="samples"/> with times from its start. The sound is handed over
    /// in memory and never written to a file.
    /// </summary>
    Task<IReadOnlyList<SpeechWord>> RecognizeAsync(short[] samples, string language, string modelPath, CancellationToken cancellationToken);
}

/// <summary>
/// whisper.cpp's command-line program as the recognizer: started without a shell, at low
/// priority, reading one stretch of sound as WAV from its standard input and writing the words
/// with their times to its standard output. Nothing is written to disk.
/// </summary>
public sealed partial class WhisperRecognizer(ILogger<WhisperRecognizer> logger) : ISpeechRecognizer
{
    private readonly Lazy<string?> program = new(() => Locate(null));

    public bool Available => Program is not null;

    public string? Program => program.Value;

    /// <summary>
    /// The whisper.cpp program: the Mac app's own beside the server, then the distribution's
    /// (Debian and Ubuntu package it as "whisper.cpp" with whisper-cli).
    /// </summary>
    public static IEnumerable<string> Candidates()
    {
        var name = OperatingSystem.IsWindows() ? "whisper-cli.exe" : "whisper-cli";
        // The Mac app keeps the server in Resources/Server/<runtime> and whisper in Resources/Server/whisper.
        yield return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "whisper", name));
        yield return Path.Combine(AppContext.BaseDirectory, "whisper", name);
        if (OperatingSystem.IsLinux())
        {
            yield return "/usr/bin/whisper-cli";
            yield return "/usr/bin/whisper-cpp";
            yield return "/usr/bin/whisper.cpp";
            yield return "/usr/local/bin/whisper-cli";
        }
        if (OperatingSystem.IsMacOS())
        {
            yield return "/opt/homebrew/bin/whisper-cli";
            yield return "/usr/local/bin/whisper-cli";
        }
    }

    public static string? Locate(string? configured)
    {
        if (!string.IsNullOrWhiteSpace(configured)) return File.Exists(configured) ? configured : null;
        return Candidates().FirstOrDefault(File.Exists);
    }

    public async Task<IReadOnlyList<SpeechWord>> RecognizeAsync(short[] samples, string language, string modelPath, CancellationToken cancellationToken)
    {
        if (Program is not { } path) throw new InvalidOperationException("whisper.cpp is not installed.");
        var start = new ProcessStartInfo(path)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in Arguments(modelPath, language, Threads())) start.ArgumentList.Add(argument);
        if (!OperatingSystem.IsWindows())
        {
            start.Environment.Clear();
            start.Environment["PATH"] = "/usr/bin:/bin";
        }
        using var process = Process.Start(start) ?? throw new InvalidOperationException("whisper.cpp did not start.");
        try { process.PriorityClass = ProcessPriorityClass.Idle; }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        using var stop = cancellationToken.Register(() => { try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
        var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errors = process.StandardError.ReadToEndAsync(cancellationToken);
        try
        {
            await using (var input = process.StandardInput.BaseStream)
            {
                await input.WriteAsync(Wav(samples), cancellationToken);
            }
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (IOException) when (!cancellationToken.IsCancellationRequested)
        {
            // The program ended early; its exit code and messages say why.
            await process.WaitForExitAsync(cancellationToken);
        }
        var text = await output;
        if (process.ExitCode != 0)
        {
            var tail = (await errors).Split('\n', StringSplitOptions.RemoveEmptyEntries).TakeLast(3);
            LogFailed(logger, process.ExitCode, string.Join(" | ", tail));
            throw new InvalidOperationException("The speech recognizer stopped with an error.");
        }
        return Parse(text);
    }

    /// <summary>One word per line with its own times, in the given language, without a translation.</summary>
    public static IReadOnlyList<string> Arguments(string modelPath, string language, int threads) =>
    [
        "-m", modelPath, "-f", "-", "-l", language, "-t", threads.ToString(CultureInfo.InvariantCulture),
        "-ml", "1", "-sow", "-np",
    ];

    private static int Threads() => Math.Clamp(Environment.ProcessorCount - 1, 1, 8);

    /// <summary>
    /// Words from whisper.cpp's lines "[00:00:01.230 --> 00:00:01.560]  word". Lines without
    /// speech such as "[Music]" or "(applause)" are left out.
    /// </summary>
    public static IReadOnlyList<SpeechWord> Parse(string output)
    {
        var words = new List<SpeechWord>();
        foreach (var raw in output.Split('\n'))
        {
            var match = LinePattern().Match(raw.TrimEnd('\r'));
            if (!match.Success) continue;
            var text = match.Groups[3].Value.Trim();
            if (text.Length == 0 || (text.StartsWith('[') && text.EndsWith(']')) || (text.StartsWith('(') && text.EndsWith(')'))) continue;
            if (Time(match.Groups[1].Value) is not { } start || Time(match.Groups[2].Value) is not { } end) continue;
            // Punctuation that whisper hands out as its own token belongs to the word before it.
            if (words.Count > 0 && text.All(character => char.IsPunctuation(character)))
            {
                words[^1] = words[^1] with { Text = words[^1].Text + text, End = Math.Max(words[^1].End, end) };
                continue;
            }
            words.Add(new SpeechWord(text, start, Math.Max(start, end)));
        }
        return words;
    }

    private static double? Time(string text)
    {
        var parts = text.Split(':');
        if (parts.Length != 3) return null;
        if (!int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var hours)
            || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var minutes)
            || !double.TryParse(parts[2].Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds)) return null;
        return hours * 3600 + minutes * 60 + seconds;
    }

    /// <summary>16-bit mono PCM at 16 kHz as a WAV file in memory, for the program's standard input.</summary>
    public static byte[] Wav(ReadOnlySpan<short> samples, int sampleRate = 16_000)
    {
        var data = samples.Length * 2;
        var bytes = new byte[44 + data];
        void Text(int at, string value) => Encoding.ASCII.GetBytes(value).CopyTo(bytes, at);
        void Int(int at, int value) => BitConverter.TryWriteBytes(bytes.AsSpan(at, 4), value);
        void Short(int at, short value) => BitConverter.TryWriteBytes(bytes.AsSpan(at, 2), value);
        Text(0, "RIFF");
        Int(4, 36 + data);
        Text(8, "WAVE");
        Text(12, "fmt ");
        Int(16, 16);
        Short(20, 1);
        Short(22, 1);
        Int(24, sampleRate);
        Int(28, sampleRate * 2);
        Short(32, 2);
        Short(34, 16);
        Text(36, "data");
        Int(40, data);
        for (var index = 0; index < samples.Length; index++) BitConverter.TryWriteBytes(bytes.AsSpan(44 + index * 2, 2), samples[index]);
        return bytes;
    }

    [GeneratedRegex(@"^\s*\[(\d+:\d+:\d+[.,]\d+)\s*-->\s*(\d+:\d+:\d+[.,]\d+)\]\s?(.*)$")]
    private static partial Regex LinePattern();

    [LoggerMessage(Level = LogLevel.Warning, Message = "whisper.cpp failed with exit code {ExitCode}: {Errors}")]
    private static partial void LogFailed(ILogger logger, int exitCode, string errors);
}
