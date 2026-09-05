namespace Aurelia.Home.Server.Services;

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
                "Aurelia Home Server is already using this data directory.",
                exception);
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
