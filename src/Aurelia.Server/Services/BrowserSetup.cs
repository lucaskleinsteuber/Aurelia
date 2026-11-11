using System.Security.Cryptography;
using System.Text;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Setting up a new server from a web browser. While the server has no owner it keeps a one-time
/// setup code in a file only root and the server can read (<see cref="FileName"/> in the data
/// folder) and in its log, so only someone at the server computer, over SSH or with Docker's logs
/// learns it. A browser that types the code creates the owner and becomes the first signed-in
/// device. Ten wrong codes make a new one; a code lasts a day; the first owner ends it for good.
/// </summary>
public sealed partial class BrowserSetup(ServerRuntimeOptions runtime, TimeProvider clock, ILogger<BrowserSetup> logger)
{
    public const string FileName = "browser-setup-code";
    public const int MaximumAttempts = 10;
    public static readonly TimeSpan Lifetime = TimeSpan.FromDays(1);
    private const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

    private readonly Lock gate = new();
    private string? code;
    private DateTimeOffset createdAt;
    private int attempts;
    private bool finished;

    private string Path => System.IO.Path.Combine(runtime.DataDirectory, FileName);

    /// <summary>Whether a browser may still set this server up: nobody owns it yet.</summary>
    public static async Task<bool> OpenAsync(AureliaDbContext database, CancellationToken token) =>
        !await database.Users.AnyAsync(token);

    /// <summary>The current code, made (and written down) when there is none or it expired.</summary>
    public string Current()
    {
        lock (gate)
        {
            if (finished) throw new InvalidOperationException("The server is already set up.");
            if (code is null || clock.GetUtcNow() - createdAt >= Lifetime) Renew();
            return code!;
        }
    }

    /// <summary>"ABCDE-FGHJK" for showing; typing it with or without the dash, in any case, works.</summary>
    public static string Display(string value) => value.Length == 10 ? $"{value[..5]}-{value[5..]}" : value;

    /// <summary>Checks a typed code. Every wrong one counts; the tenth makes a new code.</summary>
    public bool Matches(string? supplied)
    {
        lock (gate)
        {
            if (finished || code is null || clock.GetUtcNow() - createdAt >= Lifetime) return false;
            var typed = Encoding.ASCII.GetBytes(new string((supplied ?? "").Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray()));
            var expected = Encoding.ASCII.GetBytes(code);
            if (typed.Length == expected.Length && CryptographicOperations.FixedTimeEquals(typed, expected)) return true;
            if (++attempts >= MaximumAttempts) Renew();
            return false;
        }
    }

    /// <summary>The owner exists: the code and its file are gone for good.</summary>
    public void Finish()
    {
        lock (gate)
        {
            finished = true;
            code = null;
            TryDelete();
        }
    }

    private void Renew()
    {
        code = RandomNumberGenerator.GetString(Alphabet, 10);
        createdAt = clock.GetUtcNow();
        attempts = 0;
        try
        {
            TryDelete();
            using var file = PrivateFilePermissions.OpenNewPrivateFile(Path);
            file.Write(Encoding.ASCII.GetBytes(Display(code) + "\n"));
        }
        catch (IOException exception)
        {
            LogUnwritable(logger, exception);
        }
        catch (UnauthorizedAccessException exception)
        {
            LogUnwritable(logger, exception);
        }
        LogCode(logger, runtime.LanHttpsPort, Display(code));
    }

    [LoggerMessage(Level = LogLevel.Warning, Message = "The browser setup code could not be written to the data folder.")]
    private static partial void LogUnwritable(ILogger logger, Exception exception);

    [LoggerMessage(Level = LogLevel.Warning, Message = "This server has no owner yet. Open its address (https://<this computer>:{Port}) in a browser and enter the setup code {Code}.")]
    private static partial void LogCode(ILogger logger, int port, string code);

    private void TryDelete()
    {
        try { if (File.Exists(Path)) File.Delete(Path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

/// <summary>Makes the setup code at start when the server has no owner, and removes a stale one.</summary>
public sealed class BrowserSetupStarter(IServiceScopeFactory scopes, BrowserSetup setup) : IHostedService
{
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        try
        {
            if (await BrowserSetup.OpenAsync(database, cancellationToken)) setup.Current();
            else setup.Finish();
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            // A database that can't be read yet leaves browser setup off; the terminal still works.
        }
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
