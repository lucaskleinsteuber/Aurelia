using Tmds.DBus.Protocol;

namespace Aurelia.Linux.Core.Platform;

/// <summary>The desktop portal grants Flatpak background/autostart permission and a suspend/idle inhibitor.</summary>
internal interface IDesktopHostingPortal
{
    Task<(bool Background, bool Autostart)> RequestBackgroundAsync(bool autostart);
    Task<IDisposable?> InhibitAsync(string reason);
}

/// <summary>
/// Uses the XDG Background and Inhibit portals on the session bus. Subscribes before requesting
/// permission so an immediate response cannot be missed; responses run off the interface thread.
/// No host filesystem or system-bus access is needed by the Flatpak.
/// </summary>
internal sealed class DesktopHostingPortal : IDesktopHostingPortal
{
    private const string Destination = "org.freedesktop.portal.Desktop";
    private const string PortalPath = "/org/freedesktop/portal/desktop";
    private const string RequestInterface = "org.freedesktop.portal.Request";
    private static readonly string[] BackgroundCommand = AppInfo.IsTestEdition
        ? ["env", "AURELIA_EDITION=test", "aurelia-desktop", "--background"]
        : ["aurelia-desktop", "--background"];

    public async Task<(bool Background, bool Autostart)> RequestBackgroundAsync(bool autostart)
    {
        var bus = DBusConnection.Session ?? throw new InvalidOperationException("The desktop's background permission service is unavailable.");
        var token = "aurelia_" + Guid.NewGuid().ToString("N");
        var completed = new TaskCompletionSource<(uint Response, Dictionary<string, VariantValue> Results)>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var watch = await bus.AddMatchAsync(new MatchRule
        {
            Type = MessageType.Signal,
            Sender = Destination,
            Interface = RequestInterface,
            Member = "Response",
            PathNamespace = PortalPath + "/request",
        }, (message, _) =>
        {
            var reader = message.GetBodyReader();
            return (Path: message.PathAsString, Response: reader.ReadUInt32(), Results: reader.ReadDictionaryOfStringToVariantValue());
        }, (Notification<(string? Path, uint Response, Dictionary<string, VariantValue> Results)> notification) =>
        {
            if (notification.Exception is { } failure) completed.TrySetException(failure);
            else if (notification.HasValue && notification.Value.Path?.EndsWith("/" + token, StringComparison.Ordinal) == true)
                completed.TrySetResult((notification.Value.Response, notification.Value.Results));
        }, false, ObserverFlags.None, null);
        var handle = await bus.CallMethodAsync(Call(bus, PortalPath, "org.freedesktop.portal.Background", "RequestBackground", "sa{sv}", (ref MessageWriter writer) =>
        {
            writer.WriteString("");
            writer.WriteDictionary(new Dictionary<string, VariantValue>
            {
                ["handle_token"] = token,
                ["reason"] = "Keep this PC's Aurelia Server available to your devices",
                ["autostart"] = autostart,
                ["commandline"] = VariantValue.Array(BackgroundCommand),
                ["dbus-activatable"] = false,
            });
        }), (message, _) => message.GetBodyReader().ReadObjectPathAsString(), null);
        try
        {
            var response = await completed.Task.WaitAsync(TimeSpan.FromMinutes(2));
            return (response.Response == 0 && Allowed(response.Results, "background"), response.Response == 0 && Allowed(response.Results, "autostart"));
        }
        catch (TimeoutException)
        {
            await CloseAsync(bus, handle);
            throw new InvalidOperationException("The desktop did not answer the background permission request. Try again.");
        }
    }

    public async Task<IDisposable?> InhibitAsync(string reason)
    {
        var bus = DBusConnection.Session;
        if (bus is null) return null;
        var handle = await bus.CallMethodAsync(Call(bus, PortalPath, "org.freedesktop.portal.Inhibit", "Inhibit", "sua{sv}", (ref MessageWriter writer) =>
        {
            writer.WriteString("");
            writer.WriteUInt32(4 | 8); // Suspend and idle.
            writer.WriteDictionary(new Dictionary<string, VariantValue> { ["reason"] = reason });
        }), (message, _) => message.GetBodyReader().ReadObjectPathAsString(), null);
        return new Inhibition(bus, handle);
    }

    private static bool Allowed(Dictionary<string, VariantValue> values, string key) =>
        values.TryGetValue(key, out var value) && value.Type == VariantValueType.Bool && value.GetBool();

    private static MessageBuffer Call(DBusConnection bus, string path, string @interface, string method, string signature, WriteMessageBody body)
    {
        var writer = bus.GetMessageWriter();
        try
        {
            writer.WriteMethodCallHeader(destination: Destination, path: path, @interface: @interface, member: method, signature: signature);
            body(ref writer);
            return writer.CreateMessage();
        }
        finally { writer.Dispose(); }
    }

    private static async Task CloseAsync(DBusConnection bus, string handle)
    {
        try
        {
            await bus.CallMethodAsync(Call(bus, handle, RequestInterface, "Close", "", (ref MessageWriter _) => { }));
        }
        catch (DBusExceptionBase)
        {
            // The request can already be gone after a response or a desktop restart.
        }
    }

    private sealed class Inhibition(DBusConnection bus, string handle) : IDisposable
    {
        private int released;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref released, 1) == 0) _ = CloseAsync(bus, handle);
        }
    }
}
