using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class SceneNoteService(AureliaDbContext database, CatalogMutationGate mutations)
{
    public async Task<IReadOnlyList<SceneNoteSummary>> ListAsync(Guid userId, Guid mediaId, CancellationToken token)
    {
        await RequirePlayableAsync(mediaId, token);
        return await database.SceneNotes.AsNoTracking().Where(note => note.UserId == userId && note.MediaItemId == mediaId)
            .OrderBy(note => note.StartMilliseconds).ThenBy(note => note.Id)
            .Select(note => new SceneNoteSummary(note.Id, note.MediaItemId, note.StartMilliseconds, note.EndMilliseconds, note.Text, note.Revision))
            .ToListAsync(token);
    }

    public async Task<SceneNoteSummary> SaveAsync(Guid userId, Guid mediaId, Guid id, SaveSceneNoteRequest request, CancellationToken token)
    {
        if (id == Guid.Empty || request.Revision < 0 || request.StartMilliseconds < 0
            || request.EndMilliseconds is { } end && end <= request.StartMilliseconds
            || request.Text is null || request.Text.Length > 2000 || request.Text.Any(c => char.IsControl(c) && c is not '\n' and not '\r' and not '\t'))
            throw new AccountException("invalid_scene_note", "Enter a valid time or interval and a note of at most 2,000 characters.", 400);
        using var lease = await mutations.EnterAsync(token);
        await RequirePlayableAsync(mediaId, token);
        var note = await database.SceneNotes.SingleOrDefaultAsync(note => note.Id == id && note.UserId == userId && note.MediaItemId == mediaId, token);
        if (note is null)
        {
            if (request.Revision != 0) throw Missing();
            // A guessed ID owned by another profile must not be reused or disclose its contents.
            if (await database.SceneNotes.IgnoreQueryFilters().AnyAsync(note => note.Id == id, token)) throw Conflict();
            note = new SceneNote { Id = id, UserId = userId, MediaItemId = mediaId };
            database.SceneNotes.Add(note);
        }
        else if (request.Revision == 0 && note.Revision == 1
            && note.StartMilliseconds == request.StartMilliseconds && note.EndMilliseconds == request.EndMilliseconds
            && note.Text == request.Text.Trim())
        {
            // A timed-out creation response can be retried with the same client UUID.
            // Only an exact initial replay is idempotent; later edits still conflict.
            return new(note.Id, note.MediaItemId, note.StartMilliseconds, note.EndMilliseconds, note.Text, note.Revision);
        }
        else if (note.Revision != request.Revision) throw Conflict();
        note.StartMilliseconds = request.StartMilliseconds;
        note.EndMilliseconds = request.EndMilliseconds;
        note.Text = request.Text.Trim();
        // Also advance a no-op edit so its acknowledged revision is unambiguous.
        if (request.Revision > 0) database.Entry(note).Property(item => item.Text).IsModified = true;
        try { await database.SaveChangesAsync(token); }
        catch (DbUpdateConcurrencyException) { throw Conflict(); }
        catch (DbUpdateException exception) when (request.Revision == 0 && exception.InnerException is SqliteException { SqliteExtendedErrorCode: 1555 or 2067 }) { throw Conflict(); }
        return new(note.Id, note.MediaItemId, note.StartMilliseconds, note.EndMilliseconds, note.Text, note.Revision);
    }

    public async Task RemoveAsync(Guid userId, Guid mediaId, Guid id, long revision, CancellationToken token)
    {
        using var lease = await mutations.EnterAsync(token);
        await RequirePlayableAsync(mediaId, token);
        var note = await database.SceneNotes.SingleOrDefaultAsync(note => note.Id == id && note.UserId == userId && note.MediaItemId == mediaId, token)
            ?? throw Missing();
        if (revision != note.Revision) throw Conflict();
        database.SceneNotes.Remove(note);
        try { await database.SaveChangesAsync(token); }
        catch (DbUpdateConcurrencyException) { throw Conflict(); }
    }

    private async Task RequirePlayableAsync(Guid id, CancellationToken token)
    {
        if (!await database.MediaItems.AnyAsync(item => item.Id == id && item.Kind != MediaKind.Series, token))
            throw new AccountException("media_not_found", "The playable media was not found.", 404);
    }

    private static AccountException Missing() => new("scene_note_not_found", "The scene note was not found.", 404);
    private static AccountException Conflict() => new("scene_note_conflict", "The scene note changed on another device. Reload it before saving; your draft has not been replaced.", 409);
}
