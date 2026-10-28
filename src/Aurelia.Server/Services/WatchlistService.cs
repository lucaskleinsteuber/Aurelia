using System.Collections.Concurrent;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class WatchlistService(
    ServerRuntimeOptions runtime,
    AureliaDbContext database,
    TimeProvider timeProvider)
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Gates = new(StringComparer.Ordinal);
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };

    private sealed record StoredWatchlistEntry(Guid MediaId, DateTimeOffset AddedAt);

    public async Task<IReadOnlyList<Guid>> MediaIdsAsync(Guid userId, CancellationToken cancellationToken)
    {
        var entries = await ReadEntriesAsync(userId, cancellationToken);
        if (entries.Count == 0)
        {
            return [];
        }

        var orderedIds = entries
            .OrderByDescending(entry => entry.AddedAt)
            .Select(entry => entry.MediaId)
            .Distinct()
            .ToList();
        var visibleIds = (await database.MediaItems
            .AsNoTracking()
            .Where(item => orderedIds.Contains(item.Id) && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series))
            .Select(item => item.Id)
            .ToListAsync(cancellationToken))
            .ToHashSet();
        return orderedIds.Where(visibleIds.Contains).ToList();
    }

    public async Task<WatchlistResponse> GetAsync(
        Guid userId,
        PresentationService presentation,
        CancellationToken cancellationToken)
    {
        var ids = await MediaIdsAsync(userId, cancellationToken);
        var items = ids.Count == 0
            ? []
            : await presentation.SummariesAsync(userId, ids, cancellationToken);
        return new WatchlistResponse(items, items.Select(item => item.Id).ToList());
    }

    public async Task<WatchlistItemStateResponse> SetAsync(
        Guid userId,
        Guid mediaId,
        bool isWatchlisted,
        CancellationToken cancellationToken)
    {
        if (!await database.MediaItems.AnyAsync(
                item => item.Id == mediaId && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series),
                cancellationToken))
        {
            throw new MetadataException(
                "media_not_found",
                "The movie or series was not found.",
                StatusCodes.Status404NotFound);
        }

        var gate = GateForUser(userId);
        await gate.WaitAsync(cancellationToken);
        var changed = false;
        try
        {
            var entries = await ReadEntriesCoreAsync(userId, cancellationToken);
            var existingIndex = entries.FindIndex(entry => entry.MediaId == mediaId);
            if (isWatchlisted && existingIndex < 0)
            {
                entries.Insert(0, new StoredWatchlistEntry(mediaId, timeProvider.GetUtcNow()));
                await WriteEntriesCoreAsync(userId, entries, cancellationToken);
                changed = true;
            }
            else if (!isWatchlisted && existingIndex >= 0)
            {
                entries.RemoveAt(existingIndex);
                await WriteEntriesCoreAsync(userId, entries, cancellationToken);
                changed = true;
            }
        }
        finally
        {
            gate.Release();
        }

        if (changed)
        {
            database.SyncChanges.Add(new SyncChange
            {
                Area = SyncChangeArea.UserState,
                UserId = userId,
                MediaItemId = mediaId,
                CreatedAt = timeProvider.GetUtcNow(),
            });
            await database.SaveChangesAsync(cancellationToken);
        }

        return new WatchlistItemStateResponse(mediaId, isWatchlisted);
    }

    private async Task<List<StoredWatchlistEntry>> ReadEntriesAsync(Guid userId, CancellationToken cancellationToken)
    {
        var gate = GateForUser(userId);
        await gate.WaitAsync(cancellationToken);
        try
        {
            return await ReadEntriesCoreAsync(userId, cancellationToken);
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<List<StoredWatchlistEntry>> ReadEntriesCoreAsync(Guid userId, CancellationToken cancellationToken)
    {
        var path = WatchlistFilePath(userId);
        if (!File.Exists(path))
        {
            return [];
        }

        try
        {
            await using var stream = File.OpenRead(path);
            return await JsonSerializer.DeserializeAsync<List<StoredWatchlistEntry>>(stream, JsonOptions, cancellationToken) ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
        catch (IOException)
        {
            return [];
        }
    }

    private async Task WriteEntriesCoreAsync(Guid userId, List<StoredWatchlistEntry> entries, CancellationToken cancellationToken)
    {
        var directory = WatchlistDirectory();
        PrivateFilePermissions.CreatePrivateDirectory(directory);
        var target = WatchlistFilePath(userId);
        var temporary = Path.Combine(directory, $"{userId:N}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = PrivateFilePermissions.OpenNewPrivateFile(temporary))
            {
                await JsonSerializer.SerializeAsync(stream, entries, JsonOptions, cancellationToken);
            }

            File.Move(temporary, target, overwrite: true);
            PrivateFilePermissions.ProtectFile(target);
        }
        finally
        {
            try
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
            catch (IOException)
            {
            }
        }
    }

    private string WatchlistDirectory() => Path.Combine(runtime.DataDirectory, "Watchlist");

    private string WatchlistFilePath(Guid userId) => Path.Combine(WatchlistDirectory(), $"{userId:N}.json");

    private SemaphoreSlim GateForUser(Guid userId) =>
        Gates.GetOrAdd($"{Path.GetFullPath(runtime.DataDirectory)}:{userId:N}", static _ => new SemaphoreSlim(1, 1));
}
