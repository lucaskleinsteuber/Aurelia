using System.Text;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Connection;
using Tmds.DBus.Protocol;

namespace Aurelia.Linux.Core.Platform;

/// <summary>
/// Keeps the server connection in the desktop keyring through the freedesktop Secret Service
/// (GNOME Keyring, KDE Wallet and others), the Linux counterpart of the Mac Keychain. When the
/// keyring is locked, the desktop asks the person to unlock it. There is no plain-file fallback.
/// </summary>
public sealed class SecretServiceCredentialStore : ICredentialStore
{
    private const string Bus = "org.freedesktop.secrets";
    private const string ServicePath = "/org/freedesktop/secrets";
    private const string ServiceInterface = "org.freedesktop.Secret.Service";
    private const string ItemInterface = "org.freedesktop.Secret.Item";
    private const string CollectionInterface = "org.freedesktop.Secret.Collection";
    private const string PromptInterface = "org.freedesktop.Secret.Prompt";
    private const string NoPrompt = "/";

    private readonly Dictionary<string, string> attributes;
    private readonly string label;

    public SecretServiceCredentialStore(string purpose = "server-connection", string label = "Aurelia server connection")
    {
        attributes = new() { ["application"] = AppInfo.ApplicationId, ["purpose"] = purpose };
        this.label = label;
    }

    public async Task<StoredServer?> LoadAsync(CancellationToken cancellation) =>
        StoredServerSerializer.Deserialize(await LoadValueAsync(cancellation) ?? "");

    /// <summary>Reads only this store's purpose from the keyring; tokens use a separate purpose.</summary>
    public async Task<string?> LoadValueAsync(CancellationToken cancellation)
    {
        var connection = Connection();
        try
        {
            var session = await OpenSessionAsync(connection);
            var items = await UnlockedItemsAsync(connection);
            foreach (var item in items)
            {
                var secret = await GetSecretAsync(connection, item, session);
                return Encoding.UTF8.GetString(secret);
            }
            return null;
        }
        catch (DBusExceptionBase error)
        {
            throw Unavailable(error);
        }
    }

    public Task SaveAsync(StoredServer server, CancellationToken cancellation) =>
        SaveValueAsync(StoredServerSerializer.Serialize(server), cancellation);

    /// <summary>Writes a value to this store's purpose, never to a settings or token file.</summary>
    public async Task SaveValueAsync(string secret, CancellationToken cancellation)
    {
        var connection = Connection();
        try
        {
            var session = await OpenSessionAsync(connection);
            var collection = await DefaultCollectionAsync(connection);
            await UnlockAsync(connection, [collection]);
            var value = Encoding.UTF8.GetBytes(secret);
            var (_, prompt) = await connection.CallMethodAsync(CreateItemMessage(connection, collection, session, value), (message, _) =>
            {
                var reader = message.GetBodyReader();
                return (reader.ReadObjectPathAsString(), reader.ReadObjectPathAsString());
            }, null);
            await CompletePromptAsync(connection, prompt);
        }
        catch (DBusExceptionBase error)
        {
            throw Unavailable(error);
        }
    }

    public async Task DeleteAsync(CancellationToken cancellation)
    {
        var connection = Connection();
        try
        {
            foreach (var item in await UnlockedItemsAsync(connection))
            {
                var prompt = await connection.CallMethodAsync(Call(connection, item, ItemInterface, "Delete", null, (ref MessageWriter _) => { }),
                    (message, _) => message.GetBodyReader().ReadObjectPathAsString(), null);
                await CompletePromptAsync(connection, prompt);
            }
        }
        catch (DBusExceptionBase error)
        {
            throw Unavailable(error);
        }
    }

    /// <summary>
    /// "No keyring" only when no Secret Service answers on the bus; a keyring that is there but
    /// refused, timed out or stayed locked gets its own message, so nobody installs one again.
    /// </summary>
    internal static CredentialStoreUnavailableException Unavailable(Exception error) =>
        NoKeyringErrors.Any(name => error.Message.Contains(name, StringComparison.Ordinal))
            ? CredentialStoreUnavailableException.NoKeyring(error)
            : CredentialStoreUnavailableException.KeyringFailed(error);

    private static readonly string[] NoKeyringErrors =
    [
        "org.freedesktop.DBus.Error.ServiceUnknown",
        "org.freedesktop.DBus.Error.NameHasNoOwner",
        "org.freedesktop.DBus.Error.Spawn",
    ];

    private static DBusConnection Connection() =>
        DBusConnection.Session ?? throw CredentialStoreUnavailableException.NoKeyring();

    /// <summary>A "plain" session: the secret travels unencrypted, but only over this user's private session bus.</summary>
    private static Task<string> OpenSessionAsync(DBusConnection connection) =>
        connection.CallMethodAsync(Call(connection, ServicePath, ServiceInterface, "OpenSession", "sv", (ref MessageWriter writer) =>
        {
            writer.WriteString("plain");
            writer.WriteVariantString("");
        }), (message, _) =>
        {
            var reader = message.GetBodyReader();
            reader.ReadVariantValue();
            return reader.ReadObjectPathAsString();
        }, null);

    private async Task<string[]> UnlockedItemsAsync(DBusConnection connection)
    {
        var (unlocked, locked) = await connection.CallMethodAsync(Call(connection, ServicePath, ServiceInterface, "SearchItems", "a{ss}",
            (ref MessageWriter writer) => WriteStringDictionary(ref writer, attributes)), (message, _) =>
        {
            var reader = message.GetBodyReader();
            return (reader.ReadArrayOfObjectPath().Select(path => path.ToString()).ToArray(),
                reader.ReadArrayOfObjectPath().Select(path => path.ToString()).ToArray());
        }, null);
        if (locked.Length == 0) return unlocked;
        return [.. unlocked, .. await UnlockAsync(connection, locked)];
    }

    private static async Task<string[]> UnlockAsync(DBusConnection connection, string[] objects)
    {
        var (unlocked, prompt) = await connection.CallMethodAsync(Call(connection, ServicePath, ServiceInterface, "Unlock", "ao",
            (ref MessageWriter writer) => writer.WriteArray(objects.Select(path => new ObjectPath(path)).ToArray())), (message, _) =>
        {
            var reader = message.GetBodyReader();
            return (reader.ReadArrayOfObjectPath().Select(path => path.ToString()).ToArray(), reader.ReadObjectPathAsString());
        }, null);
        if (prompt == NoPrompt) return unlocked;
        await CompletePromptAsync(connection, prompt);
        return objects;
    }

    private static async Task<string> DefaultCollectionAsync(DBusConnection connection)
    {
        var path = await connection.CallMethodAsync(Call(connection, ServicePath, ServiceInterface, "ReadAlias", "s",
            (ref MessageWriter writer) => writer.WriteString("default")), (message, _) => message.GetBodyReader().ReadObjectPathAsString(), null);
        if (path != NoPrompt) return path;
        // A keyring without a default collection (rare): ask the desktop to create one.
        var (created, prompt) = await connection.CallMethodAsync(Call(connection, ServicePath, ServiceInterface, "CreateCollection", "a{sv}s", (ref MessageWriter writer) =>
        {
            var start = writer.WriteDictionaryStart();
            writer.WriteDictionaryEntryStart();
            writer.WriteString("org.freedesktop.Secret.Collection.Label");
            writer.WriteVariantString("Login");
            writer.WriteDictionaryEnd(start);
            writer.WriteString("default");
        }), (message, _) =>
        {
            var reader = message.GetBodyReader();
            return (reader.ReadObjectPathAsString(), reader.ReadObjectPathAsString());
        }, null);
        if (created != NoPrompt) return created;
        await CompletePromptAsync(connection, prompt);
        return await connection.CallMethodAsync(Call(connection, ServicePath, ServiceInterface, "ReadAlias", "s",
            (ref MessageWriter writer) => writer.WriteString("default")), (message, _) => message.GetBodyReader().ReadObjectPathAsString(), null);
    }

    private static Task<byte[]> GetSecretAsync(DBusConnection connection, string item, string session) =>
        connection.CallMethodAsync(Call(connection, item, ItemInterface, "GetSecret", "o", (ref MessageWriter writer) => writer.WriteObjectPath(session)),
            (message, _) =>
            {
                var reader = message.GetBodyReader();
                reader.AlignStruct();
                reader.ReadObjectPath();
                reader.ReadArrayOfByte();
                var value = reader.ReadArrayOfByte();
                reader.ReadString();
                return value;
            }, null);

    private MessageBuffer CreateItemMessage(DBusConnection connection, string collection, string session, byte[] value) =>
        Call(connection, collection, CollectionInterface, "CreateItem", "a{sv}(oayays)b", (ref MessageWriter writer) =>
        {
            var properties = writer.WriteDictionaryStart();
            writer.WriteDictionaryEntryStart();
            writer.WriteString("org.freedesktop.Secret.Item.Label");
            writer.WriteVariantString(label);
            writer.WriteDictionaryEntryStart();
            writer.WriteString("org.freedesktop.Secret.Item.Attributes");
            writer.WriteSignature("a{ss}");
            WriteStringDictionary(ref writer, attributes);
            writer.WriteDictionaryEnd(properties);
            writer.WriteStructureStart();
            writer.WriteObjectPath(session);
            writer.WriteArray(Array.Empty<byte>());
            writer.WriteArray(value);
            writer.WriteString("application/json");
            writer.WriteBool(true);
        });

    /// <summary>Shows the desktop's unlock or confirmation prompt and waits until the person answers it.</summary>
    private static async Task CompletePromptAsync(DBusConnection connection, string prompt)
    {
        if (prompt == NoPrompt) return;
        var completed = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var watch = await connection.WatchSignalAsync(Bus, prompt, PromptInterface, "Completed",
            (message, _) => message.GetBodyReader().ReadBool(),
            (Notification<bool> notification) =>
            {
                if (notification.Exception is { } error) completed.TrySetException(error);
                else if (notification.HasValue) completed.TrySetResult(notification.Value);
            }, ObserverFlags.None, false, null);
        await connection.CallMethodAsync(Call(connection, prompt, PromptInterface, "Prompt", "s", (ref MessageWriter writer) => writer.WriteString("")));
        if (await completed.Task)
            throw new CredentialStoreUnavailableException("The keyring stayed locked, so Aurelia cannot use its saved connection.");
    }

    private static void WriteStringDictionary(ref MessageWriter writer, IReadOnlyDictionary<string, string> values)
    {
        var start = writer.WriteDictionaryStart();
        foreach (var (key, value) in values)
        {
            writer.WriteDictionaryEntryStart();
            writer.WriteString(key);
            writer.WriteString(value);
        }
        writer.WriteDictionaryEnd(start);
    }

    private static MessageBuffer Call(DBusConnection connection, string path, string @interface, string member, string? signature,
        WriteMessageBody body)
    {
        var writer = connection.GetMessageWriter();
        try
        {
            writer.WriteMethodCallHeader(destination: Bus, path: path, @interface: @interface, signature: signature, member: member);
            body(ref writer);
            return writer.CreateMessage();
        }
        finally { writer.Dispose(); }
    }
}
