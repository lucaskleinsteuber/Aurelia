using System.Globalization;
using System.Net;
using System.Text.Json;
using Tarven.Contracts;
using Tarven.Server.Authentication;
using Tarven.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Tarven.Server.Services;

public sealed class ServerRequestGuard
{
    public const long MaximumJsonBytes = 65_536;
    /// <summary>
    /// Coarse flood protection per address and minute. Browsing a library loads one image per
    /// title, so the budget fits scrolling through thousands of posters; sign-in, PIN and
    /// pairing attempts keep their own much stricter limits.
    /// </summary>
    public const int RequestsPerMinute = 3_000;
    /// <summary>
    /// Loopback serves the local desktop app, local browser tabs, and CLI simultaneously, so
    /// it gets a higher budget than remote addresses.
    /// </summary>
    public const int LoopbackRequestsPerMinute = 12_000;
    /// <summary>
    /// Playback progress and user-state mutations count in their own bucket so artwork/catalog
    /// bursts cannot starve progress saves with 429.
    /// </summary>
    public const int WriteRequestsPerMinute = 6_000;
    /// <summary>
    /// Timeline preview reads come in short bursts of a few thousand range requests while a
    /// device prepares a title's frames on several cores. They count in their own, larger
    /// bucket so a burst never locks the device out of browsing or playback; the stream
    /// registry still caps how many run at once.
    /// </summary>
    public const int PreviewRequestsPerMinute = 12_000;
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
    /// <summary>
    /// Plain HTTP is only served on the computer's own loopback address, so its requests name
    /// that computer. A web page in a browser there can point its own name at 127.0.0.1 (DNS
    /// rebinding); such requests carry the page's name and are refused. HTTPS is not affected:
    /// a browser accepts the server's certificate for one address only.
    /// </summary>
    public static bool HostAllowed(HttpRequest request)
    {
        if (request.IsHttps || !request.Host.HasValue) return true;
        var host = request.Host.Host;
        return string.Equals(host, "localhost", StringComparison.OrdinalIgnoreCase)
            || (IPAddress.TryParse(host.Trim('[', ']'), out var address) && IPAddress.IsLoopback(address));
    }

    public const int TrackedAddresses = 4_096;

    /// <summary>
    /// One device counts once: an IPv6 address counts by its /64 network, since a device makes up
    /// new addresses within it all the time (privacy addresses).
    /// </summary>
    internal static string AddressKey(IPAddress? address)
    {
        if (address is null) return "local";
        var ip = address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
        if (ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetworkV6 || IPAddress.IsLoopback(ip)) return ip.ToString();
        var bytes = ip.GetAddressBytes();
        Array.Clear(bytes, 8, 8);
        return new IPAddress(bytes).ToString() + "/64";
    }

    public bool Admit(IPAddress? address, bool preview = false, bool userStateWrite = false)
    {
        var isLoopback = address is null || IPAddress.IsLoopback(address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address);
        var bucket = preview ? "preview:" : userStateWrite ? "write:" : "";
        var key = bucket + AddressKey(address);
        var limit = preview
            ? PreviewRequestsPerMinute
            : isLoopback
                ? LoopbackRequestsPerMinute
                : userStateWrite
                    ? WriteRequestsPerMinute
                    : RequestsPerMinute;
        var now = DateTimeOffset.UtcNow;
        lock (gate)
        {
            if (addresses.Count >= TrackedAddresses)
                foreach (var stale in addresses.Where(pair => now - pair.Value.Window >= TimeSpan.FromMinutes(1)).Select(pair => pair.Key).ToArray())
                    addresses.Remove(stale);
            if (addresses.TryGetValue(key, out var entry) && now - entry.Window < TimeSpan.FromMinutes(1))
            {
                if (entry.Count >= limit) return false;
                addresses[key] = (entry.Count + 1, entry.Window);
            }
            else
            {
                // A full table makes room by forgetting the address seen longest ago, instead of
                // refusing every new address (audit S-L5).
                if (addresses.Count >= TrackedAddresses)
                    addresses.Remove(addresses.MinBy(pair => pair.Value.Window).Key);
                addresses[key] = (1, now);
            }
            return true;
        }
    }

    /// <summary>
    /// Partition key for the "authentication" rate limiter: IPv6 counts by /64 so privacy-address
    /// rotation cannot bypass limits, while authenticated sessions partition per device session and
    /// route so one device's failed PIN guesses cannot lock out other devices or profiles sharing
    /// loopback or a NAT IP.
    /// </summary>
    internal static string AuthenticationPartitionKey(HttpContext context)
    {
        var address = AddressKey(context.Connection.RemoteIpAddress);
        if (context.User.Identity?.IsAuthenticated == true)
        {
            var sessionId = context.User.FindFirst(DeviceTokenAuthenticationHandler.SessionIdClaim)?.Value;
            if (!string.IsNullOrEmpty(sessionId))
            {
                var path = (context.Request.Path.Value ?? string.Empty).TrimEnd('/').ToLowerInvariant();
                return $"{address}:session:{sessionId}:{path}";
            }
        }
        return address;
    }

    /// <summary>Small user-state write endpoints (progress, favorites, watchlist, notes) kept separate from catalog/artwork floods.</summary>
    public static bool IsUserStateWrite(HttpRequest request)
    {
        if (HttpMethods.IsGet(request.Method) || HttpMethods.IsHead(request.Method)) return false;
        var path = request.Path.Value ?? string.Empty;
        return path.EndsWith("/progress", StringComparison.OrdinalIgnoreCase)
            || path.EndsWith("/favorite", StringComparison.OrdinalIgnoreCase)
            || path.EndsWith("/watched", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/watchlist", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/notes", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/continue-watching", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Maximum byte span allowed for a client-marked timeline preview range read (4 MiB).</summary>
    public const long MaximumPreviewRangeBytes = 4L * 1024 * 1024;

    /// <summary>A bounded direct file-stream read (or HEAD) or scrub-preview read marked as a timeline preview.</summary>
    public static bool IsPreviewStream(HttpRequest request)
    {
        if (request.Path.StartsWithSegments("/api/v1/media")
            && (request.Path.Value ?? string.Empty).Contains("/scrub-previews", StringComparison.Ordinal))
        {
            return true;
        }

        if (!string.Equals(LegacyNames.Header(request, "X-Tarven-Stream-Purpose"), "preview", StringComparison.OrdinalIgnoreCase))
            return false;

        // Only direct file stream reads (/api/v1/streams/{ticket}) may use the preview lane;
        // never /live, /hls, /speech-audio, or /subtitles.
        if (!request.Path.StartsWithSegments("/api/v1/streams", out var remaining))
            return false;
        var segment = (remaining.Value ?? string.Empty).Trim('/');
        if (segment.Length == 0 || segment.Contains('/'))
            return false;

        if (HttpMethods.IsHead(request.Method))
            return true;
        if (!HttpMethods.IsGet(request.Method))
            return false;

        var range = request.GetTypedHeaders().Range;
        if (range is null || !string.Equals(range.Unit.Value, "bytes", StringComparison.OrdinalIgnoreCase) || range.Ranges.Count != 1)
            return false;
        var span = range.Ranges.First();
        if (span.From is not { } from || span.To is not { } to || from < 0 || to < from)
            return false;
        return (to - from + 1) <= MaximumPreviewRangeBytes;
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

        // 0. Critical: who may confirm management, and the security settings and block list.
        if (IsPasskeyChange(request.Method, path)) return true;
        if (HttpMethods.IsPut(request.Method) && path == "/api/v1/server/security/settings") return true;
        if (HttpMethods.IsDelete(request.Method) && path.StartsWith("/api/v1/server/security/blocked/", StringComparison.Ordinal)) return true;

        // 1. Critical: Library reset and permanent media removal from library database
        if (path == "/api/v1/libraries/reset") return true;
        if (HttpMethods.IsDelete(request.Method) && path.StartsWith("/api/v1/media/", StringComparison.Ordinal)
            && path.Split('/').Length == 5) return true;

        // 2. Critical: Backup restore (overwrites database)
        if (path.StartsWith("/api/v1/server/backups/restore", StringComparison.Ordinal)) return true;
        // Moving the server to another computer hands out its whole state; marking or undoing a
        // move decides which computer answers devices (docs/SERVER_MOVE.md).
        if (path is "/api/v1/server/move" or "/api/v1/server/move/mark-moved") return true;
        // Storage Location Moved rewrites where a location's titles are.
        if (HttpMethods.IsPost(request.Method) && path.StartsWith("/api/v1/libraries/", StringComparison.Ordinal) && path.EndsWith("/relocate", StringComparison.Ordinal)
            && path.Split('/').Length == 6) return true;

        // 3. Critical: Factory reset / destructive reset operations
        if (path == "/api/v1/server/reset"
            || (path.StartsWith("/api/v1/server/operations", StringComparison.Ordinal) && path.Contains("reset", StringComparison.Ordinal)))
            return true;

        // 4. Critical: Server password modification
        if (path == "/api/v1/server/password") return true;

        // 5. Critical: Changing user role (who is owner/admin) or resetting owner/admin password
        if (HttpMethods.IsPut(request.Method) && path.StartsWith("/api/v1/users/", StringComparison.Ordinal)
            && (path.EndsWith("/role", StringComparison.Ordinal) || path.EndsWith("/password", StringComparison.Ordinal)))
            return true;

        // 6. Critical: Deleting user (owner/admin user deletion is critical; ordinary user deletion does not require approval)
        if (HttpMethods.IsDelete(request.Method) && path.StartsWith("/api/v1/users/", StringComparison.Ordinal))
            return true;

        return false;
    }

    /// <summary>Adding or removing a Face ID / Touch ID key: administrators may do it for their own profile.</summary>
    public static bool IsPasskeyChange(string method, string path) =>
        (HttpMethods.IsPost(method) && path == "/api/v1/management/passkeys")
        || (HttpMethods.IsDelete(method) && path.StartsWith("/api/v1/management/passkeys/", StringComparison.Ordinal));

    public static bool IsManagementRequest(HttpRequest request)
    {
        var path = (request.Path.Value ?? "").TrimEnd('/').ToLowerInvariant();
        if (path == "/api/v1/server/info" || path == "/api/v1/management/unlock" || path == "/api/v1/management/lock") return false;
        return path.StartsWith("/api/v1/server/", StringComparison.Ordinal) || path.StartsWith("/api/v1/users", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/libraries", StringComparison.Ordinal) || path.StartsWith("/api/v1/scans", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/library-operations", StringComparison.Ordinal) || path.StartsWith("/api/v1/metadata", StringComparison.Ordinal)
            || path.StartsWith("/api/v1/management/", StringComparison.Ordinal) || path.StartsWith("/api/v1/auth/sessions", StringComparison.Ordinal)
            || path == "/api/v1/auth/pairings" || path == "/api/v1/catalog/search/rebuild"
            || (path.StartsWith("/api/v1/media/", StringComparison.Ordinal) && (path.Contains("/editor", StringComparison.Ordinal)
                || path.Contains("/metadata/search", StringComparison.Ordinal) || path.EndsWith("/subtitles", StringComparison.Ordinal)
                || path.EndsWith("/subtitles/search", StringComparison.Ordinal) || (!HttpMethods.IsGet(request.Method) && !HttpMethods.IsHead(request.Method)
                    && !path.EndsWith("/playback", StringComparison.Ordinal) && !path.EndsWith("/conversion", StringComparison.Ordinal)
                    && !path.EndsWith("/progress", StringComparison.Ordinal)
                    && !path.EndsWith("/watch-state", StringComparison.Ordinal) && !path.EndsWith("/continue-watching", StringComparison.Ordinal)
                    && !path.EndsWith("/favorite", StringComparison.Ordinal) && !path.EndsWith("/watchlist", StringComparison.Ordinal)
                    && !path.Contains("/scrub-previews", StringComparison.Ordinal) && !path.Contains("/notes", StringComparison.Ordinal))));
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
        var path = (context.Request.Path.Value ?? "").ToLowerInvariant();
        if (!context.User.IsInRole(UserRole.Owner.ToString()) && context.User.FindFirst("tarven_access_mode")?.Value == nameof(ProfileAccessMode.SelectedTitles)
            && (path.StartsWith("/api/v1/libraries", StringComparison.Ordinal) || path.StartsWith("/api/v1/scans", StringComparison.Ordinal)
                || path.StartsWith("/api/v1/library-operations", StringComparison.Ordinal) || path.EndsWith("/editor/files", StringComparison.Ordinal)))
            throw new AccountException("full_library_access_required", "Storage management and file browsing require full library access, not individual title grants.", 403);
    }

    /// <summary>
    /// The other ways to change who manages the server (docs/SECURITY_MODEL.md): a new owner or
    /// administrator, a changed role, or an owner or administrator switched off, given a new PIN
    /// by someone else, or having libraries or titles revoked. These need the Server Password like
    /// <c>PUT /users/{id}/role</c>; a stolen owner PIN alone must not make a new owner or cut off
    /// an administrator (audit S-M1, SRV-SEC-003).
    /// </summary>
    internal static async Task<bool> ChangesWhoManagesAsync(HttpContext context, TarvenDbContext database)
    {
        var request = context.Request;
        if (context.User.Identity?.IsAuthenticated != true || !MayChangeWhoManages(request.Method, request.Path.Value)) return false;
        var segments = (request.Path.Value ?? string.Empty).TrimEnd('/').ToLowerInvariant().Split('/');
        var creating = segments.Length == 4;
        var action = creating ? null : segments[5];

        using var body = await ReadJsonAsync(request, context.RequestAborted);
        // Anything but an object can't bind to the request; the endpoint refuses it with 400.
        if (body is null || body.RootElement.ValueKind != JsonValueKind.Object) return false;
        var root = body.RootElement;
        // The endpoint binds property names in any case, and of repeated names it keeps one; so every
        // spelling and every copy of a name counts here (audit 2026-11-21, SRV-SEC-001).
        IEnumerable<JsonElement> Values(string name) => root.EnumerateObject()
            .Where(property => property.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
            .Select(property => property.Value);
        List<UserRole> Roles() => [.. Values("role")
            .Where(value => value.ValueKind == JsonValueKind.String)
            .Select(value => Enum.TryParse<UserRole>(value.GetString(), ignoreCase: true, out var role) ? role : (UserRole?)null)
            .OfType<UserRole>()];
        static bool Elevated(UserRole role) => role is UserRole.Owner or UserRole.Admin;
        if (creating) return Roles().Any(Elevated);

        var targetId = Guid.Parse(segments[4]);
        var target = await database.Users.AsNoTracking().Where(user => user.Id == targetId)
            .Select(user => new { user.Role, user.AccessMode }).SingleOrDefaultAsync(context.RequestAborted);
        if (target is null) return false;
        var self = context.User.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)?.Value is { } actor
            && Guid.TryParse(actor, out var actorId) && actorId == targetId;
        bool SwitchedOff() => Values("isEnabled").Any(enabled => enabled.ValueKind == JsonValueKind.False);
        bool NewPin() => Values("pin").Any(pin => pin.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(pin.GetString()));
        static ProfileAccessMode? ParseAccessMode(JsonElement value)
        {
            if (value.ValueKind == JsonValueKind.String
                && value.GetString() is { } text
                && !int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out _)
                && Enum.TryParse<ProfileAccessMode>(text, ignoreCase: true, out var parsed)
                && Enum.IsDefined(parsed))
            {
                return parsed;
            }
            if (value.ValueKind == JsonValueKind.Number
                && value.TryGetInt32(out var numeric)
                && Enum.IsDefined((ProfileAccessMode)numeric))
            {
                return (ProfileAccessMode)numeric;
            }
            return null;
        }
        async Task<bool> RevokesLibrariesAsync()
        {
            var libraryValues = Values("libraryIds").ToList();
            if (libraryValues.Count == 0) return true;
            var currentLibraries = target.AccessMode == ProfileAccessMode.LegacyLibraries
                ? await database.UserLibraryGrants.IgnoreQueryFilters().AsNoTracking()
                    .Where(grant => grant.UserId == targetId)
                    .Select(grant => grant.LibraryRootId)
                    .ToListAsync(context.RequestAborted)
                : await database.LibraryRoots.IgnoreQueryFilters().AsNoTracking()
                    .Select(library => library.Id)
                    .ToListAsync(context.RequestAborted);
            foreach (var value in libraryValues)
            {
                if (value.ValueKind != JsonValueKind.Array) return true;
                var requested = new HashSet<Guid>();
                foreach (var item in value.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.String && Guid.TryParse(item.GetString(), out var id))
                        requested.Add(id);
                }
                if (requested.Count == 0 || currentLibraries.Any(id => !requested.Contains(id))) return true;
            }
            return false;
        }
        async Task<bool> RevokesTitlesAsync(string modeProperty, bool modeOptional)
        {
            var modeValues = Values(modeProperty)
                .Where(value => !modeOptional || value.ValueKind != JsonValueKind.Null)
                .ToList();
            if (modeOptional && modeValues.Count == 0) return false;
            if (modeValues.Count > 0 && modeValues.All(value => ParseAccessMode(value) == ProfileAccessMode.EntireLibrary))
                return false;
            if (target.AccessMode != ProfileAccessMode.SelectedTitles) return true;
            var currentTitles = await database.UserTitleGrants.IgnoreQueryFilters().AsNoTracking()
                .Where(grant => grant.UserId == targetId)
                .Select(grant => grant.MediaItemId)
                .ToListAsync(context.RequestAborted);
            var titleValues = Values("titleIds").ToList();
            if (titleValues.Count == 0) return true;
            foreach (var value in titleValues)
            {
                if (value.ValueKind != JsonValueKind.Array) return true;
                var requested = new HashSet<Guid>();
                foreach (var item in value.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.String && Guid.TryParse(item.GetString(), out var id))
                        requested.Add(id);
                }
                if (requested.Count == 0 || currentTitles.Any(id => !requested.Contains(id))) return true;
            }
            return false;
        }
        return action switch
        {
            "profile" => Roles().Any(role => role != target.Role)
                || (Elevated(target.Role) && (SwitchedOff() || (NewPin() && !self) || await RevokesTitlesAsync("accessMode", modeOptional: true))),
            "enabled" => Elevated(target.Role) && SwitchedOff(),
            "access" => Elevated(target.Role) && (SwitchedOff() || await RevokesLibrariesAsync()),
            "titles" => Elevated(target.Role) && await RevokesTitlesAsync("mode", modeOptional: false),
            "pin" => Elevated(target.Role) && !self,
            _ => false,
        };
    }

    /// <summary>
    /// Requests that may change who manages the server, by address alone: creating a profile, and its
    /// profile, enabled, access, titles and PIN changes. Their content decides (<see cref="ChangesWhoManagesAsync"/>).
    /// </summary>
    public static bool MayChangeWhoManages(string method, string? path)
    {
        var segments = (path ?? string.Empty).TrimEnd('/').ToLowerInvariant().Split('/');
        // "", "api", "v1", "users"[, id, action]
        if (segments.Length < 4 || segments[1] != "api" || segments[2] != "v1" || segments[3] != "users") return false;
        if (segments.Length == 4) return HttpMethods.IsPost(method);
        return segments.Length == 6 && HttpMethods.IsPut(method) && Guid.TryParse(segments[4], out _)
            && segments[5] is "profile" or "enabled" or "access" or "titles" or "pin";
    }

    /// <summary>The request's JSON body, read once and left in place for the endpoint.</summary>
    private static async Task<JsonDocument?> ReadJsonAsync(HttpRequest request, CancellationToken cancellation)
    {
        request.EnableBuffering(bufferThreshold: 65_536, bufferLimit: MaximumJsonBytes + 1);
        try { return await JsonDocument.ParseAsync(request.Body, cancellationToken: cancellation); }
        catch (JsonException) { return null; }
        finally { request.Body.Position = 0; }
    }

    public static async Task RequireApprovalAsync(HttpContext context, AdministrationApprovalStore approvals)
    {
        var database = context.RequestServices.GetRequiredService<TarvenDbContext>();
        var required = RequiresApproval(context.Request);
        if (required && HttpMethods.IsDelete(context.Request.Method)
            && context.Request.Path.StartsWithSegments("/api/v1/users", StringComparison.OrdinalIgnoreCase, out var remainingUser)
            && Guid.TryParse(remainingUser.Value?.Trim('/'), out var targetUserId))
        {
            required = await database.Users.AsNoTracking().AnyAsync(u => u.Id == targetUserId && (u.Role == UserRole.Owner || u.Role == UserRole.Admin), context.RequestAborted);
        }
        if (!required) required = await ChangesWhoManagesAsync(context, database);
        if (!required) return;
        var reset = context.Request.Path.Equals(new PathString("/api/v1/libraries/reset"));
        var removal = HttpMethods.IsDelete(context.Request.Method) && context.Request.Path.StartsWithSegments("/api/v1/media") && (context.Request.Path.Value ?? "").Split('/').Length == 5;
        var passkey = IsPasskeyChange(context.Request.Method, (context.Request.Path.Value ?? string.Empty).TrimEnd('/').ToLowerInvariant());
        var adminAllowed = reset || removal || passkey;
        if (!context.User.IsInRole(UserRole.Owner.ToString()) && !(adminAllowed && context.User.IsInRole(UserRole.Admin.ToString())))
            throw new AccountException("owner_required", "Only an owner may change global server settings.", 403);

        var sessions = context.RequestServices.GetRequiredService<ProfileSessionStore>();
        if (!sessions.ManagementUnlocked(context.User.RequireProfileSessionId()))
            throw new AccountException("management_locked", "Unlock server management with the Server Password. Access lasts ten minutes.", 403);

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
        if (!approvals.Consume(LegacyNames.Header(context.Request, "X-Tarven-Approval") ?? "", context.User.RequireProfileSessionId(),
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
                && (user.Role == UserRole.Owner || adminAllowed && user.Role == UserRole.Admin), context.RequestAborted))
            throw new AccountException("profile_session_revoked", "The viewing profile is no longer authorized for this action.", 403);
        if (!context.RequestServices.GetRequiredService<ProfileSessionStore>().ManagementGrantActive(context.User.RequireProfileSessionId(), managementGeneration))
            throw new AccountException("management_locked", "Unlock server management with the Server Password. Access lasts ten minutes.", 403);
        context.Items["Tarven.AdministrationGeneration"] = managementGeneration;
        context.Items["Tarven.AdministrationApproved"] = true;
    }
}
