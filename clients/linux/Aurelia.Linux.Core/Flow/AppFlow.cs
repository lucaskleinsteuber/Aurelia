using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Flow;

/// <summary>Whether this computer runs the server itself or connects to one elsewhere.</summary>
public enum OperatingMode
{
    Host,
    Client,
}

/// <summary>The full-window screens, in the order the Mac app's RootView chooses them.</summary>
public enum AppScreen
{
    Starting,
    Introduction,
    Welcome,
    HostSetup,
    Connection,
    ServerUnreachable,
    ProfilePicker,
    InitialLibrarySetup,
    Library,
    /// <summary>Downloads only, without the server.</summary>
    Offline,
}

/// <summary>
/// Decides which full-window screen shows: the start screen while Aurelia gets ready, the welcome
/// choice until a mode is chosen, then host setup or the connection screen, the profile picker and
/// finally the library.
/// </summary>
public sealed class AppFlow : ObservableObject
{
    public const string OperatingModeKey = "operatingMode";

    private readonly ISettingsStore settings;
    private AppScreen screen = AppScreen.Starting;
    private OperatingMode? mode;

    public AppFlow(ISettingsStore settings)
    {
        this.settings = settings;
        mode = settings.Read<string>(OperatingModeKey) switch
        {
            "host" => OperatingMode.Host,
            "client" => OperatingMode.Client,
            _ => null,
        };
        Guide = new SetupGuide(settings, alreadySetUp: mode is not null);
    }

    /// <summary>The setup assistant; it decides whether the introduction comes before the welcome choice.</summary>
    public SetupGuide Guide { get; }

    public AppScreen Screen
    {
        get => screen;
        private set => SetProperty(ref screen, value);
    }

    public OperatingMode? Mode
    {
        get => mode;
        private set => SetProperty(ref mode, value);
    }

    /// <summary>Leaves the start screen once saved state is known.</summary>
    public void FinishStarting() => Screen = ScreenForMode();

    public void ChooseMode(OperatingMode chosen)
    {
        Mode = chosen;
        settings.Write(OperatingModeKey, chosen == OperatingMode.Host ? "host" : "client");
        Screen = ScreenForMode();
    }

    /// <summary>Back to the welcome choice, for "Connect to Another Server" and similar links.</summary>
    public void ReturnToWelcome()
    {
        Mode = null;
        settings.Remove(OperatingModeKey);
        Screen = AppScreen.Welcome;
    }

    public void Show(AppScreen next) => Screen = next;

    private AppScreen ScreenForMode() => Mode switch
    {
        OperatingMode.Host => AppScreen.HostSetup,
        OperatingMode.Client => AppScreen.Connection,
        _ => Guide.IntroSeen ? AppScreen.Welcome : AppScreen.Introduction,
    };

    /// <summary>"I Know Aurelia" on the introduction: the plain welcome choice follows.</summary>
    public void SkipIntroduction()
    {
        Guide.Skip();
        Screen = ScreenForMode();
    }

    /// <summary>The introduction's questions are answered: the guided setup starts where the media lives.</summary>
    public void StartGuidedSetup(OperatingMode chosen)
    {
        Guide.Start();
        ChooseMode(chosen);
    }
}
