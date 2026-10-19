using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop;

public sealed class App : Application
{
    /// <summary>How this process was started; set before Avalonia starts.</summary>
    internal static StartRequest Start { get; set; } = StartRequest.Open;
    /// <summary>This process as the one running Aurelia; null in tests.</summary>
    internal static AppInstance? Instance { get; set; }

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // The lifetime keeps the shell through its events until the app ends.
            var shell = new DesktopShell(this, desktop);
            Instance?.Listen(shell.HandleAsync);
            _ = shell.StartAsync(Start == StartRequest.Background);
        }
        base.OnFrameworkInitializationCompleted();
    }
}
