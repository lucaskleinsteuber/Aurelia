using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class ServerRequestGuard
{
    public const long MaximumJsonBytes = 65_536;
    /// <summary>
    /// Coarse flood protection per address and minute. Browsing a library loads one image per
    /// title, so the budget fits scrolling through thousands of posters; sign-in, PIN and
    /// pairing attempts keep their own much stricter limits.
    /// </summary>
    public const int RequestsPerMinute = 3_000;
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
                if (entry.Count >= RequestsPerMinute) return false;
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
        if (path.Contains("/exclusions/", StringComparison.Ordinal)) return false;
        if (path == "/api/v1/libraries/reset") return true;
        if (path == "/api/v1/auth/pairings") return true;
        if (path == "/api/v1/server/device-pairings/lookup") return false;
        if (path.StartsWith("/api/v1/server/device-pairings/", StringComparison.Ordinal)) return true;
        if (HttpMethods.IsDelete(request.Method) && path.StartsWith("/api/v1/auth/sessions/", StringComparison.Ordinal)) return true;
        if (HttpMethods.IsDelete(request.Method) && path.StartsWith("/api/v1/media/", StringComparison.Ordinal)
            && path.Split('/').Length == 5) return true;
        return path == "/api/v1/server/settings" || path.StartsWith("/api/v1/server/operations", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/server/backups", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/server/sessions", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/users", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/metadata/provider", StringComparison.Ordinal)
            || (path.StartsWith("/api/v1/libraries", StringComparison.Ordinal) && (HttpMethods.IsDelete(request.Method) || path == "/api/v1/libraries"));
    }

    public static bool IsManagementRequest(HttpRequest request)
    {
        var path = (request.Path.Value ?? "").TrimEnd('/').ToLowerInvariant();
        if (path == "/api/v1/server/info" || path == "/api/v1/management/unlock" || path == "/api/v1/management/lock") return false;
        return path.StartsWith("/api/v1/server/", StringComparison.Ordinal) || path.StartsWith("/api/v1/users", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/libraries", StringComparison.Ordinal) || path.StartsWith("/api/v1/scans", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/library-operations", StringComparison.Ordinal) || path.StartsWith("/api/v1/metadata", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/management/", StringComparison.Ordinal) || path.StartsWith("/api/v1/auth/sessions", StringComparison.Ordinal)
            || path == "/api/v1/auth/pairings" || path == "/api/v1/catalog/search/rebuild"
            || path.StartsWith("/api/v1/collections", StringComparison.Ordinal)
            || (path.StartsWith("/api/v1/media/", StringComparison.Ordinal) && (path.Contains("/editor", StringComparison.Ordinal)
                || path.Contains("/metadata/search", StringComparison.Ordinal) || (!HttpMethods.IsGet(request.Method) && !HttpMethods.IsHead(request.Method)
                    && !path.EndsWith("/playback", StringComparison.Ordinal) && !path.EndsWith("/progress", StringComparison.Ordinal)
                    && !path.EndsWith("/watch-state", StringComparison.Ordinal) && !path.EndsWith("/continue-watching", StringComparison.Ordinal)
                    && !path.EndsWith("/favorite", StringComparison.Ordinal) && !path.Contains("/notes", StringComparison.Ordinal))));
    }

    public static string ApprovalAction(HttpRequest request)
    {
        var target = request.HttpContext.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpRequestFeature>()?.RawTarget;
        return request.Method + " " + (string.IsNullOrEmpty(target) ? request.Path.Value + request.QueryString.Value : target);
    }

    public static void RequireManagement(HttpContext context, ProfileSessionStore sessions)
    {
        if (!IsManagementRequest(context.Request)) return;
        if (!context.User.IsInRole(UserRole.Owner.ToString()) && !context.User.IsInRole(UserRole.Admin.ToString()))
            throw new AccountException("administration_required", "This profile cannot manage the server.", 403);
        if (!sessions.ManagementUnlocked(context.User.RequireProfileSessionId()))
            throw new AccountException("management_locked", "Unlock server management with the Server Password. Access lasts ten minutes.", 403);
        var path = (context.Request.Path.Value ?? "").ToLowerInvariant();
        if (!context.User.IsInRole(UserRole.Owner.ToString()) && context.User.FindFirst("aurelia_access_mode")?.Value == nameof(ProfileAccessMode.SelectedTitles)
            && (path.StartsWith("/api/v1/libraries", StringComparison.Ordinal) || path.StartsWith("/api/v1/scans", StringComparison.Ordinal)
                || path.StartsWith("/api/v1/library-operations", StringComparison.Ordinal) || path.EndsWith("/editor/files", StringComparison.Ordinal)))
            throw new AccountException("full_library_access_required", "Storage management and file browsing require full library access, not individual title grants.", 403);
    }

    public static async Task RequireApprovalAsync(HttpContext context, AdministrationApprovalStore approvals)
    {
        var database = context.RequestServices.GetRequiredService<AureliaDbContext>();
        var required = RequiresApproval(context.Request);
        // Legacy device routes must obey the same exact-action policy as current routes.
        if (!required && HttpMethods.IsDelete(context.Request.Method)
            && context.Request.Path.StartsWithSegments("/api/v1/auth/sessions", StringComparison.OrdinalIgnoreCase, out var remaining)
            && Guid.TryParse(remaining.Value?.Trim('/'), out var targetId)
            && context.User.Identity?.IsAuthenticated == true)
        {
            var currentDeviceId = context.User.RequireSessionId();
            required = await database.DeviceSessions.AnyAsync(session => session.Id == targetId && session.Id != currentDeviceId, context.RequestAborted);
        }
        if (!required) return;
        var reset = context.Request.Path.Equals(new PathString("/api/v1/libraries/reset"));
        var removal = HttpMethods.IsDelete(context.Request.Method) && context.Request.Path.StartsWithSegments("/api/v1/media") && (context.Request.Path.Value ?? "").Split('/').Length == 5;
        if (!context.User.IsInRole(UserRole.Owner.ToString()) && !((reset || removal) && context.User.IsInRole(UserRole.Admin.ToString())))
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
        if (!approvals.Consume(context.Request.Headers["X-Aurelia-Approval"].ToString(), context.User.RequireProfileSessionId(),
                ApprovalAction(context.Request), AdministrationApprovalStore.Hash(payload.ToArray()), out var managementGeneration))
            throw new AccountException("approval_required", "Authorize this exact change using the active management unlock. Approvals expire after two minutes and can be used once.", 403);
        var sessionId = context.User.RequireSessionId();
        var now = context.RequestServices.GetRequiredService<TimeProvider>().GetUtcNow();
        if (!await database.DeviceSessions.AnyAsync(session => session.Id == sessionId && session.RevokedAt == null
                && session.ExpiresAt > now && session.User.IsEnabled, context.RequestAborted))
            throw new AccountException("device_session_revoked", "The paired device is no longer authorized.", 403);
        var actorId = context.User.RequireUserId();
        if (!context.RequestServices.GetRequiredService<ProfileSessionStore>().IsActive(context.User.RequireProfileSessionId(), sessionId, actorId)
            || !await database.Users.AnyAsync(user => user.Id == actorId && user.IsEnabled
                && (user.Role == UserRole.Owner || (reset || removal) && user.Role == UserRole.Admin), context.RequestAborted))
            throw new AccountException("profile_session_revoked", "The viewing profile is no longer authorized for this action.", 403);
        if (!context.RequestServices.GetRequiredService<ProfileSessionStore>().ManagementGrantActive(context.User.RequireProfileSessionId(), managementGeneration))
            throw new AccountException("management_locked", "Unlock server management with the Server Password. Access lasts ten minutes.", 403);
        context.Items["Aurelia.AdministrationGeneration"] = managementGeneration;
        context.Items["Aurelia.AdministrationApproved"] = true;
    }
}
