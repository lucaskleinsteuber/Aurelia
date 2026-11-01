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

    public async Task<StoredServer?> LoadAsync(CancellationToken cancellation)
    {
        var connection = Connection();
        try
        {
            var session = await OpenSessionAsync(connection);
            var items = await UnlockedItemsAsync(connection);
            foreach (var item in items)
            {
                var secret = await GetSecretAsync(connection, item, session);
                if (StoredServerSerializer.Deserialize(Encoding.UTF8.GetString(secret)) is { } server) return server;
            }
            return null;
        }
        catch (DBusExceptionBase error)
        {
            throw CredentialStoreUnavailableException.NoKeyring(error);
        }
    }

    public async Task SaveAsync(StoredServer server, CancellationToken cancellation)
    {
        var connection = Connection();
        try
        {
            var session = await OpenSessionAsync(connection);
            var collection = await DefaultCollectionAsync(connection);
            await UnlockAsync(connection, [collection]);
            var value = Encoding.UTF8.GetBytes(StoredServerSerializer.Serialize(server));
            var (_, prompt) = await connection.CallMethodAsync(CreateItemMessage(connection, collection, session, value), (message, _) =>
            {
                var reader = message.GetBodyReader();
                return (reader.ReadObjectPathAsString(), reader.ReadObjectPathAsString());
            }, null);
            await CompletePromptAsync(connection, prompt);
        }
        catch (DBusExceptionBase error)
        {
            throw CredentialStoreUnavailableException.NoKeyring(error);
        }
    }

    public async Task DeleteAsync(CancellationToken cancellation)
    {
        var connection = Connection();
        try
        {
            foreach (var item in await UnlockedItemsAsync(connection))
            {
                var prompt = await connection.CallMethodAsync(Call(connection, item, ItemInterface, "Delete", null, _ => { }),
                    (message, _) => message.GetBodyReader().ReadObjectPathAsString(), null);
                await CompletePromptAsync(connection, prompt);
            }
        }
        catch (DBusExceptionBase error)
        {
            throw CredentialStoreUnavailableException.NoKeyring(error);
        }
    }

    private static DBusConnection Connection() =>
        DBusConnection.Session ?? throw CredentialStoreUnavailableException.NoKeyring();

    /// <summary>A "plain" session: the secret travels unencrypted, but only over this user's private session bus.</summary>
    private static Task<string> OpenSessionAsync(DBusConnection connection) =>
        connection.CallMethodAsync(Call(connection, ServicePath, ServiceInterface, "OpenSession", "sv", writer =>
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
            writer => WriteStringDictionary(writer, attributes)), (message, _) =>
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
            writer => writer.WriteArray(objects.Select(path => new ObjectPath(path)).ToArray())), (message, _) =>
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
            writer => writer.WriteString("default")), (message, _) => message.GetBodyReader().ReadObjectPathAsString(), null);
        if (path != NoPrompt) return path;
        // A keyring without a default collection (rare): ask the desktop to create one.
        var (created, prompt) = await connection.CallMethodAsync(Call(connection, ServicePath, ServiceInterface, "CreateCollection", "a{sv}s", writer =>
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
            writer => writer.WriteString("default")), (message, _) => message.GetBodyReader().ReadObjectPathAsString(), null);
    }

    private static Task<byte[]> GetSecretAsync(DBusConnection connection, string item, string session) =>
        connection.CallMethodAsync(Call(connection, item, ItemInterface, "GetSecret", "o", writer => writer.WriteObjectPath(session)),
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
        Call(connection, collection, CollectionInterface, "CreateItem", "a{sv}(oayays)b", writer =>
        {
            var properties = writer.WriteDictionaryStart();
            writer.WriteDictionaryEntryStart();
            writer.WriteString("org.freedesktop.Secret.Item.Label");
            writer.WriteVariantString(label);
            writer.WriteDictionaryEntryStart();
            writer.WriteString("org.freedesktop.Secret.Item.Attributes");
            writer.WriteSignature("a{ss}");
            WriteStringDictionary(writer, attributes);
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
        await connection.CallMethodAsync(Call(connection, prompt, PromptInterface, "Prompt", "s", writer => writer.WriteString("")));
        if (await completed.Task)
            throw new CredentialStoreUnavailableException("The keyring stayed locked, so Aurelia cannot use its saved connection.");
    }

    private static void WriteStringDictionary(MessageWriter writer, IReadOnlyDictionary<string, string> values)
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
        Action<MessageWriter> body)
    {
        using var writer = connection.GetMessageWriter();
        writer.WriteMethodCallHeader(destination: Bus, path: path, @interface: @interface, signature: signature, member: member);
        body(writer);
        return writer.CreateMessage();
    }
}
