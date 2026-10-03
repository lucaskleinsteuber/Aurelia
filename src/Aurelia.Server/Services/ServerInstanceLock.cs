namespace Aurelia.Server.Services;

public sealed class ServerInstanceLock : IDisposable
{
    private readonly FileStream stream;
    private bool disposed;

    private ServerInstanceLock(FileStream stream)
    {
        this.stream = stream;
    }

    public static ServerInstanceLock Acquire(string dataDirectory)
    {
        PrivateFilePermissions.CreatePrivateDirectory(dataDirectory);
        var lockPath = Path.Combine(dataDirectory, "server.lock");

        try
        {
            var stream = new FileStream(
                lockPath,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None);
            PrivateFilePermissions.ProtectFile(lockPath);
            return new ServerInstanceLock(stream);
        }
        catch (IOException exception)
        {
            throw new InvalidOperationException(
                "Aurelia Server is already using this data directory.",
                exception);
        }
    }

    public static async Task<ServerInstanceLock> AcquireForHostAsync(string dataDirectory, CancellationToken cancellationToken)
    {
        // A previous child can still be draining requests after its helper died.
        // Never remove its lock or kill an unknown process; wait a bounded interval.
        var deadline = System.Diagnostics.Stopwatch.StartNew();
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try { return Acquire(dataDirectory); }
            catch (InvalidOperationException exception) when (
                exception.InnerException is IOException && deadline.Elapsed < TimeSpan.FromSeconds(15))
            {
                await Task.Delay(TimeSpan.FromMilliseconds(200), cancellationToken);
            }
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        stream.Dispose();
    }
}
