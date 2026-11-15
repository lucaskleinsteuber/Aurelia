using System.Data.Common;
using System.Diagnostics;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Aurelia.Server.Services;

public sealed record MoveSample(string RelativePath, long Size);
public sealed record MoveLocation(Guid Id, string Name, string Path, IReadOnlyList<MoveSample> Samples);
public sealed record MoveManifest(int Version, Guid ServerId, string Name, string MoveToken, IReadOnlyList<string> SourceAddresses,
    IReadOnlyList<MoveLocation> Locations);
public sealed record MoveSuggestion(string Path, int Matched);
public sealed record MoveLocationMatch(int Sampled, int Matched);
public sealed record MoveLocationSuggestions(int Sampled, IReadOnlyList<MoveSuggestion> Suggestions);
public sealed record MovePathMapping(Guid Id, string? Path);

/// <summary>
/// Storage locations during a move: which sample files describe a location, where on this computer
/// the same files are, and rewriting the paths of a location and its titles. Media files are never
/// opened: a sample matches when a file of the same relative path has the same size, which a
/// directory entry tells (stat), and nothing here writes outside the server's database.
/// </summary>
public static class ServerMoveLocations
{
    public const int MaximumSamples = 200;
    public const int MaximumSuggestions = 5;
    public const int SearchDepth = 4;
    public const int MaximumSearchedFolders = 50_000;
    public static readonly TimeSpan SearchBudget = TimeSpan.FromSeconds(20);
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public static byte[] Serialize(MoveManifest manifest) => JsonSerializer.SerializeToUtf8Bytes(manifest, Json);

    public static MoveManifest Parse(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.LinkTarget is not null || info.Length > EncryptedBackupContainer.MaximumEntryBytes(EncryptedBackupContainer.MoveManifestName))
            throw new InvalidDataException("The move bundle has no move description.");
        var manifest = JsonSerializer.Deserialize<MoveManifest>(File.ReadAllBytes(path), Json);
        if (manifest is null || manifest.Version != 1 || manifest.ServerId == Guid.Empty || string.IsNullOrWhiteSpace(manifest.MoveToken)
            || manifest.MoveToken.Length > 256 || manifest.Name is null || manifest.Name.Length > 128
            || manifest.SourceAddresses is null || manifest.SourceAddresses.Count > 16 || manifest.SourceAddresses.Any(address => address is null || address.Length > 512)
            || manifest.Locations is null || manifest.Locations.Count > 1_000
            || manifest.Locations.Any(location => location is null || location.Id == Guid.Empty || location.Path is null || location.Path.Length > 4096
                || location.Name is null || location.Name.Length > 256 || location.Samples is null || location.Samples.Count > MaximumSamples
                || location.Samples.Any(sample => sample is null || !SafeRelative(sample.RelativePath) || sample.Size < 0)))
            throw new InvalidDataException("The move description is incompatible.");
        return manifest;
    }

    /// <summary>A relative path inside a location: no root, no "..", no NUL.</summary>
    public static bool SafeRelative(string? value) => !string.IsNullOrEmpty(value) && value.Length <= 4096 && !value.Contains('\0')
        && !Path.IsPathRooted(value) && !value.Replace('\\', '/').Split('/').Any(part => part == "..");

    /// <summary>
    /// Each storage location (or only <paramref name="only"/>) with up to <see cref="MaximumSamples"/>
    /// of its video files. Titles' ids are random, so taking them in id order spreads the samples over
    /// every folder of a large location and gives the same samples for every preview.
    /// </summary>
    public static async Task<IReadOnlyList<MoveLocation>> ReadLocationsAsync(string databasePath, CancellationToken token, Guid? only = null)
    {
        await using var database = new SqliteConnection(new SqliteConnectionStringBuilder
        { DataSource = databasePath, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        await database.OpenAsync(token);
        var roots = new List<(string Id, string Name, string Path)>();
        await using (var command = database.CreateCommand())
        {
            command.CommandText = "SELECT Id, Name, Path FROM LibraryRoots ORDER BY Name, Id;";
            await using var reader = await command.ExecuteReaderAsync(token);
            while (await reader.ReadAsync(token))
                if (only is null || Guid.TryParse(reader.GetString(0), out var id) && id == only)
                    roots.Add((reader.GetString(0), reader.GetString(1), reader.GetString(2)));
        }
        var result = new List<MoveLocation>();
        foreach (var root in roots)
        {
            var samples = new List<MoveSample>();
            await using var command = database.CreateCommand();
            command.CommandText = "SELECT SourcePath, FileSize FROM MediaItems WHERE LibraryRootId=$id AND Kind IN ('Movie','Episode','Extra','Trailer') "
                + "AND FileSize IS NOT NULL AND FileSize > 0 ORDER BY Id LIMIT $limit;";
            command.Parameters.AddWithValue("$id", root.Id);
            command.Parameters.AddWithValue("$limit", MaximumSamples);
            await using var reader = await command.ExecuteReaderAsync(token);
            while (await reader.ReadAsync(token))
                if (Relative(root.Path, reader.GetString(0)) is { Length: > 0 } relative && SafeRelative(relative))
                    samples.Add(new(relative, reader.GetInt64(1)));
            result.Add(new(Guid.Parse(root.Id), root.Name, root.Path, samples));
        }
        return result;
    }

    /// <summary>The path below a location's folder with "/" separators, or null when it isn't below it.</summary>
    public static string? Relative(string root, string source)
    {
        var trimmed = root.TrimEnd('/', '\\');
        if (trimmed.Length == 0) trimmed = root;
        foreach (var comparison in new[] { StringComparison.Ordinal, StringComparison.OrdinalIgnoreCase })
        {
            if (string.Equals(source.TrimEnd('/', '\\'), trimmed, comparison)) return string.Empty;
            if (source.Length > trimmed.Length && source.StartsWith(trimmed, comparison) && source[trimmed.Length] is '/' or '\\')
                return source[(trimmed.Length + 1)..].Replace('\\', '/');
        }
        return null;
    }

    /// <summary>How many samples a folder on this computer has: same relative path, same size.</summary>
    public static int CountMatches(string folder, IReadOnlyList<MoveSample> samples)
    {
        var matched = 0;
        foreach (var sample in samples)
        {
            try
            {
                var file = new FileInfo(Path.Join(folder, sample.RelativePath.Replace('/', Path.DirectorySeparatorChar)));
                if (file.Exists && file.Length == sample.Size) matched++;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException
                or ArgumentException or NotSupportedException or PathTooLongException)
            { }
        }
        return matched;
    }

    /// <summary>Folders the suggestions search: Linux's usual storage places and mount points, a Mac's volumes and home folder.</summary>
    public static IReadOnlyList<string> DefaultSearchRoots()
    {
        var roots = new List<string>();
        if (OperatingSystem.IsMacOS())
        {
            roots.Add("/Volumes");
            roots.Add(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        }
        else if (OperatingSystem.IsLinux())
        {
            roots.AddRange(["/mnt", "/media", "/srv", "/home"]);
            try
            {
                string[] system = ["/proc", "/sys", "/dev", "/run", "/boot", "/snap", "/var/lib/docker", "/tmp"];
                roots.AddRange(StorageMounts.ParseTargets(File.ReadLines("/proc/self/mounts"))
                    .Where(target => target != "/" && !system.Any(prefix => target == prefix || target.StartsWith(prefix + "/", StringComparison.Ordinal))));
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
        else
        {
            roots.Add(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        }
        return roots.Where(root => !string.IsNullOrEmpty(root)).Distinct(StringComparer.Ordinal).ToArray();
    }

    /// <summary>
    /// The folders on this computer that hold most of a location's samples, best first. The old path
    /// itself always counts as a candidate; the search walks readable, non-hidden folders up to
    /// <see cref="SearchDepth"/> levels below each root, never follows links, and stops after
    /// <paramref name="budget"/> or <see cref="MaximumSearchedFolders"/> folders.
    /// </summary>
    public static IReadOnlyList<MoveSuggestion> Suggest(IReadOnlyList<MoveSample> samples, string oldPath, IEnumerable<string> roots,
        TimeSpan budget, CancellationToken token)
    {
        if (samples.Count == 0) return [];
        var clock = Stopwatch.StartNew();
        var firstParts = samples.Select(sample => sample.RelativePath.Split('/')[0]).Distinct(StringComparer.Ordinal).Take(16).ToArray();
        var results = new Dictionary<string, int>(StringComparer.Ordinal);
        void Consider(string folder)
        {
            if (results.ContainsKey(folder)) return;
            var plausible = false;
            foreach (var part in firstParts)
            {
                try { if (Path.Exists(Path.Join(folder, part))) { plausible = true; break; } }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException) { }
            }
            if (!plausible) return;
            var matched = CountMatches(folder, samples);
            if (matched > 0) results[folder] = matched;
        }
        if (Path.IsPathFullyQualified(oldPath) && Directory.Exists(oldPath)) Consider(Path.TrimEndingDirectorySeparator(oldPath));
        var visited = 0;
        var queue = new Queue<(string Path, int Depth)>();
        foreach (var root in roots.Where(Path.IsPathFullyQualified).Distinct(StringComparer.Ordinal))
            queue.Enqueue((Path.TrimEndingDirectorySeparator(root), 0));
        var seen = new HashSet<string>(StringComparer.Ordinal);
        while (queue.Count > 0 && clock.Elapsed < budget && visited < MaximumSearchedFolders)
        {
            token.ThrowIfCancellationRequested();
            var (folder, depth) = queue.Dequeue();
            if (!seen.Add(folder)) continue;
            visited++;
            DirectoryInfo directory;
            try
            {
                directory = new DirectoryInfo(folder);
                if (!directory.Exists || (depth > 0 && directory.LinkTarget is not null)) continue;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException) { continue; }
            Consider(folder);
            if (depth >= SearchDepth) continue;
            try
            {
                foreach (var child in directory.EnumerateDirectories("*", new EnumerationOptions
                { IgnoreInaccessible = true, RecurseSubdirectories = false, AttributesToSkip = FileAttributes.ReparsePoint }))
                {
                    if (child.Name.StartsWith('.')) continue;
                    queue.Enqueue((child.FullName, depth + 1));
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
        }
        return results.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key.Length).ThenBy(pair => pair.Key, StringComparer.Ordinal)
            .Take(MaximumSuggestions).Select(pair => new MoveSuggestion(pair.Key, pair.Value)).ToArray();
    }

    /// <summary>An absolute, existing folder that is not a link, trimmed; null otherwise.</summary>
    public static string? ValidFolder(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Contains('\0') || !Path.IsPathFullyQualified(value)) return null;
        try
        {
            var path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
            var directory = new DirectoryInfo(path);
            return directory.Exists && directory.LinkTarget is null ? path : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
    }

    /// <summary>
    /// Points storage locations at new folders in a database: the location's path, its titles' and
    /// excluded files' paths (manual file bindings included, they are titles' paths), with their file
    /// identities cleared so the next scan finds them by path. Every normalized path is made again
    /// for this computer, also for locations that keep their path. Returns the titles changed.
    /// </summary>
    public static async Task<IReadOnlyList<Guid>> RewriteAsync(DbConnection database, DbTransaction transaction,
        IReadOnlyCollection<MovePathMapping> mappings, bool renormalizeAll, CancellationToken token)
    {
        var roots = new List<(string Id, string Path)>();
        await using (var command = Command(database, transaction, "SELECT Id, Path FROM LibraryRoots;"))
        await using (var reader = await command.ExecuteReaderAsync(token))
            while (await reader.ReadAsync(token)) roots.Add((reader.GetString(0), reader.GetString(1)));
        var targets = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var mapping in mappings.Where(mapping => mapping.Path is not null))
        {
            var root = roots.FirstOrDefault(candidate => Guid.TryParse(candidate.Id, out var id) && id == mapping.Id);
            if (root.Id is null) throw new InvalidDataException("A storage location of the mapping does not exist.");
            targets[root.Id] = mapping.Path!;
        }
        var finalRoots = roots.Select(root => targets.TryGetValue(root.Id, out var target) ? target : root.Path).Select(MediaPath.Normalize).ToArray();
        for (var first = 0; first < finalRoots.Length; first++)
            for (var second = first + 1; second < finalRoots.Length; second++)
                if (MediaPath.Overlaps(finalRoots[first], finalRoots[second]))
                    throw new AccountException("locations_overlap", "Two storage locations would share a folder. Choose separate folders.", 409);
        var changed = new List<Guid>();
        var affected = renormalizeAll ? roots : roots.Where(root => targets.ContainsKey(root.Id)).ToList();
        // Unique indexes are checked per statement: every affected path is parked first, so a
        // location moved below its old folder, or two locations that swap folders, never collide.
        foreach (var root in affected)
        {
            await ExecuteAsync(database, transaction, "UPDATE LibraryRoots SET NormalizedPath='~move~' || Id WHERE Id=$id;", token, ("$id", root.Id));
            await ExecuteAsync(database, transaction, "UPDATE MediaItems SET NormalizedSourcePath='~move~' || Id WHERE LibraryRootId=$id;", token, ("$id", root.Id));
            await ExecuteAsync(database, transaction, "UPDATE MediaExclusions SET NormalizedSourcePath='~move~' || Id WHERE LibraryRootId=$id;", token, ("$id", root.Id));
        }
        foreach (var root in affected)
        {
            var moved = targets.TryGetValue(root.Id, out var target);
            var newRoot = moved ? target! : root.Path;
            // A moved location's import drafts were planned against the old folder.
            await ExecuteAsync(database, transaction, moved
                    ? "UPDATE LibraryRoots SET Path=$path, NormalizedPath=$normalized, ImportAssignmentRevision=ImportAssignmentRevision+1, LastError=NULL WHERE Id=$id;"
                    : "UPDATE LibraryRoots SET Path=$path, NormalizedPath=$normalized WHERE Id=$id;", token,
                ("$id", root.Id), ("$path", newRoot), ("$normalized", MediaPath.Normalize(newRoot)));
            var items = new List<(string Id, string Source)>();
            await using (var command = Command(database, transaction, "SELECT Id, SourcePath FROM MediaItems WHERE LibraryRootId=$id;", ("$id", root.Id)))
            await using (var reader = await command.ExecuteReaderAsync(token))
                while (await reader.ReadAsync(token)) items.Add((reader.GetString(0), reader.GetString(1)));
            foreach (var item in items)
            {
                var relative = Relative(root.Path, item.Source);
                if (moved && relative is not null)
                {
                    // Manual file bindings are titles' paths below the location too: they move along.
                    var source = Join(newRoot, relative);
                    await ExecuteAsync(database, transaction,
                        "UPDATE MediaItems SET SourcePath=$source, NormalizedSourcePath=$normalized, FileSystemIdentity=NULL WHERE Id=$id;", token,
                        ("$id", item.Id), ("$source", source), ("$normalized", MediaPath.Normalize(source)));
                    changed.Add(Guid.Parse(item.Id));
                }
                else
                {
                    await ExecuteAsync(database, transaction, "UPDATE MediaItems SET NormalizedSourcePath=$normalized WHERE Id=$id;", token,
                        ("$id", item.Id), ("$normalized", MediaPath.Normalize(item.Source)));
                }
            }
            var exclusions = new List<(string Id, string Relative)>();
            await using (var command = Command(database, transaction, "SELECT Id, RelativePath FROM MediaExclusions WHERE LibraryRootId=$id;", ("$id", root.Id)))
            await using (var reader = await command.ExecuteReaderAsync(token))
                while (await reader.ReadAsync(token)) exclusions.Add((reader.GetString(0), reader.IsDBNull(1) ? "" : reader.GetString(1)));
            foreach (var exclusion in exclusions)
            {
                var path = Join(newRoot, exclusion.Relative.Replace('\\', '/'));
                await ExecuteAsync(database, transaction,
                    moved ? "UPDATE MediaExclusions SET NormalizedSourcePath=$normalized, FileSystemIdentity=NULL WHERE Id=$id;"
                        : "UPDATE MediaExclusions SET NormalizedSourcePath=$normalized WHERE Id=$id;", token,
                    ("$id", exclusion.Id), ("$normalized", MediaPath.Normalize(path)));
            }
        }
        return changed;
    }

    private static string Join(string root, string relative) => relative.Length == 0 || relative == "."
        ? root : Path.Join(root, relative.Replace('/', Path.DirectorySeparatorChar));

    private static DbCommand Command(DbConnection database, DbTransaction transaction, string text, params (string Name, object Value)[] parameters)
    {
        var command = database.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = text;
        foreach (var (name, value) in parameters)
        {
            var parameter = command.CreateParameter();
            parameter.ParameterName = name;
            parameter.Value = value;
            command.Parameters.Add(parameter);
        }
        return command;
    }

    private static async Task ExecuteAsync(DbConnection database, DbTransaction transaction, string text, CancellationToken token,
        params (string Name, object Value)[] parameters)
    {
        await using var command = Command(database, transaction, text, parameters);
        await command.ExecuteNonQueryAsync(token);
    }
}
