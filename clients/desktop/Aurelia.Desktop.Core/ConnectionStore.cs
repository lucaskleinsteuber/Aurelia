using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Aurelia.Desktop.Core;

/// <summary>Where the paired server's credential is kept between app starts.</summary>
public interface ISecretStore
{
    string? Read();
    void Write(string value);
    void Delete();
}

/// <summary>
/// Windows encrypts the credential for the signed-in Windows user (DPAPI), so another account or a
/// copied file cannot use it.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsProtectedSecretStore(string path) : ISecretStore
{
    private static readonly byte[] Purpose = "Aurelia desktop server connection v1"u8.ToArray();

    public string? Read()
    {
        if (!File.Exists(path)) return null;
        try
        {
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(path), Purpose, DataProtectionScope.CurrentUser));
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    public void Write(string value) =>
        SecretFiles.WriteAtomically(path, ProtectedData.Protect(Encoding.UTF8.GetBytes(value), Purpose, DataProtectionScope.CurrentUser));

    public void Delete() => File.Delete(path);
}

/// <summary>
/// macOS and Linux development builds keep the credential in a file only the current user can
/// read. It is separate from the Mac app's keychain items and data.
/// </summary>
public sealed class PrivateFileSecretStore(string path) : ISecretStore
{
    public string? Read() => File.Exists(path) ? File.ReadAllText(path, Encoding.UTF8) : null;
    public void Write(string value) => SecretFiles.WriteAtomically(path, Encoding.UTF8.GetBytes(value));
    public void Delete() => File.Delete(path);
}

internal static class SecretFiles
{
    public static void WriteAtomically(string path, byte[] bytes)
    {
        var directory = Path.GetDirectoryName(path)!;
        DesktopPaths.EnsurePrivateDirectory(directory);
        var temporary = Path.Combine(directory, "." + Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        try
        {
            using (var stream = new FileStream(temporary, options))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}

/// <summary>The saved connection, or none. A damaged or unreadable entry counts as none.</summary>
public sealed class ConnectionStore(ISecretStore secrets)
{
    public StoredConnection? Load()
    {
        try
        {
            var text = secrets.Read();
            if (string.IsNullOrEmpty(text)) return null;
            var stored = JsonSerializer.Deserialize<StoredConnection>(text, AureliaServerApi.Json);
            return stored is not null && ServerAddress.IsValid(stored.Address) && ServerIdentity.IsValidFingerprint(stored.Fingerprint)
                && stored.DeviceToken.Length is >= 32 and <= 256
                ? stored
                : null;
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public void Save(StoredConnection connection) => secrets.Write(JsonSerializer.Serialize(connection, AureliaServerApi.Json));

    public void Clear()
    {
        try { secrets.Delete(); }
        catch (IOException) { }
    }
}

/// <summary>The app's own data folder, never the Mac app's or Aurelia Classic's.</summary>
public static class DesktopPaths
{
    public static string DataDirectory
    {
        get
        {
            if (Environment.GetEnvironmentVariable("AURELIA_DESKTOP_DATA_DIR") is { Length: > 0 } custom) return custom;
            if (OperatingSystem.IsWindows())
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Aurelia");
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (OperatingSystem.IsMacOS()) return Path.Combine(home, "Library", "Application Support", "Aurelia Desktop");
            var data = Environment.GetEnvironmentVariable("XDG_DATA_HOME") is { Length: > 0 } xdg ? xdg : Path.Combine(home, ".local", "share");
            return Path.Combine(data, "aurelia-desktop");
        }
    }

    public static ISecretStore CreateSecretStore()
    {
        var directory = DataDirectory;
        return OperatingSystem.IsWindows()
            ? new WindowsProtectedSecretStore(Path.Combine(directory, "connection.dat"))
            : new PrivateFileSecretStore(Path.Combine(directory, "connection.json"));
    }

    internal static void EnsurePrivateDirectory(string directory)
    {
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(directory);
        else Directory.CreateDirectory(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }
}
