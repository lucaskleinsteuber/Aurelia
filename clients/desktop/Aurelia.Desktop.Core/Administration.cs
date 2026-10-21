using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>Any management request to the server; the client adds the profile token and, where the server asks for one, an approval.</summary>
public interface IAdministrationClient
{
    Task<DateTimeOffset> UnlockAsync(string password, CancellationToken cancellation);
    Task<T> SendAsync<T>(HttpMethod method, string path, object? body, CancellationToken cancellation);
    /// <summary>A request with raw bytes, such as an image the person chose.</summary>
    Task<T> SendBytesAsync<T>(HttpMethod method, string path, byte[] content, string contentType, CancellationToken cancellation);
    /// <summary>Streams a large response, such as an encrypted backup, into a file the person chose.</summary>
    Task DownloadAsync(string path, Stream destination, CancellationToken cancellation);
    /// <summary>Streams a large file, such as a backup to restore, without approval (the server asks for none).</summary>
    Task UploadAsync(string path, Stream content, long length, CancellationToken cancellation);
}

/// <summary>Which management requests need a one-time approval, the same rule the server applies.</summary>
public static class AdministrationRules
{
    public static bool RequiresApproval(HttpMethod method, string target)
    {
        if (method == HttpMethod.Get || method == HttpMethod.Head) return false;
        var path = target.Split('?', 2)[0].TrimEnd('/').ToLowerInvariant();
        var delete = method == HttpMethod.Delete;
        if (path.StartsWith("/api/v1/server/operations/", StringComparison.Ordinal) && path.EndsWith("/confirm", StringComparison.Ordinal)) return false;
        if (method == HttpMethod.Put && path.StartsWith("/api/v1/server/backups/uploads/", StringComparison.Ordinal)) return false;
        if (delete && path.StartsWith("/api/v1/server/backups/transfers/", StringComparison.Ordinal)) return false;
        if (path.Contains("/exclusions/", StringComparison.Ordinal)) return false;
        if (path is "/api/v1/libraries/reset" or "/api/v1/auth/pairings") return true;
        if (path == "/api/v1/server/device-pairings/lookup") return false;
        if (path.StartsWith("/api/v1/server/device-pairings/", StringComparison.Ordinal)) return true;
        if (delete && path.StartsWith("/api/v1/auth/sessions/", StringComparison.Ordinal)) return true;
        if (delete && path.StartsWith("/api/v1/media/", StringComparison.Ordinal) && path.Split('/').Length == 5) return true;
        return path == "/api/v1/server/settings" || path.StartsWith("/api/v1/server/operations", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/server/backups", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/server/sessions", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/users", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/metadata/provider", StringComparison.Ordinal)
            || (path.StartsWith("/api/v1/libraries", StringComparison.Ordinal) && (delete || path == "/api/v1/libraries"));
    }

    /// <summary>The owner and administrators manage the server; other profiles only watch.</summary>
    public static bool CanManage(UserRole role) => role is UserRole.Owner or UserRole.Admin;
}

/// <summary>
/// Management from anywhere in the app, as on the Mac: a request that finds management locked asks
/// for the Server Password, unlocks it for ten minutes and is sent again. Closing the password
/// prompt cancels the request.
/// </summary>
public sealed class ManagementAccess(IAdministrationClient client, Func<string?, Task<string?>> askPassword)
{
    public const string WrongPassword = "The Server Password is not correct.";

    public IAdministrationClient Client => client;

    public Task<T> SendAsync<T>(HttpMethod method, string path, object? body, CancellationToken cancellation) =>
        RunAsync(token => client.SendAsync<T>(method, path, body, token), cancellation);

    public Task<T> SendBytesAsync<T>(HttpMethod method, string path, byte[] content, string contentType, CancellationToken cancellation) =>
        RunAsync(token => client.SendBytesAsync<T>(method, path, content, contentType, token), cancellation);

    public Task DownloadAsync(string path, Stream destination, CancellationToken cancellation) =>
        RunAsync(async token =>
        {
            await client.DownloadAsync(path, destination, token);
            return true;
        }, cancellation);

    public async Task<T> RunAsync<T>(Func<CancellationToken, Task<T>> operation, CancellationToken cancellation)
    {
        try
        {
            return await operation(cancellation);
        }
        catch (AureliaApiException error) when (error.Code == "management_locked")
        {
            await UnlockAsync(cancellation);
            return await operation(cancellation);
        }
    }

    /// <summary>Asks for the password until it is right; null from the prompt cancels.</summary>
    private async Task UnlockAsync(CancellationToken cancellation)
    {
        string? problem = null;
        while (true)
        {
            var password = await askPassword(problem) ?? throw new OperationCanceledException("Management stays locked.");
            try
            {
                await client.UnlockAsync(password, cancellation);
                return;
            }
            catch (AureliaApiException error) when (error.Status is 400 or 401 or 403 && error.Code != "management_locked")
            {
                problem = WrongPassword;
            }
        }
    }
}
