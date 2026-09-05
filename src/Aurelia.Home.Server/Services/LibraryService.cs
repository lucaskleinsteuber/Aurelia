using System.Text;
using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Home.Server.Services;

public sealed class LibraryService(
    AureliaHomeDbContext database,
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
        var name = ValidateName(request.Name);
        if (!Enum.IsDefined(request.Kind))
        {
            throw BadRequest("invalid_library_kind", "The library kind is not valid.");
        }

        var path = ValidateDirectory(request.Path);
        var normalizedPath = MediaPath.Normalize(path);
        var existingPaths = await database.LibraryRoots
            .AsNoTracking()
            .Select(library => library.NormalizedPath)
            .ToListAsync(cancellationToken);
        if (existingPaths.Any(existing => MediaPath.Overlaps(existing, normalizedPath)))
        {
            throw new LibraryException(
                "overlapping_library_path",
                "The folder overlaps an existing library.",
                StatusCodes.Status409Conflict);
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
            scanQueue.Enqueue(scan.Id, libraryId);
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
