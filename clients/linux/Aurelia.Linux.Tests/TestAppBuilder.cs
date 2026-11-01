using Aurelia.Linux;
using Aurelia.Linux.Tests;
using Avalonia;
using Avalonia.Headless;
using Xunit;

[assembly: AvaloniaTestApplication(typeof(TestAppBuilder))]
// The headless views share one UI dispatcher. Parallel test classes queue behind it and can
// exhaust the runner's dispatch timeout before a test starts on a slower Linux computer.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Aurelia.Linux.Tests;

/// <summary>Runs the real app styles and views without a screen; frames are drawn by Skia so they can be inspected.</summary>
public static class TestAppBuilder
{
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>()
        .UseSkia()
        .UseHarfBuzz()
        .WithInterFont()
        .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false });
}
