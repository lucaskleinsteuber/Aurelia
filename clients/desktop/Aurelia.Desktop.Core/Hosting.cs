using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text.Json;
using Microsoft.Win32;

namespace Aurelia.Desktop.Core;

/// <summary>
/// "When the Server Runs", as on the Mac: whether this computer's server keeps running in the
/// notification area when the window closes, starts when the person signs in, and keeps the
/// computer from falling asleep while it runs.
/// </summary>
public sealed record HostingPreferences(bool KeepRunning, bool StartAtSignIn, bool KeepAwake)
{
    /// <summary>On Windows a set-up server keeps running and starts with Windows, so the Apple TV always finds it.</summary>
    public static HostingPreferences ForThisComputer => new(OperatingSystem.IsWindows(), OperatingSystem.IsWindows(), false);
}

/// <summary>Remembers the hosting choices. Not a secret, only a preference.</summary>
public sealed class HostingPreferencesStore(string path)
{
    public static HostingPreferencesStore Default => new(Path.Combine(DesktopPaths.DataDirectory, "hosting.json"));

    /// <summary>Null until the person's server was set up and the choices were first saved.</summary>
    public HostingPreferences? Load()
    {
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize<HostingPreferences>(File.ReadAllText(path), AureliaServerApi.Json) : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    public void Save(HostingPreferences preferences)
    {
        DesktopPaths.EnsurePrivateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(preferences, AureliaServerApi.Json));
        File.Move(temporary, path, overwrite: true);
    }
}

/// <summary>Whether Windows starts Aurelia when the person signs in.</summary>
public enum SignInStart { Off, On, TurnedOffInWindows }

/// <summary>What the operating system offers for hosting; tests replace it.</summary>
public interface ISystemHosting
{
    bool CanStartAtSignIn { get; }
    SignInStart StartAtSignIn { get; }
    void SetStartAtSignIn(bool enabled);
    bool CanKeepAwake { get; }
    /// <summary>Keeps the computer from sleeping on its own while true; the screen may still turn off.</summary>
    void KeepAwake(bool enabled);
}

public static class SystemHosting
{
    public static ISystemHosting ForThisComputer() =>
        OperatingSystem.IsWindows() && Environment.ProcessPath is { } executable ? new WindowsSystemHosting(executable) : new NoSystemHosting();
}

/// <summary>macOS and Linux development builds: the server runs while the app runs, nothing else.</summary>
internal sealed class NoSystemHosting : ISystemHosting
{
    public bool CanStartAtSignIn => false;
    public SignInStart StartAtSignIn => SignInStart.Off;
    public void SetStartAtSignIn(bool enabled) { }
    public bool CanKeepAwake => false;
    public void KeepAwake(bool enabled) { }
}

/// <summary>
/// Windows: the person's own Run entry starts Aurelia in the notification area at sign-in (no
/// administrator rights, and Task Manager's Startup apps can turn it off), and a power request keeps
/// the PC from sleeping while the server runs, as <c>powercfg /requests</c> shows.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed partial class WindowsSystemHosting(string executable) : ISystemHosting
{
    internal const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    internal const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    internal const string ValueName = "Aurelia";
    private readonly Lock gate = new();
    private readonly string command = $"\"{executable}\" --background";
    private nint request;

    public bool CanStartAtSignIn => true;

    public SignInStart StartAtSignIn
    {
        get
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey);
            if (run?.GetValue(ValueName) is not string value || !string.Equals(value, command, StringComparison.OrdinalIgnoreCase)) return SignInStart.Off;
            using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
            // Task Manager marks a startup app it turned off with an odd first byte.
            return approved?.GetValue(ValueName) is byte[] { Length: > 0 } state && (state[0] & 1) == 1 ? SignInStart.TurnedOffInWindows : SignInStart.On;
        }
    }

    public void SetStartAtSignIn(bool enabled)
    {
        using (var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true)) approved?.DeleteValue(ValueName, throwOnMissingValue: false);
        using var run = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        if (enabled) run.SetValue(ValueName, command, RegistryValueKind.String);
        else run.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    public bool CanKeepAwake => true;

    public void KeepAwake(bool enabled)
    {
        lock (gate)
        {
            if (enabled && request == 0)
            {
                var reason = Marshal.StringToHGlobalUni("Aurelia Server is running so other devices can play from this PC.");
                try
                {
                    var context = new ReasonContext { Version = 0, Flags = 1, SimpleReasonString = reason };
                    var created = PowerCreateRequest(in context);
                    if (created == -1) return;
                    if (PowerSetRequest(created, PowerRequestSystemRequired)) request = created;
                    else CloseHandle(created);
                }
                finally { Marshal.FreeHGlobal(reason); }
            }
            else if (!enabled && request != 0)
            {
                PowerClearRequest(request, PowerRequestSystemRequired);
                CloseHandle(request);
                request = 0;
            }
        }
    }

    private const int PowerRequestSystemRequired = 1;

    /// <summary>REASON_CONTEXT with a simple reason string; the padding covers the larger detailed form.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct ReasonContext
    {
        public uint Version;
        public uint Flags;
        public nint SimpleReasonString;
        private readonly nint padding1;
        private readonly nint padding2;
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    private static partial nint PowerCreateRequest(in ReasonContext context);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PowerSetRequest(nint request, int type);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PowerClearRequest(nint request, int type);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(nint handle);
}

/// <summary>
/// Applies the hosting choices for this computer's server. A newly set-up server takes the
/// platform's defaults (on Windows: keep running and start with Windows); start at sign-in is
/// only registered while this computer hosts, and the PC stays awake only while the server runs.
/// </summary>
public sealed class HostingController : INotifyPropertyChanged
{
    private readonly ILocalServerHost host;
    private readonly HostingPreferencesStore store;
    private readonly ISystemHosting system;
    private HostingPreferences current;

    public HostingController(ILocalServerHost host, HostingPreferencesStore store, ISystemHosting system, HostingPreferences defaults,
        Action<Action> dispatch)
    {
        this.host = host;
        this.store = store;
        this.system = system;
        current = store.Load() ?? defaults;
        host.Changed += () => dispatch(HostChanged);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public HostingPreferences Current => current;
    public bool CanStartAtSignIn => system.CanStartAtSignIn;
    public bool CanKeepAwake => system.CanKeepAwake;
    public string? Error { get; private set => Set(ref field, value, nameof(Error), nameof(HasError)); }
    public bool HasError => Error is not null;

    public bool KeepRunning
    {
        get => current.KeepRunning;
        // Starting at sign-in only makes sense for a server that keeps running.
        set => Change(current with { KeepRunning = value, StartAtSignIn = value && current.StartAtSignIn });
    }

    public bool StartAtSignIn
    {
        get => current.StartAtSignIn;
        set => Change(current with { StartAtSignIn = value && current.KeepRunning });
    }

    public bool KeepAwake
    {
        get => current.KeepAwake;
        set => Change(current with { KeepAwake = value });
    }

    /// <summary>Closing the window leaves the server running: it is set up here and the person wants that.</summary>
    public bool RunsInBackground => current.KeepRunning && host.Info?.IsSetup == true && host.State != LocalServerState.Stopped;

    /// <summary>What closing Aurelia does to the server, as the choices stand.</summary>
    public string Explanation => !current.KeepRunning
        ? "The server stops when you close Aurelia."
        : OperatingSystem.IsWindows()
            ? "To stop the server, choose Quit Aurelia from its icon in the notification area."
            : "To stop the server, choose Quit Aurelia from its icon in the menu bar.";

    /// <summary>A short state for the notification area.</summary>
    public string StatusText => host.State switch
    {
        LocalServerState.Running => "Aurelia Server is running",
        LocalServerState.Starting or LocalServerState.Restarting => "Aurelia Server is starting…",
        LocalServerState.SetupRequired => "Aurelia Server is waiting for setup",
        LocalServerState.Failed => "Aurelia Server needs attention",
        _ => "Aurelia Server is stopped",
    };

    /// <summary>This computer no longer hosts (another server was chosen): Windows stops starting Aurelia.</summary>
    public void HostingEnded()
    {
        try
        {
            if (system.CanStartAtSignIn) system.SetStartAtSignIn(false);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            Error = "Windows could not stop starting Aurelia when you sign in. " + error.Message;
        }
        system.KeepAwake(false);
    }

    private void HostChanged()
    {
        if (host.State == LocalServerState.Running && host.Info?.IsSetup == true)
        {
            Apply(saveFirst: store.Load() is null);
        }
        system.KeepAwake(current.KeepAwake && host.State is LocalServerState.Running or LocalServerState.Restarting or LocalServerState.Starting);
        Changed(nameof(StatusText), nameof(RunsInBackground));
    }

    /// <summary>Brings Windows in line with the choices; one turned off in Task Manager stays off.</summary>
    private void Apply(bool saveFirst)
    {
        try
        {
            if (saveFirst) store.Save(current);
            if (!system.CanStartAtSignIn) return;
            var actual = system.StartAtSignIn;
            if (actual == SignInStart.TurnedOffInWindows)
            {
                if (!current.StartAtSignIn) return;
                current = current with { StartAtSignIn = false };
                store.Save(current);
                Changed(nameof(StartAtSignIn));
                return;
            }
            if (actual == SignInStart.On != current.StartAtSignIn) system.SetStartAtSignIn(current.StartAtSignIn);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            Error = "Aurelia could not save when the server runs. " + error.Message;
        }
    }

    private void Change(HostingPreferences value)
    {
        if (value == current) return;
        current = value;
        Error = null;
        try
        {
            store.Save(value);
            if (system.CanStartAtSignIn && host.Info?.IsSetup == true && host.State != LocalServerState.Stopped)
                system.SetStartAtSignIn(value.StartAtSignIn);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            Error = "Aurelia could not save when the server runs. " + error.Message;
        }
        system.KeepAwake(value.KeepAwake && host.State is LocalServerState.Running or LocalServerState.Restarting or LocalServerState.Starting);
        Changed(nameof(KeepRunning), nameof(StartAtSignIn), nameof(KeepAwake), nameof(RunsInBackground), nameof(Current), nameof(Explanation));
    }

    private void Changed(params string[] names)
    {
        foreach (var name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private void Set<T>(ref T field, T value, params string[] names)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Changed(names);
    }
}

/// <summary>
/// Windows lets other devices reach the server only on networks marked Private (the installer's
/// firewall rule covers those). A network marked Public needs the person to change it.
/// </summary>
public static class NetworkProfile
{
    public static Func<bool> PublicNetworkCheck => OperatingSystem.IsWindows() ? OnPublicNetwork : () => false;

    [SupportedOSPlatform("windows")]
    private static bool OnPublicNetwork()
    {
        try
        {
            // Network List Manager, as Windows Settings uses it: connected networks and their category.
            if (Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B")) is not { } type) return false;
            dynamic manager = Activator.CreateInstance(type)!;
            foreach (var network in manager.GetNetworks(1))
                if ((int)network.GetCategory() == 0) return true;
            return false;
        }
        catch (Exception error) when (error is COMException or InvalidCastException or NotSupportedException
            or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException or TypeLoadException)
        {
            return false;
        }
    }
}
