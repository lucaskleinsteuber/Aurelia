using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Playback;

/// <summary>Settings › Playback, with the Mac app's defaults and allowed values (PlaybackEngine.swift).</summary>
public sealed record PlaybackPreferences(
    bool AutomaticResume = true,
    bool AutoplayNextEpisode = true,
    int UpNextCountdownSeconds = 20,
    int ResumeThresholdSeconds = 0,
    bool PreventSleep = true,
    bool NightMode = false,
    double DefaultRate = 1,
    double DefaultVolume = 1,
    int ControlsHideDelaySeconds = 2,
    int SeekIntervalSeconds = 10,
    string DefaultAudioLanguage = "original",
    string DefaultSubtitleLanguage = "off",
    DialogueBoost DialogueBoost = DialogueBoost.Off,
    VolumeLeveling? VolumeLeveling = null,
    bool FillsScreen = false,
    StreamingQuality StreamingQuality = StreamingQuality.Original,
    IntroSkipping IntroSkipping = IntroSkipping.Button,
    bool UpNextAtCredits = true)
{
    [JsonIgnore]
    public VolumeLeveling EffectiveLeveling => VolumeLeveling ?? (NightMode ? Playback.VolumeLeveling.Standard : Playback.VolumeLeveling.Off);
    [JsonIgnore]
    public AudioProcessing AudioProcessing => new(DialogueBoost, EffectiveLeveling);

    public const string Key = "playback.preferences.v1";
    public static readonly int[] Countdowns = [5, 10, 15, 20, 30];
    public static readonly int[] ResumeThresholds = [0, 30, 60, 120];
    public static readonly int[] HideDelays = [2, 3, 5, 8];
    public static readonly string[] Languages = ["en", "de", "fr", "es", "it", "ja"];

    /// <summary>Values outside the allowed choices fall back to the defaults, as on the Mac.</summary>
    public PlaybackPreferences Normalized()
    {
        var defaults = new PlaybackPreferences();
        return this with
        {
            DialogueBoost = Enum.IsDefined(DialogueBoost) ? DialogueBoost : Playback.DialogueBoost.Off,
            StreamingQuality = Enum.IsDefined(StreamingQuality) ? StreamingQuality : Playback.StreamingQuality.Original,
            IntroSkipping = Enum.IsDefined(IntroSkipping) ? IntroSkipping : Playback.IntroSkipping.Button,
            VolumeLeveling = Enum.IsDefined(EffectiveLeveling) ? EffectiveLeveling : Playback.VolumeLeveling.Off,
            NightMode = Enum.IsDefined(EffectiveLeveling) && EffectiveLeveling != Playback.VolumeLeveling.Off,
            UpNextCountdownSeconds = Countdowns.Contains(UpNextCountdownSeconds) ? UpNextCountdownSeconds : defaults.UpNextCountdownSeconds,
            ResumeThresholdSeconds = ResumeThresholds.Contains(ResumeThresholdSeconds) ? ResumeThresholdSeconds : 0,
            DefaultRate = PlayerPolicy.Rates.Contains(DefaultRate) ? DefaultRate : 1,
            DefaultVolume = Math.Clamp(DefaultVolume, 0, 1),
            ControlsHideDelaySeconds = HideDelays.Contains(ControlsHideDelaySeconds) ? ControlsHideDelaySeconds : 2,
            SeekIntervalSeconds = Math.Clamp(SeekIntervalSeconds / 5 * 5, 5, 60),
            DefaultAudioLanguage = DefaultAudioLanguage == "original" || Languages.Contains(DefaultAudioLanguage) ? DefaultAudioLanguage : "original",
            DefaultSubtitleLanguage = DefaultSubtitleLanguage == "off" || Languages.Contains(DefaultSubtitleLanguage) ? DefaultSubtitleLanguage : "off",
        };
    }

    public static PlaybackPreferences Load(ISettingsStore store)
    {
        try
        {
            return (store.Read<PlaybackPreferences>(Key) ?? new PlaybackPreferences()).Normalized();
        }
        catch (JsonException)
        {
            return new PlaybackPreferences();
        }
    }

    public void Save(ISettingsStore store) => store.Write(Key, Normalized());
}

/// <summary>
/// Remembered audio and subtitle choices, per profile, as on the Mac: the series' own choice first,
/// then the last choice made anywhere, then the default language. At most 300 series are kept.
/// </summary>
public sealed class TrackMemory(ISettingsStore store, Guid profileId)
{
    public const int MaximumSeries = 300;

    private string AudioKey => $"playback.preferredAudioTrack.{profileId}";

    private string SubtitleKey => $"playback.preferredSubtitleTrack.{profileId}";

    private string SeriesKey => $"playback.seriesTrackChoices.{profileId}.v1";

    public TrackChoice? LastAudio => store.Read<TrackChoice>(AudioKey);

    public TrackChoice? LastSubtitle => store.Read<TrackChoice>(SubtitleKey);

    public SeriesChoice? ForSeries(Guid? seriesId) =>
        seriesId is { } id ? store.Read<List<SeriesChoice>>(SeriesKey)?.FirstOrDefault(choice => choice.SeriesId == id) : null;

    public void RememberAudio(MediaTrack track, Guid? seriesId)
    {
        var choice = new TrackChoice(track.Language, track.Name, Off: false);
        store.Write(AudioKey, choice);
        UpdateSeries(seriesId, current => current with { Audio = choice });
    }

    public void RememberSubtitle(MediaTrack? track, Guid? seriesId)
    {
        var choice = track is null ? new TrackChoice(null, null, Off: true) : new TrackChoice(track.Language, track.Name, Off: false);
        store.Write(SubtitleKey, choice);
        UpdateSeries(seriesId, current => current with { Subtitle = choice });
    }

    /// <summary>"Forget Track Choices" in Settings › Playback.</summary>
    public void Forget()
    {
        store.Remove(AudioKey);
        store.Remove(SubtitleKey);
        store.Remove(SeriesKey);
    }

    private void UpdateSeries(Guid? seriesId, Func<SeriesChoice, SeriesChoice> change)
    {
        if (seriesId is not { } id) return;
        var list = store.Read<List<SeriesChoice>>(SeriesKey) ?? [];
        var existing = list.FirstOrDefault(choice => choice.SeriesId == id) ?? new SeriesChoice(id, null, null);
        list.RemoveAll(choice => choice.SeriesId == id);
        list.Insert(0, change(existing));
        if (list.Count > MaximumSeries) list.RemoveRange(MaximumSeries, list.Count - MaximumSeries);
        store.Write(SeriesKey, list);
    }

    /// <summary>
    /// The track to choose: exact language and name first, then language only. Without any memory,
    /// the default language applies ("original" keeps the file's default audio, "off" no subtitles).
    /// </summary>
    public static MediaTrack? Pick(IReadOnlyList<MediaTrack> tracks, TrackChoice? remembered, string defaultLanguage)
    {
        if (remembered is { Off: true }) return null;
        if (remembered is { } choice)
        {
            var exact = tracks.FirstOrDefault(t => Same(t.Language, choice.Language) && t.Name == choice.Name);
            if (exact is not null) return exact;
            var language = tracks.Where(t => !t.IsForced).FirstOrDefault(t => choice.Language is not null && Same(t.Language, choice.Language));
            if (language is not null) return language;
        }
        if (defaultLanguage is "original" or "off") return null;
        return tracks.Where(t => !t.IsForced).FirstOrDefault(t => Same(t.Language, defaultLanguage));
    }

    /// <summary>Language codes from VLC ("eng", "ger") and settings ("en", "de") compare equal.</summary>
    public static bool Same(string? left, string? right) => left is not null && right is not null && Normalize(left) == Normalize(right);

    public static string Normalize(string code) => code.Trim().ToLowerInvariant() switch
    {
        "eng" or "en" or "english" => "en",
        "deu" or "ger" or "de" or "german" or "deutsch" => "de",
        "fra" or "fre" or "fr" or "french" => "fr",
        "spa" or "es" or "spanish" => "es",
        "ita" or "it" or "italian" => "it",
        "jpn" or "ja" or "japanese" => "ja",
        var other => other,
    };
}

/// <summary>What the player does while an episode's intro plays (Mac: IntroSkipping).</summary>
public enum IntroSkipping
{
    /// <summary>Nothing is offered; the intro plays.</summary>
    Off,
    /// <summary>A Skip Intro button is offered while the intro plays.</summary>
    Button,
    /// <summary>The intro is skipped without asking, once per episode.</summary>
    Automatic,
}

public sealed record TrackChoice(string? Language, string? Name, bool Off);

public sealed record SeriesChoice(Guid SeriesId, TrackChoice? Audio, TrackChoice? Subtitle);
