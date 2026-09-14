using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class LibraryService(
    AureliaDbContext database,
    LibraryScanScheduler scanQueue)
{
    public async Task<IReadOnlyList<LibrarySummary>> ListAsync(CancellationToken cancellationToken)
    {
        var libraries = await database.LibraryRoots
            .AsNoTracking()
            .OrderBy(library => library.Name)
            .ThenBy(library => library.Id)
            .ToListAsync(cancellationToken);
        return libraries.Select(ToSummary).ToList();
    }

    public async Task<LibrarySummary> CreateAsync(
        CreateLibraryRequest request,
        CancellationToken cancellationToken)
    {
        if (!Enum.IsDefined(request.Kind))
        {
            throw BadRequest("invalid_library_kind", "The library kind is not valid.");
        }

        var path = ValidateDirectory(request.Path);
        var derivedName = new DirectoryInfo(path).Name;
        var name = ValidateName(string.IsNullOrWhiteSpace(request.Name) ? derivedName : request.Name);
        var normalizedPath = MediaPath.Normalize(path);
        var existingLibraries = await database.LibraryRoots
            .ToListAsync(cancellationToken);
        var overlaps = existingLibraries
            .Where(existing => MediaPath.Overlaps(existing.NormalizedPath, normalizedPath))
            .ToList();
        if (overlaps.Count > 0 && !request.CombineExisting)
        {
            throw new LibraryException(
                "overlapping_library_path",
                request.Kind == LibraryKind.Automatic
                    ? "This storage location contains an existing library. Choose Combine Existing Libraries to keep its media and progress."
                    : "The folder overlaps an existing library.",
                StatusCodes.Status409Conflict);
        }

        if (overlaps.Count > 0)
        {
            if (request.Kind != LibraryKind.Automatic
                || overlaps.Any(existing => existing.Kind == LibraryKind.Automatic)
                || overlaps.Any(existing => !MediaPath.IsSameOrDescendant(
                    existing.NormalizedPath,
                    normalizedPath)))
            {
                throw new LibraryException(
                    "libraries_cannot_be_combined",
                    "Only existing movie and TV libraries inside a new automatic storage location can be combined.",
                    StatusCodes.Status409Conflict);
            }

            return await CombineAsync(
                overlaps,
                name,
                path,
                normalizedPath,
                cancellationToken);
        }

        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = name,
            Path = path,
            NormalizedPath = normalizedPath,
            Kind = request.Kind,
            Availability = LibraryAvailability.Unknown,
            CreatedAt = DateTimeOffset.UtcNow,
        };
        database.LibraryRoots.Add(library);
        await database.SaveChangesAsync(cancellationToken);
        return ToSummary(library);
    }

    private async Task<LibrarySummary> CombineAsync(
        IReadOnlyList<LibraryRoot> existingLibraries,
        string name,
        string path,
        string normalizedPath,
        CancellationToken cancellationToken)
    {
        var existingIds = existingLibraries.Select(library => library.Id).ToList();
        var activeScan = await database.LibraryScans.AnyAsync(
            scan => existingIds.Contains(scan.LibraryRootId)
                && (scan.State == LibraryScanState.Queued
                    || scan.State == LibraryScanState.Running),
            cancellationToken);
        if (activeScan)
        {
            throw new LibraryException(
                "library_scan_active",
                "Existing libraries cannot be combined while a scan is active.",
                StatusCodes.Status409Conflict);
        }

        await using var transaction = await database.Database.BeginTransactionAsync(cancellationToken);
        var now = DateTimeOffset.UtcNow;
        var combined = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = name,
            Path = path,
            NormalizedPath = normalizedPath,
            Kind = LibraryKind.Automatic,
            Availability = existingLibraries.All(library =>
                library.Availability == LibraryAvailability.Available)
                ? LibraryAvailability.Available
                : LibraryAvailability.Unknown,
            CreatedAt = existingLibraries.Min(library => library.CreatedAt),
            LastScanStartedAt = existingLibraries.Max(library => library.LastScanStartedAt),
            LastScanCompletedAt = existingLibraries.Max(library => library.LastScanCompletedAt),
        };
        database.LibraryRoots.Add(combined);
        await database.SaveChangesAsync(cancellationToken);

        foreach (var existing in existingLibraries)
        {
            var relativePath = Path.GetRelativePath(path, existing.Path);
            if (relativePath == ".")
            {
                relativePath = string.Empty;
            }

            database.LibraryDiscoveries.Add(new LibraryDiscovery
            {
                Id = Guid.NewGuid(),
                LibraryRootId = combined.Id,
                LibraryRoot = combined,
                RelativePath = relativePath,
                NormalizedRelativePath = NormalizeRelativePath(relativePath),
                DetectedTitle = existing.Name,
                SuggestedKind = existing.Kind,
                Reason = "combined_existing_library",
                Decision = existing.Kind switch
                {
                    LibraryKind.Movies => ClassificationDecision.Movie,
                    LibraryKind.TvShows => ClassificationDecision.TvShows,
                    _ => throw new InvalidOperationException(
                        "Only fixed movie and TV libraries can be combined."),
                },
                CreatedAt = now,
                UpdatedAt = now,
            });
        }

        await database.MediaItems
            .Where(item => existingIds.Contains(item.LibraryRootId))
            .ExecuteUpdateAsync(
                setters => setters.SetProperty(item => item.LibraryRootId, combined.Id),
                cancellationToken);
        await database.LibraryScans
            .Where(scan => existingIds.Contains(scan.LibraryRootId))
            .ExecuteUpdateAsync(
                setters => setters.SetProperty(scan => scan.LibraryRootId, combined.Id),
                cancellationToken);
        database.LibraryRoots.RemoveRange(existingLibraries);
        await database.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return ToSummary(combined);
    }

    public async Task<IReadOnlyList<LibraryDiscoverySummary>> ListDiscoveriesAsync(
        Guid libraryId,
        CancellationToken cancellationToken)
    {
        var library = await RequireLibraryAsync(libraryId, cancellationToken);
        if (library.Kind != LibraryKind.Automatic)
        {
            throw BadRequest(
                "automatic_library_required",
                "Discovery review is only available for automatic storage locations.");
        }

        return await database.LibraryDiscoveries
            .AsNoTracking()
            .Where(discovery => discovery.LibraryRootId == libraryId)
            .OrderBy(discovery => discovery.RelativePath)
            .ThenBy(discovery => discovery.Id)
            .Select(discovery => new LibraryDiscoverySummary(
                discovery.Id,
                discovery.LibraryRootId,
                discovery.RelativePath,
                discovery.DetectedTitle,
                discovery.SuggestedKind,
                discovery.Reason,
                discovery.Decision))
            .ToListAsync(cancellationToken);
    }

    public async Task<LibraryScanSummary> UpdateClassificationDecisionsAsync(
        Guid libraryId,
        UpdateClassificationDecisionsRequest request,
        CancellationToken cancellationToken)
    {
        var library = await RequireLibraryAsync(libraryId, cancellationToken);
        if (library.Kind != LibraryKind.Automatic)
        {
            throw BadRequest(
                "automatic_library_required",
                "Classification decisions are only available for automatic storage locations.");
        }

        if (request.Decisions is null || request.Decisions.Count == 0)
        {
            throw BadRequest("decisions_required", "Choose at least one folder classification.");
        }

        if (request.Decisions.Select(update => update.DiscoveryId).Distinct().Count()
            != request.Decisions.Count)
        {
            throw BadRequest("duplicate_decision", "Each discovered folder can be changed once per request.");
        }

        if (request.Decisions.Any(update => !Enum.IsDefined(update.Decision)))
        {
            throw BadRequest("invalid_decision", "A classification decision is not valid.");
        }

        var ids = request.Decisions.Select(update => update.DiscoveryId).ToList();
        var discoveries = await database.LibraryDiscoveries
            .Where(discovery => discovery.LibraryRootId == libraryId && ids.Contains(discovery.Id))
            .ToListAsync(cancellationToken);
        if (discoveries.Count != ids.Count)
        {
            throw new LibraryException(
                "discovery_not_found",
                "A discovered folder no longer exists.",
                StatusCodes.Status404NotFound);
        }

        var updates = request.Decisions.ToDictionary(update => update.DiscoveryId);
        var now = DateTimeOffset.UtcNow;
        foreach (var discovery in discoveries)
        {
            discovery.Decision = updates[discovery.Id].Decision;
            discovery.UpdatedAt = now;
        }

        await database.SaveChangesAsync(cancellationToken);
        var target = discoveries.Count == 1 ? discoveries[0].RelativePath : null;
        return await StartScanAsync(libraryId, target, cancellationToken);
    }

    public async Task<LibraryScanSummary> ResetClassificationDecisionAsync(
        Guid libraryId,
        Guid discoveryId,
        CancellationToken cancellationToken)
    {
        var library = await RequireLibraryAsync(libraryId, cancellationToken);
        if (library.Kind != LibraryKind.Automatic)
        {
            throw BadRequest(
                "automatic_library_required",
                "Classification decisions are only available for automatic storage locations.");
        }

        var discovery = await database.LibraryDiscoveries.SingleOrDefaultAsync(
            candidate => candidate.LibraryRootId == libraryId && candidate.Id == discoveryId,
            cancellationToken)
            ?? throw new LibraryException(
                "discovery_not_found",
                "The discovered folder no longer exists.",
                StatusCodes.Status404NotFound);

        discovery.Decision = null;
        discovery.UpdatedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
        return await StartScanAsync(libraryId, discovery.RelativePath, cancellationToken);
    }

    public async Task RemoveAsync(Guid libraryId, CancellationToken cancellationToken)
    {
        var library = await RequireLibraryAsync(libraryId, cancellationToken);
        var hasActiveScan = await database.LibraryScans.AnyAsync(
            scan => scan.LibraryRootId == libraryId
                && (scan.State == LibraryScanState.Queued
                    || scan.State == LibraryScanState.Running),
            cancellationToken);
        if (hasActiveScan)
        {
            throw new LibraryException(
                "library_scan_active",
                "The library cannot be removed while a scan is active.",
                StatusCodes.Status409Conflict);
        }

        await database.MediaItems
            .Where(item => item.LibraryRootId == libraryId && item.ParentId != null)
            .ExecuteDeleteAsync(cancellationToken);
        await database.MediaItems
            .Where(item => item.LibraryRootId == libraryId)
            .ExecuteDeleteAsync(cancellationToken);
        database.LibraryRoots.Remove(library);
        await database.SaveChangesAsync(cancellationToken);
    }

    public async Task<LibraryScanSummary> StartScanAsync(
        Guid libraryId,
        CancellationToken cancellationToken)
    {
        return await StartScanAsync(libraryId, null, cancellationToken);
    }

    private async Task<LibraryScanSummary> StartScanAsync(
        Guid libraryId,
        string? targetRelativePath,
        CancellationToken cancellationToken)
    {
        _ = await RequireLibraryAsync(libraryId, cancellationToken);
        if (!scanQueue.TryReserve(libraryId))
        {
            throw ScanAlreadyActive();
        }

        try
        {
            var hasActiveScan = await database.LibraryScans.AnyAsync(
                scan => scan.LibraryRootId == libraryId
                    && (scan.State == LibraryScanState.Queued
                        || scan.State == LibraryScanState.Running),
                cancellationToken);
            if (hasActiveScan)
            {
                throw ScanAlreadyActive();
            }

            var scan = new LibraryScan
            {
                Id = Guid.NewGuid(),
                LibraryRootId = libraryId,
                State = LibraryScanState.Queued,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            database.LibraryScans.Add(scan);
            await database.SaveChangesAsync(cancellationToken);
            scanQueue.Enqueue(scan.Id, libraryId, targetRelativePath);
            return ToSummary(scan, []);
        }
        catch
        {
            scanQueue.Release(libraryId);
            throw;
        }
    }

    public async Task<IReadOnlyList<LibraryScanSummary>> StartAllScansAsync(
        CancellationToken cancellationToken)
    {
        var libraryIds = await database.LibraryRoots
            .AsNoTracking()
            .OrderBy(library => library.Name)
            .Select(library => library.Id)
            .ToListAsync(cancellationToken);
        var scans = new List<LibraryScanSummary>();
        foreach (var libraryId in libraryIds)
        {
            try
            {
                scans.Add(await StartScanAsync(libraryId, cancellationToken));
            }
            catch (LibraryException exception) when (exception.Code == "library_scan_active")
            {
                // Other roots should still be queued when one root is already scanning.
            }
        }

        if (scans.Count == 0)
        {
            throw new LibraryException(
                "no_libraries_queued",
                libraryIds.Count == 0
                    ? "No libraries have been configured."
                    : "Every library already has an active scan.",
                StatusCodes.Status409Conflict);
        }

        return scans;
    }

    public async Task<LibraryScanSummary> GetScanAsync(
        Guid scanId,
        CancellationToken cancellationToken)
    {
        var scan = await database.LibraryScans
            .AsNoTracking()
            .Include(candidate => candidate.Issues)
            .SingleOrDefaultAsync(candidate => candidate.Id == scanId, cancellationToken)
            ?? throw new LibraryException(
                "scan_not_found",
                "The library scan was not found.",
                StatusCodes.Status404NotFound);
        return ToSummary(scan, scan.Issues.OrderBy(issue => issue.Id));
    }

    public async Task<IReadOnlyList<LibraryScanSummary>> ListScansAsync(
        Guid? libraryId,
        bool activeOnly,
        int limit,
        CancellationToken cancellationToken)
    {
        if (limit is < 1 or > 100)
        {
            throw BadRequest("invalid_scan_limit", "The scan history limit must be between 1 and 100.");
        }

        if (libraryId is { } id)
        {
            _ = await RequireLibraryAsync(id, cancellationToken);
        }

        var query = database.LibraryScans
            .AsNoTracking()
            .Include(scan => scan.Issues)
            .AsQueryable();
        if (libraryId is { } selectedLibraryId)
        {
            query = query.Where(scan => scan.LibraryRootId == selectedLibraryId);
        }

        if (activeOnly)
        {
            query = query.Where(scan => scan.State == LibraryScanState.Queued
                || scan.State == LibraryScanState.Running);
        }

        var scans = await query
            .OrderByDescending(scan => scan.CreatedAt)
            .ThenByDescending(scan => scan.Id)
            .Take(limit)
            .ToListAsync(cancellationToken);
        return scans.Select(scan => ToSummary(scan, scan.Issues.OrderBy(issue => issue.Id))).ToList();
    }

    private async Task<LibraryRoot> RequireLibraryAsync(
        Guid libraryId,
        CancellationToken cancellationToken)
    {
        return await database.LibraryRoots.SingleOrDefaultAsync(
            library => library.Id == libraryId,
            cancellationToken)
            ?? throw new LibraryException(
                "library_not_found",
                "The library was not found.",
                StatusCodes.Status404NotFound);
    }

    private static string ValidateName(string? value)
    {
        var name = (value ?? string.Empty).Trim().Normalize(NormalizationForm.FormKC);
        if (name.Length is < 1 or > 128 || name.Any(char.IsControl))
        {
            throw BadRequest(
                "invalid_library_name",
                "The library name must contain 1 to 128 visible characters.");
        }

        return name;
    }

    private static string NormalizeRelativePath(string path)
    {
        return path.Replace(Path.AltDirectorySeparatorChar, Path.DirectorySeparatorChar)
            .Trim(Path.DirectorySeparatorChar)
            .Normalize(NormalizationForm.FormKC)
            .ToUpperInvariant();
    }

    private static string ValidateDirectory(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || !Path.IsPathFullyQualified(value))
        {
            throw BadRequest(
                "invalid_library_path",
                "The library path must be an absolute directory path.");
        }

        var path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
        var directory = new DirectoryInfo(path);
        if (!directory.Exists || directory.LinkTarget is not null)
        {
            throw BadRequest(
                "invalid_library_path",
                "The library path must be an existing, readable directory and cannot be a symbolic link.");
        }

        try
        {
            _ = directory.EnumerateFileSystemInfos().Take(1).ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw BadRequest(
                "unreadable_library_path",
                "The library directory cannot be read.");
        }

        return path;
    }

    private static LibrarySummary ToSummary(LibraryRoot library)
    {
        return new LibrarySummary(
            library.Id,
            library.Name,
            library.Path,
            library.Kind,
            library.Availability,
            library.CreatedAt,
            library.LastScanStartedAt,
            library.LastScanCompletedAt,
            library.LastError);
    }

    private static LibraryScanSummary ToSummary(
        LibraryScan scan,
        IEnumerable<LibraryScanIssue> issues)
    {
        return new LibraryScanSummary(
            scan.Id,
            scan.LibraryRootId,
            scan.State,
            scan.CreatedAt,
            scan.StartedAt,
            scan.CompletedAt,
            scan.FilesDiscovered,
            scan.FilesProcessed,
            scan.AddedFiles,
            scan.UpdatedFiles,
            scan.MissingFiles,
            scan.SkippedFiles,
            scan.Error,
            issues.Take(500).Select(issue => new LibraryScanIssueSummary(
                issue.Code,
                issue.Message,
                issue.Path)).ToList());
    }

    private static LibraryException ScanAlreadyActive()
    {
        return new LibraryException(
            "library_scan_active",
            "This library already has an active scan.",
            StatusCodes.Status409Conflict);
    }

    private static LibraryException BadRequest(string code, string message)
    {
        return new LibraryException(code, message, StatusCodes.Status400BadRequest);
    }
}
