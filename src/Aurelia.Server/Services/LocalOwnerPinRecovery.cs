using System.Net;
using System.Security.Cryptography;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class LocalOwnerPinRecovery(IConfiguration configuration)
{
    private readonly byte[]? secret = Resolve(configuration);
    public void Authorize(HttpContext context)
    {
        if (context.Connection.RemoteIpAddress is { } ip && !IPAddress.IsLoopback(ip)) throw Denied();
        var supplied = context.Request.Headers["X-Aurelia-Host-Recovery"].ToString();
        if (secret is null || supplied.Length is < 32 or > 256) throw Denied();
        var bytes = Encoding.UTF8.GetBytes(supplied);
        if (bytes.Length != secret.Length || !CryptographicOperations.FixedTimeEquals(bytes, secret)) throw Denied();
    }
    public async Task RecoverAsync(InitializeProfilesRequest request, AureliaDbContext database, ProfileService profiles, CancellationToken token)
    {
        var owners = await database.Users.Where(user => user.Role == UserRole.Owner && user.IsEnabled).Select(user => user.Id).Take(2).ToListAsync(token);
        if (owners.Count != 1) throw new AccountException("owner_pin_recovery_unavailable", "Ask another owner to reset your viewing PIN in Users & Access.", 409);
        await profiles.VerifyManagementAsync(owners[0], request.Password, token);
        await profiles.ResetPinAsync(owners[0], owners[0], request.Pin, token);
    }
    private static byte[]? Resolve(IConfiguration configuration)
    {
        var value = Environment.GetEnvironmentVariable("AURELIA_HOST_CONTROL_URL");
        var key = Uri.TryCreate(value, UriKind.Absolute, out var address) && address.Scheme == "http" && address.Host == "127.0.0.1"
            ? address.AbsolutePath.Trim('/') : null;
        key ??= configuration["Aurelia:HostRecoveryToken"];
        return key is { Length: >= 32 and <= 256 } ? Encoding.UTF8.GetBytes(key) : null;
    }
    private static AccountException Denied() => new("local_host_authorization_required", "Owner PIN recovery requires the private host channel on the server Mac.", 403);
}
