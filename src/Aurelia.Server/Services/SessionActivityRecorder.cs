using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

// Authorization never uses this cache; the caller must first read and validate
// the live session. It only bounds optional activity writes during an outage.
public sealed class SessionActivityRecorder(TimeProvider clock, ServerDiagnosticsStore diagnostics)
{
    private readonly object gate = new();
    private readonly Dictionary<Guid, DateTimeOffset> attempts = [];
    private DateTimeOffset nextWarning = DateTimeOffset.MinValue;

    internal async Task RecordAsync(AureliaDbContext database, Guid id, DateTimeOffset now, CancellationToken token) =>
        await RecordAsync(database, id, now, null, token);

    /// <summary>
    /// When the device was last seen and, from <paramref name="identity"/>, its address, kind and
    /// version. An installation identifier is written once and never replaced, so a device can't
    /// swap its name on the block list.
    /// </summary>
    internal async Task RecordAsync(AureliaDbContext database, Guid id, DateTimeOffset now, ClientIdentity? identity, CancellationToken token)
    {
        var address = identity?.IpAddress;
        var platform = identity?.Platform;
        var version = identity?.Version;
        var installation = identity?.InstallationId;
        await TryRecordAsync(id, async () =>
        {
            await database.DeviceSessions.Where(candidate => candidate.Id == id && candidate.RevokedAt == null)
                .ExecuteUpdateAsync(update => update
                    .SetProperty(candidate => candidate.LastSeenAt, now)
                    .SetProperty(candidate => candidate.LastIpAddress, candidate => address ?? candidate.LastIpAddress)
                    .SetProperty(candidate => candidate.FirstIpAddress, candidate => candidate.FirstIpAddress ?? address)
                    .SetProperty(candidate => candidate.Platform, candidate => platform ?? candidate.Platform)
                    .SetProperty(candidate => candidate.ClientVersion, candidate => version ?? candidate.ClientVersion)
                    .SetProperty(candidate => candidate.InstallationId, candidate => candidate.InstallationId ?? installation), token);
        });
    }

    internal async Task TryRecordAsync(Guid id, Func<Task> write)
    {
        var now = clock.GetUtcNow();
        lock (gate)
        {
            if (attempts.TryGetValue(id, out var next) && next > now) return;
            if (attempts.Count >= 4096)
                foreach (var expired in attempts.Where(entry => entry.Value <= now).Select(entry => entry.Key).ToArray())
                    attempts.Remove(expired);
            // Optional bookkeeping may be skipped when its bounded cache is full.
            if (attempts.Count >= 4096 && !attempts.ContainsKey(id)) return;
            attempts[id] = now.AddMinutes(1);
        }
        try { await write(); }
        catch (Exception error) when (StorageRecovery.IsRecoverableDatabase(error))
        {
            lock (gate)
            {
                if (now < nextWarning) return;
                nextWarning = now.AddMinutes(1);
                diagnostics.Record("session_activity_storage_unavailable", "warning");
            }
        }
    }
}
