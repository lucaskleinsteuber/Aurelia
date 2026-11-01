using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Library;

/// <summary>
/// Keeps the library current while the app is open: a long poll of /api/v1/sync/changes (30 s),
/// applying what changed and only then moving the cursor on. The cursor and generation are kept
/// per server, profile and session, as docs/CLIENT_PROTOCOL.md asks. Transient failures back off
/// (3, 6, 12 … 30 s or the server's Retry-After); a server without sync (404) is left alone.
/// </summary>
public sealed class LibrarySync(LibraryStore store, ISettingsStore settings, TimeProvider time)
{
    public const int WaitSeconds = 30;

    public async Task RunAsync(CancellationToken cancellation)
    {
        var client = store.Client;
        var key = $"syncCursor.{client.Server.ServerId}.{client.Profile.User.Id}.{client.Server.SessionId}";
        var saved = settings.Read<SavedCursor>(key);
        var cursor = saved?.Cursor ?? 0;
        var generation = saved?.Generation;
        var failures = 0;
        while (!cancellation.IsCancellationRequested)
        {
            var started = time.GetUtcNow();
            try
            {
                var changes = await client.ChangesAsync(cursor, WaitSeconds, generation, cancellation);
                if (changes.Cursor < cursor && !changes.ResetRequired) changes = changes with { ResetRequired = true };
                if (changes.ResetRequired || changes.ChangedAreas.Count > 0 || changes.ChangedMediaIds.Count > 0)
                    await store.ApplyChangesAsync(changes);
                cursor = changes.Cursor;
                generation = changes.Generation;
                settings.Write(key, new SavedCursor(cursor, generation));
                failures = 0;
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                return;
            }
            catch (AureliaApiException failure) when (failure.Status == 404)
            {
                return;
            }
            catch (AureliaApiException failure) when (failure.IsTransient)
            {
                failures++;
                var wait = failure.RetryAfter ?? TimeSpan.FromSeconds(Math.Min(30, 3 * Math.Pow(2, failures - 1)));
                await DelayAsync(wait, cancellation);
                continue;
            }
            catch (AureliaApiException failure)
            {
                store.Report(failure);
                return;
            }
            // Never loop faster than four times a second, even when the server answers at once.
            var elapsed = time.GetUtcNow() - started;
            if (elapsed < TimeSpan.FromMilliseconds(250)) await DelayAsync(TimeSpan.FromMilliseconds(250) - elapsed, cancellation);
        }
    }

    private async Task DelayAsync(TimeSpan wait, CancellationToken cancellation)
    {
        try
        {
            await Task.Delay(wait, time, cancellation);
        }
        catch (OperationCanceledException)
        {
        }
    }

    private sealed record SavedCursor(long Cursor, string? Generation);
}
