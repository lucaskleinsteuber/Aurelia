using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Management;

/// <summary>The subtitle languages Settings offers, with English names that need no system locale data.</summary>
public static class SubtitleLanguages
{
    private static readonly (string Code, string Name)[] Known =
    [
        ("en", "English"), ("de", "German"), ("fr", "French"), ("es", "Spanish"), ("it", "Italian"), ("nl", "Dutch"),
        ("pt", "Portuguese"), ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"), ("fi", "Finnish"), ("pl", "Polish"),
        ("cs", "Czech"), ("tr", "Turkish"), ("ru", "Russian"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("ar", "Arabic"),
    ];

    public static IReadOnlyList<string> Choices { get; } = [.. Known.Select(language => language.Code)];

    public static string Name(string code) =>
        Known.FirstOrDefault(language => language.Code == code).Name ?? code;

    public static string Names(IEnumerable<string> codes) => string.Join(", ", codes.Select(Name));

    /// <summary>Adds or removes a language; at least one and at most five stay chosen.</summary>
    public static IReadOnlyList<string> Toggle(IReadOnlyList<string> chosen, string code)
    {
        var next = chosen.Contains(code) ? chosen.Where(language => language != code).ToList() : [.. chosen, code];
        return next.Count is 0 or > 5 ? chosen : next;
    }

    /// <summary>"Matches this file · SDH · 1,204 downloads", the facts that help choose a subtitle.</summary>
    public static string Details(SubtitleCandidate candidate)
    {
        var parts = new List<string>();
        if (candidate.HashMatch) parts.Add("Matches this file");
        if (candidate.HearingImpaired) parts.Add("SDH");
        if (candidate.ForeignPartsOnly) parts.Add("Foreign parts only");
        if (candidate.MachineTranslated) parts.Add("Machine translated");
        if (candidate.FromTrusted) parts.Add("Trusted");
        parts.Add(candidate.DownloadCount.ToString("N0", System.Globalization.CultureInfo.InvariantCulture) + " downloads");
        return string.Join(" · ", parts);
    }
}
