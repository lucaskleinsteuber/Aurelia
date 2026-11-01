using Aurelia.Linux.Views;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace Aurelia.Linux;

public sealed class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            if (desktop.Args?.Contains("--background") == true)
            {
                // Started at login to host the server: no window until it is opened from the icon.
                var services = AppServices.CreateDefault();
                var window = new MainWindow(services, startSession: false);
                if (window.Flow.Mode == Core.Flow.OperatingMode.Host && Core.Platform.HostingSettings.Read(services.Settings).KeepRunning)
                {
                    desktop.ShutdownMode = Avalonia.Controls.ShutdownMode.OnExplicitShutdown;
                    _ = window.StartInBackgroundAsync();
                    base.OnFrameworkInitializationCompleted();
                    return;
                }
                window.Opened += async (_, _) => await window.Session.StartAsync();
                desktop.MainWindow = window;
            }
            else
            {
                desktop.MainWindow = new MainWindow();
            }
        }
        base.OnFrameworkInitializationCompleted();
    }
}
