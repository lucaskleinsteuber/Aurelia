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
            if (request.RequireImportPreview)
                throw new LibraryException("preview_combine_not_supported", "Existing libraries cannot be combined through a first-import preview. Keep their current storage locations.", 409);
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
            ImportPreviewRequired = request.RequireImportPreview,
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
        if (existingLibraries.Any(library => library.ImportPreviewRequired)
            || await database.LibraryImportAssignments.AnyAsync(value => existingIds.Contains(value.LibraryRootId), cancellationToken)
            || await database.MediaExclusions.AnyAsync(value => existingIds.Contains(value.LibraryRootId), cancellationToken)
            || await database.LibraryImportPreviews.AnyAsync(value => existingIds.Contains(value.LibraryRootId) && !value.Confirmed, cancellationToken))
        {
            throw new LibraryException("libraries_have_import_assignments", "Libraries with import previews, saved assignments or excluded sources cannot be combined. Keep their existing storage locations so these decisions remain intact.", 409);
        }
        var activeScan = await database.LibraryScans.AnyAsync(
            scan => existingIds.Contains(scan.LibraryRootId)
                && (scan.State == LibraryScanState.Queued
                    || scan.State == LibraryScanState.Running
                    || scan.State == LibraryScanState.WaitingForStorage),
            cancellationToken);
        if (activeScan)
        {
            throw new LibraryException(
                "library_scan_active",
                "Existing libraries cannot be combined while a scan is active.",
                StatusCodes.Status409Conflict);
        }

        await using var transaction = await database.Database.BeginTransactionAsync(cancellationToken);
        var oldGrants = await database.UserLibraryGrants.Where(grant => existingIds.Contains(grant.LibraryRootId)).ToListAsync(cancellationToken);
        var sharedUsers = oldGrants.GroupBy(grant => grant.UserId).ToArray();
        if (sharedUsers.Any(group => group.Count() != existingIds.Count))
            throw new LibraryException("different_library_access", "Libraries with different user access cannot be combined. Review their grants first.", 409);
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
        database.UserLibraryGrants.AddRange(sharedUsers.Select(group => new UserLibraryGrant { UserId = group.Key, LibraryRootId = combined.Id }));
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

            var importedReviews = await database.LibraryImportReviews
                .Where(review => review.LibraryRootId == existing.Id)
                .ToListAsync(cancellationToken);
            foreach (var review in importedReviews)
            {
                review.RelativePath = Path.Combine(relativePath, review.RelativePath);
                review.NormalizedRelativePath = NormalizeRelativePath(review.RelativePath);
                review.LibraryRootId = combined.Id;
                review.LibraryRoot = combined;
            }
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

    public async Task<IReadOnlyList<LibraryImportReviewSummary>> ListImportReviewsAsync(
        Guid libraryId,
        CancellationToken cancellationToken)
    {
        _ = await RequireLibraryAsync(libraryId, cancellationToken);
        return await database.LibraryImportReviews
            .AsNoTracking()
            .Where(review => review.LibraryRootId == libraryId
                && review.State == LibraryImportReviewState.Pending)
            .OrderBy(review => review.DetectedTitle)
            .ThenBy(review => review.RelativePath)
            .Select(review => new LibraryImportReviewSummary(
                review.Id,
                review.LibraryRootId,
                review.RelativePath,
                review.DetectedTitle,
                review.Reason,
                review.State))
            .ToListAsync(cancellationToken);
    }

    public async Task<LibraryScanSummary> UpdateImportReviewAsync(
        Guid libraryId,
        Guid reviewId,
        UpdateLibraryImportReviewRequest request,
        CancellationToken cancellationToken)
    {
        var library = await RequireLibraryAsync(libraryId, cancellationToken);
        if (!Enum.IsDefined(request.Action))
        {
            throw BadRequest("invalid_import_review_action", "The import review action is not valid.");
        }

        var review = await database.LibraryImportReviews.SingleOrDefaultAsync(
            candidate => candidate.Id == reviewId && candidate.LibraryRootId == libraryId,
            cancellationToken)
            ?? throw new LibraryException(
                "import_review_not_found",
                "The import review no longer exists.",
                StatusCodes.Status404NotFound);
        if (review.State != LibraryImportReviewState.Pending)
        {
            throw new LibraryException(
                "import_review_already_decided",
                "This import review has already been resolved.",
                StatusCodes.Status409Conflict);
        }

        if (request.Action == LibraryImportReviewAction.AssignToMovie)
        {
            if (!request.MovieId.HasValue)
            {
                throw BadRequest("movie_required", "Choose a movie for this trailer.");
            }

            var movieExists = await database.MediaItems.AnyAsync(
                item => item.Id == request.MovieId.Value
                    && item.LibraryRootId == libraryId
                    && item.Kind == MediaKind.Movie,
                cancellationToken);
            if (!movieExists)
            {
                throw new LibraryException(
                    "movie_not_found",
                    "Choose a movie from this storage location.",
                    StatusCodes.Status404NotFound);
            }

        }
        else if (request.MovieId.HasValue)
        {
            throw BadRequest("unexpected_movie", "Ignore does not accept a movie selection.");
        }

        if (!scanQueue.TryReserve(libraryId))
        {
            throw ScanAlreadyActive();
        }

        try
        {
            var hasActiveScan = await database.LibraryScans.AnyAsync(
                scan => scan.LibraryRootId == libraryId
                    && (scan.State == LibraryScanState.Queued
                        || scan.State == LibraryScanState.Running
                        || scan.State == LibraryScanState.WaitingForStorage),
                cancellationToken);
            if (hasActiveScan)
            {
                throw ScanAlreadyActive();
            }

            await using var transaction = await database.Database.BeginTransactionAsync(cancellationToken);
            if (request.Action == LibraryImportReviewAction.AssignToMovie)
            {
                review.State = LibraryImportReviewState.Assigned;
                review.AssignedMovieId = request.MovieId;
            }
            else
            {
                review.State = LibraryImportReviewState.Ignored;
                review.AssignedMovieId = null;
            }

            var now = DateTimeOffset.UtcNow;
            review.UpdatedAt = now;
            library.ImportAssignmentRevision++;
            var scan = new LibraryScan
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                LibraryRoot = library,
                State = LibraryScanState.Queued,
                Trigger = LibraryScanTrigger.ClassificationChanged,
                CreatedAt = now,
            };
            database.LibraryScans.Add(scan);
            await database.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
            scanQueue.Pulse();
            return ToSummary(scan, []);
        }
        catch
        {
            scanQueue.Release(libraryId);
            throw;
        }
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
        library.ImportAssignmentRevision++;
        var now = DateTimeOffset.UtcNow;
        foreach (var discovery in discoveries)
        {
            discovery.Decision = updates[discovery.Id].Decision;
            discovery.UpdatedAt = now;
        }

        await database.SaveChangesAsync(cancellationToken);
        var target = discoveries.Count == 1 ? discoveries[0].RelativePath : null;
        return await StartScanAsync(
            libraryId,
            LibraryScanTrigger.ClassificationChanged,
            target,
            cancellationToken);
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
        library.ImportAssignmentRevision++;
        discovery.UpdatedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
        return await StartScanAsync(
            libraryId,
            LibraryScanTrigger.ClassificationChanged,
            discovery.RelativePath,
            cancellationToken);
    }

    public async Task RemoveAsync(Guid libraryId, CancellationToken cancellationToken)
    {
        var library = await RequireLibraryAsync(libraryId, cancellationToken);
        var hasActiveScan = await database.LibraryScans.AnyAsync(
            scan => scan.LibraryRootId == libraryId
                && (scan.State == LibraryScanState.Queued
                    || scan.State == LibraryScanState.Running
                    || scan.State == LibraryScanState.WaitingForStorage),
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
        return await StartScanAsync(
            libraryId,
            LibraryScanTrigger.Manual,
            null,
            cancellationToken);
    }

    public async Task<LibraryScanSummary> StartScanAsync(
        Guid libraryId,
        LibraryScanTrigger trigger,
        string? targetRelativePath,
        CancellationToken cancellationToken)
    {
        var library = await RequireLibraryAsync(libraryId, cancellationToken);
        if (library.ImportPreviewRequired)
            throw new LibraryException("import_preview_required", "Review and confirm the first import before starting a scan.", 409);
        if (!scanQueue.TryReserve(libraryId))
        {
            throw ScanAlreadyActive();
        }

        try
        {
            var hasActiveScan = await database.LibraryScans.AnyAsync(
                scan => scan.LibraryRootId == libraryId
                    && (scan.State == LibraryScanState.Queued
                        || scan.State == LibraryScanState.Running
                        || scan.State == LibraryScanState.WaitingForStorage),
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
                Trigger = trigger,
                TargetRelativePath = targetRelativePath,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            database.LibraryScans.Add(scan);
            await database.SaveChangesAsync(cancellationToken);
            scanQueue.Pulse();
            return ToSummary(scan, []);
        }
        catch
        {
            scanQueue.Release(libraryId);
            throw;
        }
    }

    public async Task<LibrarySummary> SetMonitoringAsync(
        Guid libraryId,
        bool enabled,
        CancellationToken cancellationToken)
    {
        var library = await RequireLibraryAsync(libraryId, cancellationToken);
        var wasEnabled = library.MonitoringEnabled;
        library.MonitoringEnabled = enabled;
        library.LastObservedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
        if (enabled && !wasEnabled && !library.ImportPreviewRequired)
        {
            try
            {
                _ = await StartScanAsync(
                    libraryId,
                    LibraryScanTrigger.Scheduled,
                    targetRelativePath: null,
                    cancellationToken);
            }
            catch (LibraryException exception) when (exception.Code == "library_scan_active")
            {
                // Existing work already reconciles this library.
            }
        }

        return ToSummary(library);
    }

    public async Task CancelScanAsync(Guid scanId, CancellationToken cancellationToken)
    {
        var scan = await database.LibraryScans.SingleOrDefaultAsync(
            candidate => candidate.Id == scanId,
            cancellationToken)
            ?? throw new LibraryException(
                "scan_not_found",
                "The library scan was not found.",
                StatusCodes.Status404NotFound);
        if (scan.State is LibraryScanState.Completed
            or LibraryScanState.Failed
            or LibraryScanState.Interrupted
            or LibraryScanState.Cancelled)
        {
            return;
        }

        scan.CancelRequestedAt ??= DateTimeOffset.UtcNow;
        if (scan.State is LibraryScanState.Queued or LibraryScanState.WaitingForStorage)
        {
            scan.State = LibraryScanState.Cancelled;
            scan.Phase = "Cancelled";
            scan.CompletedAt = DateTimeOffset.UtcNow;
            scan.Error = null;
            scanQueue.Release(scan.LibraryRootId);
        }

        await database.SaveChangesAsync(cancellationToken);
        scanQueue.RequestCancellation(scanId);
    }

    public async Task<bool> ResumeWaitingForStorageAsync(
        Guid libraryId,
        CancellationToken cancellationToken)
    {
        var scan = await database.LibraryScans
            .Where(candidate => candidate.LibraryRootId == libraryId
                && candidate.State == LibraryScanState.WaitingForStorage
                && !candidate.CancelRequestedAt.HasValue)
            .OrderBy(candidate => candidate.CreatedAt)
            .FirstOrDefaultAsync(cancellationToken);
        if (scan is null)
        {
            return false;
        }

        scan.State = LibraryScanState.Queued;
        scan.Error = null;
        scan.LeaseExpiresAt = null;
        scan.Trigger = LibraryScanTrigger.StorageReconnected;
        await database.SaveChangesAsync(cancellationToken);
        scanQueue.ReserveExisting(libraryId);
        scanQueue.Pulse();
        return true;
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
                || scan.State == LibraryScanState.Running
                || scan.State == LibraryScanState.WaitingForStorage);
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
            library.LastError,
            library.MonitoringEnabled,
            library.LastObservedAt,
            library.Availability switch
            {
                LibraryAvailability.Available => LibraryHealthStatus.Healthy,
                LibraryAvailability.Unavailable => LibraryHealthStatus.WaitingForStorage,
                LibraryAvailability.Error => LibraryHealthStatus.Error,
                _ => LibraryHealthStatus.Unknown,
            },
            library.ImportPreviewRequired);
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
                issue.Path)).ToList(),
            scan.Trigger,
            scan.Attempt,
            scan.TargetRelativePath,
            scan.Phase,
            scan.RecognizedFiles,
            scan.PendingFiles,
            scan.IgnoredFiles,
            scan.FailedFiles);
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
