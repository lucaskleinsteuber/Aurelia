namespace Tarven.Server.Services;

/// <summary>
/// Tarven was called Aurelia until server 3.0.0. These names stay only so a server finds and
/// takes over what it wrote under the old name, and so apps from that time still reach it; nothing
/// new is written under them. A few values never changed because data or older apps depend on
/// them: the data protection application name "Aurelia.Server" (Program.cs), the protector purpose
/// "Aurelia.DeviceAuthorization.v1", the move key info "aurelia-move", the signed passkey message
/// "aurelia-passkey-v1" and the file markers AURBK001 and AUSTPV01.
/// </summary>
public static class LegacyNames
{
    /// <summary>The data folder of a server on a Mac or Windows computer.</summary>
    public const string ServerFolderName = "Aurelia Server";
    /// <summary>The data folder under $XDG_DATA_HOME on Linux.</summary>
    public const string LinuxDataFolderName = "aurelia";
    public const string DatabaseFileName = "aurelia.db";
    /// <summary>Request and response headers of apps from before the rename.</summary>
    public const string HeaderPrefix = "X-Aurelia-";
    public const string CookiePrefix = "aurelia_";
    public const string ServiceType = "_aurelia._tcp";
    public const string BackupExtension = ".aureliabackup";
    public const string MoveExtension = ".aureliamove";
    public const string DatabaseBackupPrefix = "aurelia-database-";
    /// <summary>Configuration keys ("Aurelia:Ffmpeg", AURELIA_DATA_DIR) still apply under the new name.</summary>
    public const string ConfigurationSection = "Aurelia";

    /// <summary>
    /// The default data folder, taking over the one of the old name once: when only the old folder
    /// exists it is renamed. A server still running there keeps it, and this one then stops on its lock.
    /// </summary>
    public static string AdoptDefaultDataDirectory(string current, string legacy)
    {
        if (Directory.Exists(current) || !Directory.Exists(legacy)) return current;
        try
        {
            using (ServerInstanceLock.Acquire(legacy)) { }
            Directory.Move(legacy, current);
            return current;
        }
        catch (Exception error) when (error is InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            return legacy;
        }
    }

    /// <summary>
    /// The database file. A data folder from before the rename keeps its database under the old
    /// name until the server holds the folder's lock and renames it together with its journal files.
    /// </summary>
    public static string DatabasePath(string dataDirectory) => Path.Combine(dataDirectory, "tarven.db");

    /// <summary>
    /// Renames aurelia.db (and -wal, -shm, -journal) to tarven.db and the database backups in
    /// Backups to their new names; only while holding the folder's lock.
    /// </summary>
    public static void AdoptDatabase(string dataDirectory)
    {
        var backups = Path.Combine(dataDirectory, "Backups");
        if (Directory.Exists(backups))
        {
            foreach (var file in Directory.EnumerateFiles(backups, DatabaseBackupPrefix + "*.db"))
            {
                var renamed = Path.Combine(backups, "tarven-database-" + Path.GetFileName(file)[DatabaseBackupPrefix.Length..]);
                if (new FileInfo(file).LinkTarget is null && !File.Exists(renamed)) File.Move(file, renamed);
            }
        }
        var current = DatabasePath(dataDirectory);
        var legacy = Path.Combine(dataDirectory, DatabaseFileName);
        if (File.Exists(current) || !File.Exists(legacy)) return;
        foreach (var suffix in new[] { "-wal", "-shm", "-journal" })
        {
            if (File.Exists(legacy + suffix) && !File.Exists(current + suffix)) File.Move(legacy + suffix, current + suffix);
        }
        File.Move(legacy, current);
    }

    /// <summary>The value of a request header, under its new name or the one older apps send.</summary>
    public static string? Header(HttpRequest request, string name)
    {
        if (!name.StartsWith("X-Tarven-", StringComparison.Ordinal)) return request.Headers[name].FirstOrDefault();
        var value = request.Headers[name].FirstOrDefault();
        return !string.IsNullOrEmpty(value) ? value
            : request.Headers[HeaderPrefix + name["X-Tarven-".Length..]].FirstOrDefault();
    }

    /// <summary>Whether a request carries the header under either name.</summary>
    public static bool HasHeader(HttpRequest request, string name) =>
        request.Headers.ContainsKey(name)
        || (name.StartsWith("X-Tarven-", StringComparison.Ordinal)
            && request.Headers.ContainsKey(HeaderPrefix + name["X-Tarven-".Length..]));

    /// <summary>
    /// Adds every "Aurelia:…" setting (appsettings, AURELIA__… variables) under "Tarven:…" unless
    /// the new name already sets it.
    /// </summary>
    public static void MapConfiguration(IConfigurationManager configuration)
    {
        var mapped = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (var (key, value) in configuration.AsEnumerable())
        {
            if (value is null || !key.StartsWith(ConfigurationSection + ":", StringComparison.OrdinalIgnoreCase)) continue;
            var renamed = "Tarven" + key[ConfigurationSection.Length..];
            if (configuration[renamed] is null) mapped[renamed] = value;
        }
        if (mapped.Count > 0) configuration.AddInMemoryCollection(mapped);
    }
}
