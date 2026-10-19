using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;

namespace Aurelia.Desktop.Core;

/// <summary>How Aurelia was started: by the person, at sign-in, or by the installer to quit it.</summary>
public enum StartRequest { Open, Background, Quit }

public static class StartRequests
{
    public static StartRequest From(IEnumerable<string> arguments)
    {
        var given = arguments.ToArray();
        if (given.Contains("--quit", StringComparer.OrdinalIgnoreCase)) return StartRequest.Quit;
        return given.Contains("--background", StringComparer.OrdinalIgnoreCase) ? StartRequest.Background : StartRequest.Open;
    }
}

/// <summary>
/// One Aurelia per person on this computer, so only one server is ever started. A second start hands
/// its request (open the window, or quit for the installer) to the running one over a pipe that only
/// this account can open. The installer finds a running Aurelia by <see cref="MutexName"/>.
/// </summary>
public sealed class AppInstance : IDisposable
{
    /// <summary>Also named in the installer; Windows keeps it per sign-in session.</summary>
    public const string MutexName = "AureliaDesktopRunning";
    private readonly Mutex mutex;
    private readonly string pipe;
    private readonly CancellationTokenSource stop = new();
    private bool owned = true;

    private AppInstance(Mutex mutex, string pipe)
    {
        this.mutex = mutex;
        this.pipe = pipe;
    }

    /// <summary>This process becomes the running Aurelia, or null when one already runs.</summary>
    public static AppInstance? TryClaim(string name = MutexName)
    {
        var mutex = new Mutex(initiallyOwned: false, name);
        bool claimed;
        try { claimed = mutex.WaitOne(0); }
        catch (AbandonedMutexException) { claimed = true; }
        if (claimed) return new AppInstance(mutex, PipeName(name));
        mutex.Dispose();
        return null;
    }

    /// <summary>Answers "open" and "quit" from later starts; the reply goes out once the request is done.</summary>
    public void Listen(Func<StartRequest, Task> handle) => _ = Task.Run(async () =>
    {
        while (!stop.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(pipe, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(stop.Token);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(5));
                var line = await ReadLineAsync(server, timeout.Token);
                StartRequest? request = line switch { "open" => StartRequest.Open, "quit" => StartRequest.Quit, _ => null };
                if (request is null) continue;
                await handle(request.Value);
                await server.WriteAsync("ok\n"u8.ToArray(), stop.Token);
                await server.FlushAsync(stop.Token);
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { return; }
            catch (Exception error) when (error is IOException or OperationCanceledException or UnauthorizedAccessException) { }
        }
    });

    /// <summary>Asks the running Aurelia to open its window or to quit, and waits until it has.</summary>
    public static async Task<bool> SendAsync(StartRequest request, TimeSpan timeout, string name = MutexName)
    {
        using var limit = new CancellationTokenSource(timeout);
        try
        {
            await using var client = new NamedPipeClientStream(".", PipeName(name), PipeDirection.InOut,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await client.ConnectAsync(limit.Token);
            await client.WriteAsync(Encoding.ASCII.GetBytes(request == StartRequest.Quit ? "quit\n" : "open\n"), limit.Token);
            await client.FlushAsync(limit.Token);
            return await ReadLineAsync(client, limit.Token) == "ok";
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or TimeoutException or UnauthorizedAccessException
            or ArgumentException)
        {
            return false;
        }
    }

    public void Dispose()
    {
        stop.Cancel();
        stop.Dispose();
        if (owned)
        {
            owned = false;
            // Only the thread that claimed it may release it; otherwise Windows does when the process ends.
            try { mutex.ReleaseMutex(); }
            catch (ApplicationException) { }
        }
        mutex.Dispose();
    }

    /// <summary>Pipes are shared across the computer, so the name carries the account; short for macOS socket paths.</summary>
    private static string PipeName(string name)
    {
        var account = Encoding.UTF8.GetBytes(name + "|" + Environment.UserDomainName + "\\" + Environment.UserName);
        return "Aurelia-" + Convert.ToHexStringLower(SHA256.HashData(account))[..16];
    }

    private static async Task<string?> ReadLineAsync(Stream stream, CancellationToken cancellation)
    {
        var line = new StringBuilder();
        var one = new byte[1];
        while (line.Length < 16)
        {
            if (await stream.ReadAsync(one, cancellation) == 0) return null;
            if (one[0] == '\n') return line.ToString();
            line.Append((char)one[0]);
        }
        return null;
    }
}
