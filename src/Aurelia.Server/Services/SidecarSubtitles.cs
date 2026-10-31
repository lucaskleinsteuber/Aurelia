using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public sealed record DiscoveredSidecarSubtitle(
    string FilePath,
    string Format,
    string? Language,
    string? Title,
    bool IsDefault,
    bool IsForced,
    bool IsSdh,
    bool Supported);

public static partial class SidecarSubtitles
{
    public const int MaximumFileBytes = 5 * 1024 * 1024; // 5 MB cap

    private static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".srt", ".vtt", ".ass", ".ssa"
    };

    private static readonly HashSet<string> BitmapExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".sub", ".idx"
    };

    private static readonly ConcurrentDictionary<string, CachedSubtitle> MemoryCache = new();
    // Converted subtitles are small; the cap keeps a few large files from filling a small server's memory.
    private const long MaximumCachedBytes = 32 * 1024 * 1024;
    private const int MaximumCachedFileBytes = 2 * 1024 * 1024;
    private static long cachedBytes;

    private sealed record CachedSubtitle(long LastModifiedTicks, long FileLength, byte[] Content);

    /// <summary>
    /// Subtitle files that belong to a video, in a stable order (track numbers are positions in
    /// this list). Next to the video they must be named after it ("Movie.srt", "Movie.en.forced.srt");
    /// in a "Subs" or "Subtitles" folder they may also sit in a folder named after the video, and
    /// when the video is alone in its folder any subtitle there counts. Links are never followed,
    /// so a subtitle name cannot expose a file outside the media folder.
    /// </summary>
    public static IReadOnlyList<DiscoveredSidecarSubtitle> Discover(string videoPath)
    {
        if (string.IsNullOrWhiteSpace(videoPath)) return [];
        var video = new FileInfo(videoPath);
        if (!video.Exists || video.Directory is not { Exists: true, LinkTarget: null } directory) return [];

        var baseName = Path.GetFileNameWithoutExtension(video.Name);
        var candidates = new List<FileInfo>();
        try
        {
            candidates.AddRange(directory.EnumerateFiles().Where(file => BelongsTo(file.Name, baseName)));
            var alone = directory.EnumerateFiles().Count(file => MediaLibraryScanner.IsSupportedMediaPath(file.Name)) == 1;
            foreach (var folder in directory.EnumerateDirectories().Where(IsSubtitleFolder))
            {
                candidates.AddRange(folder.EnumerateFiles().Where(file => alone || BelongsTo(file.Name, baseName)));
                if (folder.EnumerateDirectories().FirstOrDefault(child => child.LinkTarget is null
                        && string.Equals(child.Name, baseName, StringComparison.OrdinalIgnoreCase)) is { } named)
                    candidates.AddRange(named.EnumerateFiles());
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            // An unreadable folder only means no sidecar subtitles.
        }

        return candidates
            .Where(file => file.LinkTarget is null && IsSubtitleExtension(file.Extension))
            .DistinctBy(file => file.FullName, StringComparer.Ordinal)
            .OrderBy(file => file.FullName, StringComparer.Ordinal)
            .Select(file => Describe(file, baseName))
            .ToList();
    }

    private static bool IsSubtitleFolder(DirectoryInfo folder) =>
        folder.LinkTarget is null && (string.Equals(folder.Name, "Subs", StringComparison.OrdinalIgnoreCase)
            || string.Equals(folder.Name, "Subtitles", StringComparison.OrdinalIgnoreCase));

    private static bool IsSubtitleExtension(string extension) =>
        TextExtensions.Contains(extension) || BitmapExtensions.Contains(extension);

    /// <summary>"Movie.srt" and "Movie.en.srt" belong to "Movie.mkv"; "Movie 2.srt" does not.</summary>
    private static bool BelongsTo(string fileName, string baseName)
    {
        var name = Path.GetFileNameWithoutExtension(fileName);
        return name.Length == baseName.Length
            ? string.Equals(name, baseName, StringComparison.OrdinalIgnoreCase)
            : name.Length > baseName.Length && name[baseName.Length] == '.'
                && name.StartsWith(baseName, StringComparison.OrdinalIgnoreCase);
    }

    private static DiscoveredSidecarSubtitle Describe(FileInfo file, string baseName)
    {
        var (language, isForced, isSdh, isDefault, title) = ParseTags(baseName, Path.GetFileNameWithoutExtension(file.Name));
        var format = file.Extension.TrimStart('.').ToLowerInvariant() switch
        {
            "srt" => "subrip",
            "vtt" => "webvtt",
            "sub" or "idx" => "vobsub",
            var other => other,
        };
        return new DiscoveredSidecarSubtitle(file.FullName, format, language, title, isDefault, isForced, isSdh,
            Supported: TextExtensions.Contains(file.Extension));
    }

    public static (string? Language, bool IsForced, bool IsSdh, bool IsDefault, string? Title) ParseTags(string videoBaseName, string subtitleBaseName)
    {
        string tagPart;
        if (subtitleBaseName.StartsWith(videoBaseName, StringComparison.OrdinalIgnoreCase))
        {
            tagPart = subtitleBaseName[videoBaseName.Length..].TrimStart('.', '_', '-', ' ');
        }
        else
        {
            tagPart = subtitleBaseName;
        }

        var tokens = tagPart.Split(['.', '_', '-', ' '], StringSplitOptions.RemoveEmptyEntries);
        string? detectedLanguage = null;
        var isForced = false;
        var isSdh = false;
        var isDefault = false;

        foreach (var token in tokens)
        {
            var lower = token.ToLowerInvariant();
            if (lower is "forced" or "force")
            {
                isForced = true;
            }
            else if (lower is "sdh" or "cc")
            {
                isSdh = true;
            }
            else if (lower is "default" or "def")
            {
                isDefault = true;
            }
            else if (detectedLanguage == null && TryParseLanguage(lower, out var lang))
            {
                detectedLanguage = lang;
            }
        }

        string? title = null;
        if (detectedLanguage != null)
        {
            try
            {
                var culture = CultureInfo.GetCultureInfo(detectedLanguage);
                title = culture.EnglishName;
            }
            catch
            {
                title = detectedLanguage;
            }
        }

        if (isForced && title != null) title += " (Forced)";
        if (isSdh && title != null) title += " (SDH)";

        return (detectedLanguage, isForced, isSdh, isDefault, title);
    }

    public static bool TryParseLanguage(string token, out string language)
    {
        language = string.Empty;
        var lower = token.ToLowerInvariant();

        // 2-letter codes
        if (lower.Length == 2 && char.IsLetter(lower[0]) && char.IsLetter(lower[1]))
        {
            language = lower;
            return true;
        }

        // 3-letter codes to ISO 639-1
        var map3 = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["eng"] = "en",
            ["deu"] = "de",
            ["ger"] = "de",
            ["fra"] = "fr",
            ["fre"] = "fr",
            ["spa"] = "es",
            ["ita"] = "it",
            ["jpn"] = "ja",
            ["zho"] = "zh",
            ["chi"] = "zh",
            ["por"] = "pt",
            ["rus"] = "ru",
            ["nld"] = "nl",
            ["dut"] = "nl",
            ["swe"] = "sv",
            ["nor"] = "no",
            ["dan"] = "da",
            ["fin"] = "fi",
            ["pol"] = "pl",
            ["ces"] = "cs",
            ["cze"] = "cs",
            ["ell"] = "el",
            ["gre"] = "el",
            ["tur"] = "tr",
            ["kor"] = "ko",
            ["ara"] = "ar",
            ["heb"] = "he",
            ["hin"] = "hi",
            ["tha"] = "th",
            ["vie"] = "vi",
            ["ind"] = "id",
            ["ukr"] = "uk",
            ["ron"] = "ro",
            ["rum"] = "ro",
            ["hun"] = "hu"
        };
        if (map3.TryGetValue(lower, out var mapped2))
        {
            language = mapped2;
            return true;
        }

        // Common language names
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["english"] = "en",
            ["german"] = "de",
            ["deutsch"] = "de",
            ["french"] = "fr",
            ["francais"] = "fr",
            ["français"] = "fr",
            ["spanish"] = "es",
            ["espanol"] = "es",
            ["español"] = "es",
            ["italian"] = "it",
            ["italiano"] = "it",
            ["japanese"] = "ja",
            ["chinese"] = "zh",
            ["portuguese"] = "pt",
            ["russian"] = "ru",
            ["dutch"] = "nl",
            ["swedish"] = "sv",
            ["norwegian"] = "no",
            ["danish"] = "da",
            ["finnish"] = "fi",
            ["polish"] = "pl",
            ["czech"] = "cs",
            ["greek"] = "el",
            ["turkish"] = "tr",
            ["korean"] = "ko",
            ["arabic"] = "ar",
            ["hebrew"] = "he"
        };
        if (names.TryGetValue(lower, out var mappedName))
        {
            language = mappedName;
            return true;
        }

        return false;
    }

    public static async Task<byte[]> ReadAsWebVttAsync(string filePath, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(filePath) || !File.Exists(filePath))
            throw new FileNotFoundException("Subtitle file not found.", filePath);

        var fileInfo = new FileInfo(filePath);
        if (fileInfo.LinkTarget is not null)
            throw new FileNotFoundException("Subtitle file not found.", filePath);
        if (fileInfo.Length > MaximumFileBytes)
            throw new InvalidOperationException($"Subtitle file exceeds maximum permitted size of {MaximumFileBytes} bytes.");

        var ticks = fileInfo.LastWriteTimeUtc.Ticks;
        var length = fileInfo.Length;

        if (MemoryCache.TryGetValue(filePath, out var cached) && cached.LastModifiedTicks == ticks && cached.FileLength == length)
        {
            return cached.Content;
        }

        byte[] rawBytes;
        await using (var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.Asynchronous | FileOptions.SequentialScan))
        {
            if (stream.Length > MaximumFileBytes)
                throw new InvalidOperationException($"Subtitle file exceeds maximum permitted size of {MaximumFileBytes} bytes.");
            rawBytes = new byte[stream.Length];
            var read = 0;
            while (read < rawBytes.Length)
            {
                var count = await stream.ReadAsync(rawBytes.AsMemory(read, rawBytes.Length - read), cancellationToken);
                if (count == 0) break;
                read += count;
            }
        }

        var text = DecodeText(rawBytes);
        var ext = Path.GetExtension(filePath).ToLowerInvariant();

        string vtt;
        if (ext == ".vtt")
        {
            vtt = NormalizeWebVtt(text);
        }
        else if (ext is ".ass" or ".ssa")
        {
            vtt = ConvertAssToWebVtt(text);
        }
        else
        {
            vtt = ConvertSrtToWebVtt(text);
        }

        var resultBytes = Encoding.UTF8.GetBytes(vtt);
        if (resultBytes.Length <= MaximumCachedFileBytes)
        {
            if (MemoryCache.Count >= 100 || Interlocked.Read(ref cachedBytes) + resultBytes.Length > MaximumCachedBytes)
            {
                MemoryCache.Clear();
                Interlocked.Exchange(ref cachedBytes, 0);
            }
            if (MemoryCache.TryAdd(filePath, new CachedSubtitle(ticks, length, resultBytes)))
                Interlocked.Add(ref cachedBytes, resultBytes.Length);
            else
                MemoryCache[filePath] = new CachedSubtitle(ticks, length, resultBytes);
        }
        return resultBytes;
    }

    public static string DecodeText(byte[] bytes)
    {
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            return Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);

        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
            return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);

        if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
            return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);

        // Try UTF-8 without BOM
        try
        {
            var utf8Strict = new UTF8Encoding(false, true);
            return utf8Strict.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            // Fallback to Windows-1252 (or ISO-8859-1)
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            try
            {
                var win1252 = Encoding.GetEncoding(1252);
                return win1252.GetString(bytes);
            }
            catch
            {
                return Encoding.Latin1.GetString(bytes);
            }
        }
    }

    public static string NormalizeWebVtt(string input)
    {
        var normalized = input.Replace("\r\n", "\n").Replace('\r', '\n');
        if (!normalized.StartsWith("WEBVTT", StringComparison.OrdinalIgnoreCase))
        {
            normalized = "WEBVTT\n\n" + normalized.TrimStart();
        }
        return normalized;
    }

    // Some tools write one-digit hours ("0:00:01,000") or a dot before the milliseconds.
    [GeneratedRegex(@"^(\d{1,3}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{1,3}):(\d{2}):(\d{2})[,.](\d{3})", RegexOptions.Multiline)]
    private static partial Regex SrtTimestampRegex();

    public static string ConvertSrtToWebVtt(string srt)
    {
        var normalized = srt.Replace("\r\n", "\n").Replace('\r', '\n');
        // WebVTT needs at least two hour digits and a dot before the milliseconds.
        var convertedTimestamps = SrtTimestampRegex().Replace(normalized, match =>
            $"{match.Groups[1].Value.PadLeft(2, '0')}:{match.Groups[2].Value}:{match.Groups[3].Value}.{match.Groups[4].Value} --> "
            + $"{match.Groups[5].Value.PadLeft(2, '0')}:{match.Groups[6].Value}:{match.Groups[7].Value}.{match.Groups[8].Value}");

        var sb = new StringBuilder();
        sb.AppendLine("WEBVTT");
        sb.AppendLine();
        sb.Append(convertedTimestamps.Trim());
        sb.AppendLine();
        return sb.ToString();
    }

    public static string ConvertAssToWebVtt(string ass)
    {
        var lines = ass.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        var sb = new StringBuilder();
        sb.AppendLine("WEBVTT");
        sb.AppendLine();

        var inEvents = false;
        int startIndex = -1;
        int endIndex = -1;
        int textIndex = -1;

        foreach (var rawLine in lines)
        {
            var line = rawLine.Trim();
            if (line.StartsWith("[Events]", StringComparison.OrdinalIgnoreCase))
            {
                inEvents = true;
                continue;
            }
            if (line.StartsWith('[') && inEvents)
            {
                inEvents = false;
                continue;
            }
            if (!inEvents) continue;

            if (line.StartsWith("Format:", StringComparison.OrdinalIgnoreCase))
            {
                var fields = line["Format:".Length..].Split(',').Select(f => f.Trim().ToLowerInvariant()).ToList();
                startIndex = fields.IndexOf("start");
                endIndex = fields.IndexOf("end");
                textIndex = fields.IndexOf("text");
                continue;
            }

            if (line.StartsWith("Dialogue:", StringComparison.OrdinalIgnoreCase) && startIndex >= 0 && endIndex >= 0 && textIndex >= 0)
            {
                var content = line["Dialogue:".Length..].Trim();
                var parts = SplitAssDialogue(content, Math.Max(startIndex, Math.Max(endIndex, textIndex)) + 1);
                if (parts.Count > Math.Max(startIndex, Math.Max(endIndex, textIndex)))
                {
                    var start = FormatAssTimestamp(parts[startIndex].Trim());
                    var end = FormatAssTimestamp(parts[endIndex].Trim());
                    var text = CleanAssText(parts[textIndex].Trim());

                    if (!string.IsNullOrWhiteSpace(text))
                    {
                        sb.AppendLine(CultureInfo.InvariantCulture, $"{start} --> {end}");
                        sb.AppendLine(text);
                        sb.AppendLine();
                    }
                }
            }
        }

        return sb.ToString();
    }

    private static List<string> SplitAssDialogue(string line, int minParts)
    {
        var result = new List<string>();
        var current = 0;
        for (var i = 0; i < minParts - 1; i++)
        {
            var comma = line.IndexOf(',', current);
            if (comma == -1) break;
            result.Add(line[current..comma]);
            current = comma + 1;
        }
        if (current < line.Length)
        {
            result.Add(line[current..]);
        }
        return result;
    }

    private static string FormatAssTimestamp(string assTime)
    {
        // ASS format: H:MM:SS.CC or HH:MM:SS.CC
        var parts = assTime.Split([':', '.']);
        if (parts.Length == 4 &&
            int.TryParse(parts[0], out var h) &&
            int.TryParse(parts[1], out var m) &&
            int.TryParse(parts[2], out var s) &&
            int.TryParse(parts[3], out var cs))
        {
            var ms = cs * 10;
            return string.Create(CultureInfo.InvariantCulture, $"{h:D2}:{m:D2}:{s:D2}.{ms:D3}");
        }
        return assTime;
    }

    [GeneratedRegex(@"\{[^}]*\}")]
    private static partial Regex AssOverrideTagRegex();

    public static string CleanAssText(string text)
    {
        var cleaned = text.Replace("\\N", "\n").Replace("\\n", "\n");
        cleaned = AssOverrideTagRegex().Replace(cleaned, match =>
        {
            var content = match.Value;
            var sb = new StringBuilder();
            if (content.Contains("\\i1", StringComparison.Ordinal)) sb.Append("<i>");
            if (content.Contains("\\i0", StringComparison.Ordinal)) sb.Append("</i>");
            if (content.Contains("\\b1", StringComparison.Ordinal)) sb.Append("<b>");
            if (content.Contains("\\b0", StringComparison.Ordinal)) sb.Append("</b>");
            return sb.ToString();
        });
        return cleaned.Trim();
    }
}
