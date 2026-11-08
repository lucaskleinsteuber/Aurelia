using System.Text.Json;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Connection;

/// <summary>Keeps this computer's paired server connection in a safe place.</summary>
public interface ICredentialStore
{
    Task<StoredServer?> LoadAsync(CancellationToken cancellation);

    Task SaveAsync(StoredServer server, CancellationToken cancellation);

    Task DeleteAsync(CancellationToken cancellation);
}

/// <summary>Raised when the desktop has no keyring Aurelia can use; credentials are never written to a plain file instead.</summary>
public sealed class CredentialStoreUnavailableException(string message, Exception? inner = null) : Exception(message, inner)
{
    public static CredentialStoreUnavailableException NoKeyring(Exception? inner = null) => new(
        "Aurelia keeps its server connection in your desktop's keyring, but none is available. Install and start GNOME Keyring or KDE Wallet, then try again.",
        inner);

    public static CredentialStoreUnavailableException KeyringFailed(Exception? inner = null) => new(
        "Your desktop's keyring did not give Aurelia its saved connection. Unlock the keyring if it asks, then try again.",
        inner);
}

/// <summary>Holds the connection in memory, for tests.</summary>
public sealed class MemoryCredentialStore : ICredentialStore
{
    public StoredServer? Server { get; set; }

    public Task<StoredServer?> LoadAsync(CancellationToken cancellation) => Task.FromResult(Server);

    public Task SaveAsync(StoredServer server, CancellationToken cancellation)
    {
        Server = server;
        return Task.CompletedTask;
    }

    public Task DeleteAsync(CancellationToken cancellation)
    {
        Server = null;
        return Task.CompletedTask;
    }
}

/// <summary>The stored form of a connection inside the keyring item.</summary>
public static class StoredServerSerializer
{
    public static string Serialize(StoredServer server) => JsonSerializer.Serialize(server, AureliaJson.Options);

    public static StoredServer? Deserialize(string text)
    {
        try
        {
            var server = JsonSerializer.Deserialize<StoredServer>(text, AureliaJson.Options);
            return server is not null && ServerAddress.IsValid(server.Address) && ServerIdentity.IsValidFingerprint(server.Fingerprint)
                && server.DeviceToken.Length > 0 ? server : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
