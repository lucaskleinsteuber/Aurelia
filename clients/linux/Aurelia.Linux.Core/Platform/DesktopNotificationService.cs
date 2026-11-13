using Aurelia.Linux.Core.Library;
using Tmds.DBus.Protocol;

namespace Aurelia.Linux.Core.Platform;

/// <summary>Shows a desktop notification for wish updates when enabled in General settings.</summary>
public interface IDesktopNotificationService
{
    Task NotifyAsync(WishNotificationEvent notification, CancellationToken cancellation = default);
}

public sealed class NoDesktopNotificationService : IDesktopNotificationService
{
    public Task NotifyAsync(WishNotificationEvent notification, CancellationToken cancellation = default) => Task.CompletedTask;
}

/// <summary>Sends notifications via org.freedesktop.Notifications over the user's D-Bus session.</summary>
public sealed class FreedesktopNotificationService : IDesktopNotificationService
{
    private const string Service = "org.freedesktop.Notifications";
    private const string Path = "/org/freedesktop/Notifications";
    private const string Interface = "org.freedesktop.Notifications";

    public async Task NotifyAsync(WishNotificationEvent notification, CancellationToken cancellation = default)
    {
        DBusConnection? bus;
        try
        {
            bus = DBusConnection.Session;
        }
        catch (Exception error) when (error is DBusExceptionBase or IOException or InvalidOperationException or PlatformNotSupportedException)
        {
            return;
        }
        if (bus is null) return;
        try
        {
            var writer = bus.GetMessageWriter();
            MessageBuffer buffer;
            try
            {
                writer.WriteMethodCallHeader(
                    destination: Service,
                    path: Path,
                    @interface: Interface,
                    member: "Notify",
                    signature: "susssasa{sv}i");
                writer.WriteString("Aurelia");
                writer.WriteUInt32(0);
                writer.WriteString("io.github.lucasfd3.Aurelia");
                writer.WriteString(notification.Title);
                writer.WriteString(notification.Body);
                writer.WriteArray(Array.Empty<string>());
                writer.WriteDictionary(new Dictionary<string, VariantValue>
                {
                    ["desktop-entry"] = VariantValue.String("io.github.lucasfd3.Aurelia"),
                });
                writer.WriteInt32(-1);
                buffer = writer.CreateMessage();
            }
            finally
            {
                writer.Dispose();
            }
            await bus.CallMethodAsync(buffer, (message, _) => message.GetBodyReader().ReadUInt32(), null).WaitAsync(TimeSpan.FromSeconds(5), cancellation);
        }
        catch (Exception error) when (error is DBusExceptionBase or IOException or TimeoutException or OperationCanceledException or InvalidOperationException)
        {
            // Desktops without a notification daemon or running headless safely ignore notification failures.
        }
    }
}
