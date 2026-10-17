using System.Data.Common;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace Aurelia.Server.Services;

// Wake only after a committed write. The timed fallback also supports other processes.
public sealed class DatabaseChangeSignal
{
    private readonly object gate = new();
    private TaskCompletionSource wake = NewSignal();
    public Task Snapshot() { lock (gate) return wake.Task; }
    public void Pulse()
    {
        TaskCompletionSource previous;
        lock (gate) { previous = wake; wake = NewSignal(); }
        previous.TrySetResult();
    }
    private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    /// <summary>Waits for a captured snapshot or the fallback, without leaving a timer behind.</summary>
    public static async Task WaitAsync(Task snapshot, TimeSpan fallback, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(fallback);
        try { await snapshot.WaitAsync(timeout.Token); }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { }
    }
}

public sealed class DatabaseSaveSignal(DatabaseChangeSignal signal) : SaveChangesInterceptor
{
    public override ValueTask<int> SavedChangesAsync(SaveChangesCompletedEventData eventData, int result, CancellationToken cancellationToken = default)
    {
        if (result > 0 && eventData.Context?.Database.CurrentTransaction is null) signal.Pulse();
        return ValueTask.FromResult(result);
    }
}

public sealed class DatabaseCommitSignal(DatabaseChangeSignal signal) : DbTransactionInterceptor
{
    public override Task TransactionCommittedAsync(DbTransaction transaction, TransactionEndEventData eventData, CancellationToken cancellationToken = default)
    { signal.Pulse(); return Task.CompletedTask; }
}
