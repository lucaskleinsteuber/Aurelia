using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;

namespace Aurelia.Desktop.Core;

/// <summary>
/// Settings › Playback for this computer, as on the Mac: how titles start, how the player behaves,
/// and the remembered track choices. Saved at once; the next title uses them.
/// </summary>
public sealed class PlaybackPreferencesModel(PlaybackSettingsStore store) : INotifyPropertyChanged
{
    public static readonly IReadOnlyList<string> RateNames = [.. PlayerPolicy.Rates.Select(rate => rate == 1 ? "Standard" : rate.ToString("0.##", CultureInfo.InvariantCulture) + "×")];
    private static readonly int[] Seeks = [5, 10, 15, 30, 60];
    public static readonly IReadOnlyList<string> SeekNames = [.. Seeks.Select(seconds => $"{seconds} seconds")];
    private static readonly int[] Hides = [2, 3, 5, 8];
    public static readonly IReadOnlyList<string> HideNames = [.. Hides.Select(seconds => $"{seconds} seconds")];
    private PlaybackSettings settings = store.Load();

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool AutoplayNext { get => settings.AutoplayNext; set => Save(settings with { AutoplayNext = value }); }
    public bool AutomaticResume { get => settings.AutomaticResume; set => Save(settings with { AutomaticResume = value }); }
    public bool KeepScreenOn { get => settings.KeepScreenOn; set => Save(settings with { KeepScreenOn = value }); }
    public bool NightMode { get => settings.NightMode; set => Save(settings with { NightMode = value }); }
    public int RateIndex
    {
        get => Math.Max(0, Array.IndexOf(PlayerPolicy.Rates, settings.DefaultRate));
        set => Save(settings with { DefaultRate = PlayerPolicy.Rates[Math.Clamp(value, 0, PlayerPolicy.Rates.Length - 1)] });
    }
    public int Volume { get => Math.Clamp(settings.Volume, 0, 100); set => Save(settings with { Volume = Math.Clamp(value, 0, 100) }); }
    public string VolumeText => $"{Volume}%";
    public int SeekIndex { get => Math.Max(0, Array.IndexOf(Seeks, settings.SeekSeconds)); set => Save(settings with { SeekSeconds = Seeks[Math.Clamp(value, 0, Seeks.Length - 1)] }); }
    public int HideIndex { get => Math.Max(0, Array.IndexOf(Hides, settings.HideSeconds)); set => Save(settings with { HideSeconds = Hides[Math.Clamp(value, 0, Hides.Length - 1)] }); }
    /// <summary>Only Windows keeps the screen on through Aurelia; elsewhere the system decides.</summary>
    public static bool CanKeepScreenOn => OperatingSystem.IsWindows();
    public bool HasTrackChoices => settings.Audio is not null || settings.SubtitleChosen || settings.Series is { Count: > 0 };
    public string? Notice { get; private set { if (field == value) return; field = value; Changed(nameof(Notice)); } }

    /// <summary>Audio and subtitle choices remembered for each series and last used anywhere.</summary>
    public void ForgetTrackChoices()
    {
        Save(settings with { Audio = null, Subtitle = null, SubtitleChosen = false, Series = null });
        Notice = "Aurelia forgot the audio and subtitle choices.";
    }

    public void RestoreDefaults()
    {
        var defaults = new PlaybackSettings();
        Save(defaults with { Audio = settings.Audio, Subtitle = settings.Subtitle, SubtitleChosen = settings.SubtitleChosen, Series = settings.Series });
        Notice = "Playback settings are back to their defaults.";
    }

    private void Save(PlaybackSettings value)
    {
        if (value == settings) return;
        settings = store.Update(_ => value);
        Changed(nameof(AutoplayNext), nameof(AutomaticResume), nameof(KeepScreenOn), nameof(NightMode), nameof(RateIndex), nameof(Volume),
            nameof(VolumeText), nameof(SeekIndex), nameof(HideIndex), nameof(HasTrackChoices));
    }

    private void Changed(params string[] names)
    {
        foreach (var name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
