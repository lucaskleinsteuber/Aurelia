namespace Aurelia.Server.Services;

/// <summary>
/// Tells the Linux power saving (<c>aurelia-autosleep</c>) what the server is working on, in a
/// <c>work</c> file in its data folder, renewed every 30 seconds while it lasts:
/// <c>keepawake</c> while a library scan or metadata job runs, which should finish first;
/// <c>analysis</c> while only intro, credits, speech or scrub-preview work runs. That work can take
/// hours for a large library and continues after the next wake, where it left off, so it no longer
/// keeps an unused computer awake through the processor load it causes (audit B-4). Without the
/// file the power saving goes by the load as before.
/// </summary>
public sealed partial class ServerWorkSignal(ServerRuntimeOptions runtime, TimeProvider clock, ILogger<ServerWorkSignal> logger) : BackgroundService
{
    public const string FileName = "work";
    private int keepAwake;
    private int analysis;
    private string? written;

    /// <summary>Work that should keep the computer on until it finishes (a scan, a metadata job).</summary>
    public IDisposable KeepAwake() => new Lease(this, keep: true);

    /// <summary>Background analysis that may wait for the next wake.</summary>
    public IDisposable Analysis() => new Lease(this, keep: false);

    /// <summary>Starts work of a background service; nothing happens where no signal is registered (tests).</summary>
    public static IDisposable Begin(IServiceScopeFactory scopes, bool keepAwake)
    {
        using var scope = scopes.CreateScope();
        var signal = scope.ServiceProvider.GetService<ServerWorkSignal>();
        return signal is null ? NoWork.Instance : keepAwake ? signal.KeepAwake() : signal.Analysis();
    }

    private sealed class NoWork : IDisposable
    {
        public static readonly NoWork Instance = new();
        public void Dispose() { }
    }

    /// <summary>What the file says now: keepawake, analysis or nothing.</summary>
    public string? State => Volatile.Read(ref keepAwake) > 0 ? "keepawake" : Volatile.Read(ref analysis) > 0 ? "analysis" : null;

    private string WorkPath => Path.Combine(runtime.DataDirectory, FileName);

    private static readonly Action<ILogger, Exception?> WorkLoopFailed = LoggerMessage.Define(
        LogLevel.Warning, new EventId(4423, nameof(WorkLoopFailed)), "Server work signal paused after an unexpected failure.");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(30), clock);
        try
        {
            do
            {
                try { Write(); }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    WorkLoopFailed(logger, exception);
                }
            }
            while (await timer.WaitForNextTickAsync(stoppingToken));
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        finally { Remove(); }
    }

    /// <summary>Writes the current state, or removes the file when nothing runs.</summary>
    internal void Write()
    {
        try
        {
            if (State is not { } state)
            {
                Remove();
                Volatile.Write(ref written, null);
                return;
            }
            PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
            File.WriteAllText(WorkPath, state + "\n");
            Volatile.Write(ref written, state);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Power saving then goes by the processor load, as without this signal.
            LogUnwritable(logger, exception);
        }
    }

    private void Remove()
    {
        try { File.Delete(WorkPath); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    private void Changed(bool keep, int delta)
    {
        if (keep) Interlocked.Add(ref keepAwake, delta);
        else Interlocked.Add(ref analysis, delta);
        // A new kind of work is written at once, so the power saving sees it before its next look;
        // short repeats of the same work only wait for the next renewal.
        if (delta > 0 && State != Volatile.Read(ref written)) Write();
    }

    private sealed class Lease : IDisposable
    {
        private readonly ServerWorkSignal owner;
        private readonly bool keep;
        private int disposed;

        public Lease(ServerWorkSignal owner, bool keep)
        {
            this.owner = owner;
            this.keep = keep;
            owner.Changed(keep, 1);
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) == 0) owner.Changed(keep, -1);
        }
    }

    [LoggerMessage(Level = LogLevel.Debug, Message = "The work signal for power saving could not be written")]
    private static partial void LogUnwritable(ILogger logger, Exception exception);
}
