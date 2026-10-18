using System.Text.Json;
using System.Text.RegularExpressions;

namespace Aurelia.Desktop.Core;

/// <summary>An audio or subtitle track as people recognize it again: its language and name.</summary>
public sealed record TrackChoice(string? Language, string Name)
{
    /// <summary>VLC names tracks like "Commentary - [English]"; the bracket holds the language.</summary>
    public static TrackChoice From(string name)
    {
        var match = Regex.Match(name, @"\[(?<language>[^\]]+)\]\s*$");
        return new TrackChoice(match.Success ? match.Groups["language"].Value.Trim() : null, name.Trim());
    }

    /// <summary>The same track if it exists, else one in the same language.</summary>
    public MediaTrack? Match(IReadOnlyList<MediaTrack> tracks)
    {
        var exact = tracks.FirstOrDefault(track => string.Equals(track.Name.Trim(), Name, StringComparison.OrdinalIgnoreCase));
        if (exact is not null || Language is null) return exact;
        return tracks.FirstOrDefault(track => string.Equals(From(track.Name).Language, Language, StringComparison.OrdinalIgnoreCase));
    }
}

/// <summary>A series' own track choices; "subtitles off" is a choice too.</summary>
public sealed record SeriesTracks(TrackChoice? Audio, TrackChoice? Subtitle, bool SubtitleChosen, DateTimeOffset UpdatedAt);

public sealed record PlaybackSettings(
    int Volume = 100,
    bool NightMode = false,
    bool AutoplayNext = true,
    TrackChoice? Audio = null,
    TrackChoice? Subtitle = null,
    bool SubtitleChosen = false,
    IReadOnlyDictionary<Guid, SeriesTracks>? Series = null);

/// <summary>Player preferences in this app's data folder; unreadable files fall back to defaults.</summary>
public sealed class PlaybackSettingsStore(string path)
{
    public const int SeriesLimit = 300;

    public static PlaybackSettingsStore Default => new(Path.Combine(DesktopPaths.DataDirectory, "playback.json"));

    public PlaybackSettings Load()
    {
        try
        {
            return File.Exists(path)
                ? JsonSerializer.Deserialize<PlaybackSettings>(File.ReadAllText(path), AureliaServerApi.Json) ?? new PlaybackSettings()
                : new PlaybackSettings();
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            return new PlaybackSettings();
        }
    }

    public void Save(PlaybackSettings settings)
    {
        try { SecretFiles.WriteAtomically(path, JsonSerializer.SerializeToUtf8Bytes(settings, AureliaServerApi.Json)); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public PlaybackSettings Update(Func<PlaybackSettings, PlaybackSettings> change)
    {
        var updated = change(Load());
        Save(updated);
        return updated;
    }

    /// <summary>Remembers a choice for the series and as the last choice anywhere.</summary>
    public PlaybackSettings Remember(Guid? series, TrackChoice? audio = null, TrackChoice? subtitle = null, bool subtitleChosen = false) =>
        Update(settings =>
        {
            var next = settings with
            {
                Audio = audio ?? settings.Audio,
                Subtitle = subtitleChosen ? subtitle : settings.Subtitle,
                SubtitleChosen = settings.SubtitleChosen || subtitleChosen,
            };
            if (series is not { } id) return next;
            var all = new Dictionary<Guid, SeriesTracks>(settings.Series ?? new Dictionary<Guid, SeriesTracks>());
            var current = all.GetValueOrDefault(id) ?? new SeriesTracks(null, null, false, DateTimeOffset.UtcNow);
            all[id] = current with
            {
                Audio = audio ?? current.Audio,
                Subtitle = subtitleChosen ? subtitle : current.Subtitle,
                SubtitleChosen = current.SubtitleChosen || subtitleChosen,
                UpdatedAt = DateTimeOffset.UtcNow,
            };
            if (all.Count > SeriesLimit)
                foreach (var oldest in all.OrderBy(pair => pair.Value.UpdatedAt).Take(all.Count - SeriesLimit).ToList()) all.Remove(oldest.Key);
            return next with { Series = all };
        });
}
