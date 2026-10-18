using Avalonia;
using Avalonia.Headless;

[assembly: AvaloniaTestApplication(typeof(Aurelia.Desktop.Tests.TestAppBuilder))]

namespace Aurelia.Desktop.Tests;

/// <summary>Runs the real app styles and views headless with Skia: no window ever appears.</summary>
public static class TestAppBuilder
{
    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UseSkia()
            .WithInterFont()
            .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false });
}
