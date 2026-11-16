namespace Aurelia.Linux.Core.Settings;

/// <summary>
/// The main window's last size and whether it was maximized, so Aurelia opens the way it was closed.
/// Full screen is never restored; a window too small or absurdly large falls back to the default.
/// </summary>
public sealed record WindowPlacement(double Width, double Height, bool Maximized)
{
    public const string Key = "mainWindowPlacement";
    public const double MinimumWidth = 760;
    public const double MinimumHeight = 560;
    private const double Largest = 16384;

    public static WindowPlacement? Read(ISettingsStore store)
    {
        var saved = store.Read<WindowPlacement>(Key);
        if (saved is null) return null;
        var fits = saved.Width is >= MinimumWidth and <= Largest && saved.Height is >= MinimumHeight and <= Largest;
        return fits ? saved : saved.Maximized ? saved with { Width = 1280, Height = 800 } : null;
    }

    public void Save(ISettingsStore store) => store.Write(Key, this);
}
