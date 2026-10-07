using System.Collections.Concurrent;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class WatcherAcknowledgementTests
{
    [Fact]
    public void EventArrivingWhileScanStartsCannotBeAcknowledgedByTheOlderScan()
    {
        var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "synthetic-watcher"));
        var state = new LibraryMonitoringService.PendingChanges(root);
        var now = DateTimeOffset.UtcNow;
        Assert.True(state.TryRecord(Path.Combine(root, "Season 1", "old.mp4"), false, now));
        Assert.True(state.Ready(now.AddSeconds(20), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(5), out var target, out var revision));
        Assert.Equal("Season 1", target);
        // The async enqueue has begun; a new callback arrives before completion.
        Assert.True(state.TryRecord(Path.Combine(root, "Season 2", "new.mp4"), false, now.AddSeconds(21)));
        var removed = false;
        Assert.False(state.TryAcknowledge(revision, () => { removed = true; return true; }));
        Assert.False(removed);
        Assert.True(state.Ready(now.AddSeconds(41), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(5), out target, out var nextRevision));
        Assert.Null(target); // Both seasons remain pending, requiring a full scan.
        Assert.True(nextRevision > revision);
    }

    [Fact]
    public void CallbackHoldingRetiredEntryMustRetryWithoutDeletingAReplacement()
    {
        var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "synthetic-watcher"));
        var id = Guid.NewGuid();
        var pending = new ConcurrentDictionary<Guid, LibraryMonitoringService.PendingChanges>();
        var old = new LibraryMonitoringService.PendingChanges(root);
        pending[id] = old;
        var now = DateTimeOffset.UtcNow;
        Assert.True(old.TryRecord(root, true, now));
        Assert.True(old.Ready(now.AddSeconds(20), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(5), out _, out var revision));
        Assert.True(old.TryAcknowledge(revision, () => pending.TryRemove(new KeyValuePair<Guid, LibraryMonitoringService.PendingChanges>(id, old))));
        Assert.False(old.TryRecord(root, true));
        var replacement = pending.GetOrAdd(id, _ => new LibraryMonitoringService.PendingChanges(root));
        Assert.True(replacement.TryRecord(root, true, now));
        Assert.False(old.TryAcknowledge(revision, () => pending.TryRemove(new KeyValuePair<Guid, LibraryMonitoringService.PendingChanges>(id, old))));
        Assert.Same(replacement, pending[id]);
    }
}
