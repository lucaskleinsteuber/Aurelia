using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Views;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Aurelia.Linux.Tests;

/// <summary>Opens the real main window with in-memory settings, so tests never touch the person's files.</summary>
internal static class TestWindows
{
    public static MainWindow Show(WindowButtonLayout? layout = null, ISettingsStore? settings = null)
    {
        var window = new MainWindow(new AppServices(settings ?? new MemorySettingsStore(), layout ?? WindowButtonLayout.Default))
        {
            Width = 1280,
            Height = 800,
        };
        window.Show();
        Dispatcher.UIThread.RunJobs();
        return window;
    }

    /// <summary>Keeps rendered frames for a person to look at when AURELIA_LINUX_SNAPSHOTS names a folder.</summary>
    public static void SaveSnapshot(Bitmap frame, string name)
    {
        var folder = Environment.GetEnvironmentVariable("AURELIA_LINUX_SNAPSHOTS");
        if (string.IsNullOrEmpty(folder)) return;
        Directory.CreateDirectory(folder);
        frame.Save(Path.Combine(folder, name + ".png"), PngBitmapEncoderOptions.Default);
    }
}
