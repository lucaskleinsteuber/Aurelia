using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class ServerRequestGuard
{
    public const long MaximumJsonBytes = 65_536;
    private readonly object gate = new();
    private readonly Dictionary<string, (int Count, DateTimeOffset Window)> addresses = [];
    private static readonly IPNetwork[] PrivateNetworks = [IPNetwork.Parse("10.0.0.0/8"), IPNetwork.Parse("172.16.0.0/12"),
        IPNetwork.Parse("192.168.0.0/16"), IPNetwork.Parse("100.64.0.0/10"), IPNetwork.Parse("169.254.0.0/16"),
        IPNetwork.Parse("fc00::/7"), IPNetwork.Parse("fe80::/10")];
    public static bool NetworkAllowed(IPAddress? address, string[]? restrictions)
    {
        if (address is null) return true; // Isolated in-process test transport.
        var ip = address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
        if (IPAddress.IsLoopback(ip)) return true;
        return PrivateNetworks.Any(network => network.Contains(ip))
            && (restrictions is not { Length: > 0 } || restrictions.Any(network => IPNetwork.Parse(network).Contains(ip)));
    }
    public bool Admit(IPAddress? address)
    {
        var key = address?.ToString() ?? "local";
        var now = DateTimeOffset.UtcNow;
        lock (gate)
        {
            if (addresses.Count >= 4_096)
                foreach (var stale in addresses.Where(pair => now - pair.Value.Window >= TimeSpan.FromMinutes(1)).Select(pair => pair.Key).ToArray())
                    addresses.Remove(stale);
            if (addresses.TryGetValue(key, out var entry) && now - entry.Window < TimeSpan.FromMinutes(1))
            {
                if (entry.Count >= 600) return false;
                addresses[key] = (entry.Count + 1, entry.Window);
            }
            else
            {
                if (addresses.Count >= 4_096) return false;
                addresses[key] = (1, now);
            }
            return true;
        }
    }

    public static bool RequiresApproval(HttpRequest request)
    {
        if (HttpMethods.IsGet(request.Method) || HttpMethods.IsHead(request.Method)) return false;
        var path = (request.Path.Value ?? string.Empty).TrimEnd('/').ToLowerInvariant();
        if (path.StartsWith("/api/v1/server/operations/", StringComparison.Ordinal) && path.EndsWith("/confirm", StringComparison.Ordinal)) return false;
        if (HttpMethods.IsPut(request.Method) && path.StartsWith("/api/v1/server/backups/uploads/", StringComparison.Ordinal)) return false;
        // Removing a temporary encrypted transfer is not a restore or persistent backup deletion.
        if (HttpMethods.IsDelete(request.Method) && path.StartsWith("/api/v1/server/backups/transfers/", StringComparison.Ordinal)) return false;
        return path == "/api/v1/server/settings" || path.StartsWith("/api/v1/server/operations", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/server/backups", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/server/sessions", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/users", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/metadata/provider", StringComparison.Ordinal)
            || (path.StartsWith("/api/v1/libraries", StringComparison.Ordinal) && (HttpMethods.IsDelete(request.Method) || path == "/api/v1/libraries"));
    }

    public static async Task RequireApprovalAsync(HttpContext context, AdministrationApprovalStore approvals)
    {
        var database = context.RequestServices.GetRequiredService<AureliaDbContext>();
        var required = RequiresApproval(context.Request);
        // Keep self-service sign-out compatible, but do not let the legacy device route
        // bypass owner reauthentication when revoking another account's device.
        if (!required && HttpMethods.IsDelete(context.Request.Method)
            && context.Request.Path.StartsWithSegments("/api/v1/auth/sessions", StringComparison.OrdinalIgnoreCase, out var remaining)
            && Guid.TryParse(remaining.Value?.Trim('/'), out var targetId)
            && context.User.Identity?.IsAuthenticated == true)
        {
            var actorId = context.User.RequireUserId();
            required = await database.DeviceSessions.AnyAsync(session => session.Id == targetId && session.UserId != actorId, context.RequestAborted);
        }
        if (!required) return;
        if (!context.User.IsInRole(UserRole.Owner.ToString()))
            throw new AccountException("owner_required", "Only an owner may change global server settings.", 403);
        context.Request.EnableBuffering(bufferThreshold: 65_536, bufferLimit: MaximumJsonBytes + 1);
        using var payload = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            var count = await context.Request.Body.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, MaximumJsonBytes + 1 - payload.Length)), context.RequestAborted);
            if (count == 0) break;
            payload.Write(buffer, 0, count);
            if (payload.Length > MaximumJsonBytes)
                throw new AccountException("request_too_large", "The JSON request is too large.", 413);
        }
        context.Request.Body.Position = 0;
        if (!approvals.Consume(context.Request.Headers["X-Aurelia-Approval"].ToString(), context.User.RequireSessionId(),
                context.Request.Method + " " + context.Request.Path.Value, AdministrationApprovalStore.Hash(payload.ToArray())))
            throw new AccountException("approval_required", "Confirm your password for this exact change. Approvals expire after two minutes and can be used once.", 403);
        var sessionId = context.User.RequireSessionId();
        var now = DateTimeOffset.UtcNow;
        if (!await database.DeviceSessions.AnyAsync(session => session.Id == sessionId && session.RevokedAt == null
                && session.ExpiresAt > now && session.User.IsEnabled && session.User.Role == UserRole.Owner, context.RequestAborted))
            throw new AccountException("owner_session_revoked", "The owner session is no longer authorized.", 403);
        context.Items["Aurelia.AdministrationApproved"] = true;
    }
}
