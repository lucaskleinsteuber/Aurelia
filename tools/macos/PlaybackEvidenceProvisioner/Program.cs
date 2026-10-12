using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;

// Offline fixture setup only. This never opens an installed/personal database,
// scans a directory, reads media bytes, or replaces production playback APIs.
try
{
    if (args.Length != 3 || args[0] is not ("synthetic" or "authorized-personal"))
        throw new EvidenceSetupException("invalid_provisioner_arguments");
    var mode = args[0];
    var databasePath = Path.GetFullPath(args[1]);
    var manifestPath = Path.GetFullPath(args[2]);
    if (!databasePath.Contains("/Library/Caches/Aurelia/TestRuns/playback-evidence-", StringComparison.Ordinal)
        || !databasePath.EndsWith("/aurelia.db", StringComparison.Ordinal)
        || !manifestPath.Contains("/Library/Caches/Aurelia/TestRuns/playback-evidence-", StringComparison.Ordinal)
        || !File.Exists(databasePath) || !File.Exists(manifestPath))
        throw new EvidenceSetupException("not_an_owned_evidence_database");
    var configuration = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
    var fixtures = JsonSerializer.Deserialize<EvidenceFixture[]>(await File.ReadAllTextAsync(manifestPath), configuration)
        ?? throw new EvidenceSetupException("invalid_owned_fixture_manifest");
    if (mode == "synthetic" && (fixtures.Length != 3
        || !fixtures.Select(value => value.Format).Order(StringComparer.Ordinal).SequenceEqual(EvidenceFixturePolicy.SyntheticFormats)))
        throw new EvidenceSetupException("not_the_three_generated_fixtures");
    if (mode == "authorized-personal" && (fixtures.Length != 1
        || Environment.GetEnvironmentVariable("AURELIA_EVIDENCE_AUTHORIZED_SOURCE_FILE") is not { } authorized
        || Path.GetFullPath(fixtures[0].Path) != Path.GetFullPath(authorized)))
        throw new EvidenceSetupException("not_the_exact_authorized_source");
    var options = new DbContextOptionsBuilder<AureliaDbContext>()
        .UseSqlite($"Data Source={databasePath};Mode=ReadWrite;Foreign Keys=True")
        .Options;
    await using var database = new AureliaDbContext(options);
    if (await database.LibraryRoots.AnyAsync() || await database.MediaItems.AnyAsync()
        || (await database.Database.GetPendingMigrationsAsync()).Any())
        throw new EvidenceSetupException("owned_database_not_empty_or_not_migrated");
    var now = DateTimeOffset.UtcNow;
    var libraries = new Dictionary<string, LibraryRoot>(StringComparer.Ordinal);
    foreach (var fixture in fixtures)
    {
        var source = Path.GetFullPath(fixture.Path);
        if (mode == "synthetic"
            && !source.Contains("/Library/Caches/Aurelia/TestRuns/playback-evidence-", StringComparison.Ordinal))
            throw new EvidenceSetupException("synthetic_fixture_outside_owned_run");
        var file = new FileInfo(source);
        if (!file.Exists || file.LinkTarget is not null)
            throw new EvidenceSetupException("authorized_source_missing_or_symlink");
        var parent = file.DirectoryName ?? throw new EvidenceSetupException("source_has_no_parent");
        if (!libraries.TryGetValue(parent, out var library))
        {
            library = new LibraryRoot
            {
                Id = Guid.NewGuid(), Name = "Owned playback evidence", Path = parent,
                NormalizedPath = MediaPath.Normalize(parent), Kind = LibraryKind.Movies,
                Availability = LibraryAvailability.Available, MonitoringEnabled = false,
                // Prevent even the monitoring worker's preliminary directory probe.
                // Playback still goes through the unchanged production service.
                ImportPreviewRequired = true, CreatedAt = now, LastScanCompletedAt = now,
            };
            database.LibraryRoots.Add(library);
            libraries.Add(parent, library);
        }
        database.MediaItems.Add(new MediaItem
        {
            Id = fixture.MediaId, LibraryRoot = library, LibraryRootId = library.Id,
            Kind = MediaKind.Movie, SourcePath = source, NormalizedSourcePath = MediaPath.Normalize(source),
            DetectedTitle = mode == "synthetic" ? $"Full Chain {fixture.Format}" : "Authorized playback evidence",
            ManualSourceBinding = true, Extension = file.Extension, FileSize = file.Length,
            FileModifiedAt = file.LastWriteTimeUtc, Availability = MediaAvailability.Available,
            CreatedAt = now, UpdatedAt = now,
        });
    }
    await database.SaveChangesAsync();
    Console.WriteLine("Owned playback evidence metadata provisioned; no media bytes read and no directory scanned.");
    return 0;
}
catch (EvidenceSetupException error)
{
    Console.Error.WriteLine($"Evidence setup failed: {error.Code}");
    return 1;
}
catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException
                             or DbUpdateException or InvalidOperationException)
{
    Console.Error.WriteLine("Evidence setup failed: owned_state_operation_failed");
    return 1;
}

internal sealed record EvidenceFixture(string Format, Guid MediaId, string Path);
internal static class EvidenceFixturePolicy
{
    internal static readonly string[] SyntheticFormats = ["AVI", "MKV", "MP4"];
}
internal sealed class EvidenceSetupException(string code) : Exception
{
    public string Code { get; } = code;
}
