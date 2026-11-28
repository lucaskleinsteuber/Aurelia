using Tarven.Server.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;

namespace Tarven.Server.Services;

public sealed record LibraryRelocatePreviewRequest(string? Path);
public sealed record LibraryRelocateRequest(string? Path, bool Force = false);
public sealed record LibraryRelocateResult(int Sampled, int Matched, int Titles, Guid? ScanId);

/// <summary>
/// Storage Location Moved (docs/SERVER_MOVE.md): points a storage location at the folder that now
/// holds its files, after a move or when a disk moved. Only the server's database changes; the
/// following scan finds the titles by path and only reads the media.
/// </summary>
public sealed class LibraryRelocationService(TarvenDbContext database, ServerRuntimeOptions runtime, CatalogMutationGate mutations,
    LibraryService libraries, ActiveStreamRegistry streams, ServerMoveOptions options)
{
    public async Task<MoveLocationSuggestions> SuggestionsAsync(Guid libraryId, CancellationToken token)
    {
        var location = await LocationAsync(libraryId, token);
        var suggestions = await Task.Run(() => ServerMoveLocations.Suggest(location.Samples, location.Path, options.SearchRoots, options.SearchBudget, token), token);
        return new(location.Samples.Count, suggestions);
    }

    public async Task<MoveLocationMatch> PreviewAsync(Guid libraryId, LibraryRelocatePreviewRequest request, CancellationToken token)
    {
        var location = await LocationAsync(libraryId, token);
        return new(location.Samples.Count, ServerMoveLocations.CountMatches(Folder(request.Path), location.Samples));
    }

    public async Task<LibraryRelocateResult> RelocateAsync(Guid libraryId, LibraryRelocateRequest request, CancellationToken token)
    {
        var folder = Folder(request.Path);
        if (MediaPath.Overlaps(MediaPath.Normalize(runtime.DataDirectory), MediaPath.Normalize(folder)))
            throw new AccountException("library_overlaps_server_data", "A storage location cannot contain or be inside Tarven Server's data folder.", 400);
        var location = await LocationAsync(libraryId, token);
        var matched = ServerMoveLocations.CountMatches(folder, location.Samples);
        if (location.Samples.Count > 0 && matched == 0 && !request.Force)
            throw new AccountException("relocate_no_matches", "None of this storage location's sample files are in that folder. Confirm to point it there anyway.", 409);
        IReadOnlyList<Guid> changed;
        using (await mutations.EnterAsync(token))
        {
            if (await database.LibraryScans.AnyAsync(scan => scan.LibraryRootId == libraryId && (scan.State == Tarven.Contracts.LibraryScanState.Queued
                    || scan.State == Tarven.Contracts.LibraryScanState.Running || scan.State == Tarven.Contracts.LibraryScanState.WaitingForStorage), token))
                throw new AccountException("library_scan_active", "Wait for this storage location's scan to finish, or stop it first.", 409);
            await using var transaction = await database.Database.BeginTransactionAsync(token);
            changed = await ServerMoveLocations.RewriteAsync(database.Database.GetDbConnection(), transaction.GetDbTransaction(),
                [new MovePathMapping(libraryId, folder)], renormalizeAll: false, token);
            // A ticket names a file at the old place; players ask for a new one.
            await database.PlaybackTickets.Where(ticket => changed.Contains(ticket.MediaItemId)).ExecuteDeleteAsync(token);
            await transaction.CommitAsync(token);
        }
        database.ChangeTracker.Clear();
        streams.RevokeMedia([.. changed]);
        Guid? scanId = null;
        try { scanId = (await libraries.StartScanAsync(libraryId, token)).Id; }
        catch (LibraryException exception) when (exception.Code is "import_preview_required" or "library_scan_active") { }
        return new(location.Samples.Count, matched, changed.Count, scanId);
    }

    private async Task<MoveLocation> LocationAsync(Guid libraryId, CancellationToken token)
    {
        if (!await database.LibraryRoots.AnyAsync(root => root.Id == libraryId, token))
            throw new AccountException("library_not_found", "The storage location was not found.", 404);
        return (await ServerMoveLocations.ReadLocationsAsync(runtime.DatabasePath, token, libraryId)).Single();
    }

    private static string Folder(string? path) => ServerMoveLocations.ValidFolder(path)
        ?? throw new AccountException("folder_invalid", "Enter the whole path of an existing folder on this computer.", 400);
}
