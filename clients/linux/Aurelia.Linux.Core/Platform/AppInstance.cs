using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;

namespace Aurelia.Linux.Core.Platform;

/// <summary>
/// One app per settings directory. Opening the launcher again brings back the existing window,
/// including a host hidden in the notification area, rather than starting a competing server.
/// The pipe accepts only the same user and carries a single show/background byte, no credentials.
/// </summary>
public sealed class AppInstance : IDisposable
{
    private readonly FileStream? ownership;
    private readonly string name;
    private readonly CancellationTokenSource stop = new();
    private readonly Lock gate = new();
    private Action? show;
    private bool pending;
    private readonly Task? listener;
    private bool disposed;

    public AppInstance(string settingsDirectory)
    {
        var directory = Path.GetFullPath(settingsDirectory);
        var identity = OperatingSystem.IsWindows() ? directory : Environment.UserName + "\n" + directory;
        var id = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(identity)))[..24];
        var pipe = "aurelia-desktop-" + id;
        // Unix named pipes use filesystem sockets, whose paths have a small fixed limit.
        // TMPDIR can be long and can differ between a desktop launcher and a terminal.
        // Keep both launches on the same bounded path; CurrentUserOnly still authenticates peers.
        name = OperatingSystem.IsWindows() ? pipe : Path.Combine("/tmp", pipe);
        Settings.PrivateFiles.CreateDirectory(directory);
        var path = Path.Combine(directory, "instance.lock");
        var options = new FileStreamOptions { Mode = FileMode.OpenOrCreate, Access = FileAccess.ReadWrite, Share = FileShare.None };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        try { ownership = new FileStream(path, options); IsOwner = true; }
        catch (IOException) when (File.Exists(path)) { IsOwner = false; }
        if (IsOwner) listener = Task.Run(ListenAsync);
    }

    public bool IsOwner { get; }

    /// <summary>The callback runs from a pipe thread; the app supplies an explicit UI dispatch.</summary>
    public void OnShow(Action callback)
    {
        bool deliver;
        lock (gate)
        {
            show = callback;
            deliver = pending;
            pending = false;
        }
        if (deliver) callback();
    }

    public async Task NotifyExistingAsync(bool showWindow, CancellationToken cancellation = default)
    {
        if (IsOwner) return;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await client.ConnectAsync(timeout.Token);
        await client.WriteAsync(new byte[] { showWindow ? (byte)1 : (byte)0 }, timeout.Token);
        var ack = new byte[1];
        if (await client.ReadAsync(ack, timeout.Token) != 1 || ack[0] != 1)
            throw new IOException("The running Aurelia app did not acknowledge the request.");
    }

    private async Task ListenAsync()
    {
        while (!stop.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(stop.Token);
                using var request = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                request.CancelAfter(TimeSpan.FromSeconds(3));
                var command = new byte[1];
                if (await server.ReadAsync(command, request.Token) != 1 || command[0] > 1) continue;
                if (command[0] == 1)
                {
                    Action? callback;
                    lock (gate)
                    {
                        callback = show;
                        if (callback is null) pending = true;
                    }
                    callback?.Invoke();
                }
                await server.WriteAsync(new byte[] { 1 }, request.Token);
            }
            catch (OperationCanceledException) { }
            catch (IOException) { }
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        stop.Cancel();
        if (listener is not null)
        {
            try { listener.GetAwaiter().GetResult(); }
            catch (OperationCanceledException) { }
        }
        ownership?.Dispose();
        stop.Dispose();
    }
}
