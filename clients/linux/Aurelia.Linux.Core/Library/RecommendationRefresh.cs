using System.ComponentModel;

namespace Aurelia.Linux.Core.Library;

/// <summary>Refreshes Home at the server's recommendation deadline even when the library has no sync changes.</summary>
public sealed class RecommendationRefresh(LibraryStore store, TimeProvider? time = null)
{
    private readonly TimeProvider clock = time ?? TimeProvider.System;
    private CancellationTokenSource? waiting;

    public async Task RunAsync(CancellationToken cancellation)
    {
        store.PropertyChanged += HomeChanged;
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                using var wait = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                waiting = wait;
                var until = store.Home?.RecommendationChangesAt - clock.GetUtcNow() ?? TimeSpan.FromSeconds(30);
                if (until < TimeSpan.FromSeconds(1)) until = TimeSpan.FromSeconds(1);
                try { await Task.Delay(until, clock, wait.Token); }
                catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { continue; }
                finally { waiting = null; }
                cancellation.ThrowIfCancellationRequested();
                await store.RefreshHomeAsync(cancellation);
                // A stale deadline or failed request must not turn into a tight request loop.
                if (store.Home is null || store.Home.RecommendationChangesAt <= clock.GetUtcNow())
                    await Task.Delay(TimeSpan.FromSeconds(30), clock, cancellation);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        finally
        {
            store.PropertyChanged -= HomeChanged;
            waiting = null;
        }
    }

    private void HomeChanged(object? sender, PropertyChangedEventArgs change)
    {
        if (change.PropertyName == nameof(LibraryStore.Home)) waiting?.Cancel();
    }
}
