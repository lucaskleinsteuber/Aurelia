namespace Aurelia.Contracts;

/// <summary>
/// Subtitle downloads from OpenSubtitles.com. The owner enters their own free API key (and
/// optionally an OpenSubtitles account for more downloads a day). Downloaded subtitles live in the
/// server's data folder, never next to the media, and play like subtitle files beside the video.
/// </summary>
public sealed record SubtitleProviderStatus(
    bool Enabled,
    bool HasApiKey,
    bool HasAccount,
    string? AccountName,
    IReadOnlyList<string> Languages,
    bool Automatic,
    string Provider,
    string Attribution,
    int? RemainingDownloads,
    DateTimeOffset? ResetsAt,
    DateTimeOffset? LastAutomaticRunAt,
    int DownloadedCount);

/// <summary>
/// Null key or account fields keep what is saved. Languages are two-letter codes ("de", "en"),
/// at most five, in order of preference.
/// </summary>
public sealed record UpdateSubtitleProviderRequest(
    bool Enabled,
    IReadOnlyList<string> Languages,
    bool Automatic,
    string? ApiKey = null,
    string? AccountName = null,
    string? AccountPassword = null);

public sealed record SubtitleCandidate(
    string FileId,
    string Language,
    string? Release,
    bool HashMatch,
    bool HearingImpaired,
    bool ForeignPartsOnly,
    bool MachineTranslated,
    int DownloadCount,
    bool FromTrusted);

public sealed record DownloadSubtitleRequest(
    string FileId,
    string Language,
    string? Release = null,
    bool HearingImpaired = false,
    bool ForeignPartsOnly = false);

public sealed record DownloadedSubtitle(
    Guid Id,
    string Language,
    string Title,
    bool HearingImpaired,
    bool Forced,
    string Provider,
    string? Release,
    DateTimeOffset DownloadedAt,
    bool Automatic);
