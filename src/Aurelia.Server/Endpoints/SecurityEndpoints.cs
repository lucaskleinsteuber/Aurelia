using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Endpoints;

/// <summary>The security log, signed-in devices, the block list and Face ID / Touch ID ("security-v1").</summary>
public static class SecurityEndpoints
{
    public const string Feature = "security-v1";

    public static void MapSecurityEndpoints(this WebApplication app)
    {
        var security = app.MapGroup("/api/v1/server/security").RequireAuthorization("Owner");

        security.MapGet("/events", async (string? outcome, DateTimeOffset? before, int? limit, SecurityLog log, AureliaDbContext database, CancellationToken token) =>
        {
            await log.FlushAsync(token);
            var take = Math.Clamp(limit ?? 100, 1, 500);
            var query = database.SecurityEvents.AsNoTracking();
            if (outcome is SecurityLog.Succeeded or SecurityLog.Failed or SecurityLog.Changed) query = query.Where(entry => entry.Outcome == outcome);
            if (before is { } cutoff) query = query.Where(entry => entry.At < cutoff);
            var events = await query.OrderByDescending(entry => entry.At).Take(take + 1).ToListAsync(token);
            var page = events.Take(take).Select(entry => new SecurityEventSummary(entry.Id, entry.At, entry.Kind, entry.Outcome, entry.UserId,
                entry.UserName, entry.DeviceSessionId, entry.DeviceName, entry.Platform, entry.IpAddress, entry.Detail)).ToArray();
            return new SecurityEventPage(page, events.Count > take ? page[^1].At : null);
        });

        security.MapGet("/devices", async (AureliaDbContext database, TimeProvider clock, HttpContext context, CancellationToken token) =>
            await DevicesAsync(database, clock, context.User.RequireSessionId(), onlyNew: false, token));

        security.MapPost("/devices/{id:guid}/acknowledge", async (Guid id, AureliaDbContext database, TimeProvider clock, SecurityAlertSignal alerts, CancellationToken token) =>
        {
            var changed = await database.DeviceSessions.Where(session => session.Id == id && session.AcknowledgedAt == null)
                .ExecuteUpdateAsync(update => update.SetProperty(session => session.AcknowledgedAt, clock.GetUtcNow()), token);
            if (changed > 0) alerts.Bump();
            return Results.NoContent();
        });

        security.MapPost("/devices/{id:guid}/block", async (Guid id, AureliaDbContext database, TimeProvider clock, SecurityAlertSignal alerts,
            SecurityLog log, ActiveStreamRegistry streams, ProfileSessionStore profiles, HttpContext context, CancellationToken token) =>
        {
            if (id == context.User.RequireSessionId())
                throw new AccountException("cannot_block_current_device", "This is the device you are using. Block it from another one.", 409);
            var target = await database.DeviceSessions.Include(session => session.User).SingleOrDefaultAsync(session => session.Id == id, token)
                ?? throw new AccountException("session_not_found", "The device was not found.", 404);
            var now = clock.GetUtcNow();
            var listed = false;
            var affected = new List<DeviceSession> { target };
            if (target.InstallationId is { } installation)
            {
                affected = await database.DeviceSessions.Where(session => session.InstallationId == installation && session.RevokedAt == null).ToListAsync(token);
                if (!affected.Contains(target)) affected.Add(target);
                if (!await database.BlockedDevices.AnyAsync(blocked => blocked.InstallationId == installation, token))
                {
                    database.BlockedDevices.Add(new BlockedDevice
                    {
                        Id = Guid.NewGuid(),
                        InstallationId = installation,
                        DeviceName = target.DeviceName,
                        Platform = target.Platform,
                        IpAddress = target.LastIpAddress,
                        BlockedAt = now,
                        BlockedByUserId = context.User.RequireUserId(),
                    });
                }
                listed = true;
            }
            foreach (var session in affected)
            {
                session.RevokedAt ??= now;
                session.AcknowledgedAt ??= now;
            }
            await database.SaveChangesAsync(token);
            foreach (var session in affected)
            {
                streams.RevokeSession(session.Id);
                profiles.RevokeDevice(session.Id);
            }
            log.Record(context, "device_blocked", SecurityLog.Changed, target.DeviceName);
            alerts.Bump();
            return new BlockDeviceResponse(listed, affected.Count);
        });

        security.MapGet("/blocked", async (AureliaDbContext database, CancellationToken token) =>
            (await database.BlockedDevices.AsNoTracking().ToListAsync(token)).OrderByDescending(blocked => blocked.BlockedAt)
                .Select(blocked => new BlockedDeviceSummary(blocked.Id, blocked.DeviceName, blocked.Platform, blocked.IpAddress, blocked.BlockedAt)));

        security.MapDelete("/blocked/{id:guid}", async (Guid id, AureliaDbContext database, SecurityLog log, HttpContext context, CancellationToken token) =>
        {
            var blocked = await database.BlockedDevices.SingleOrDefaultAsync(value => value.Id == id, token)
                ?? throw new AccountException("blocked_device_not_found", "This device is not blocked.", 404);
            database.BlockedDevices.Remove(blocked);
            await database.SaveChangesAsync(token);
            log.Record(context, "device_unblocked", SecurityLog.Changed, blocked.DeviceName);
            return Results.NoContent();
        });

        security.MapGet("/settings", async (SecuritySettingsStore settings, AureliaDbContext database, CancellationToken token) =>
            new SecuritySettingsResponse(settings.Current.SecurityLogDays, settings.Current.RequirePasskeysForAdministrators,
                await database.ManagementPasskeys.CountAsync(token)));

        security.MapPut("/settings", async (UpdateSecuritySettingsRequest request, SecuritySettingsStore settings, SecurityLog log,
            AureliaDbContext database, HttpContext context, CancellationToken token) =>
        {
            var previous = settings.Current;
            var owner = context.User.RequireUserId();
            if (request.RequirePasskeysForAdministrators && !previous.RequirePasskeysForAdministrators
                && !await database.ManagementPasskeys.AnyAsync(passkey => passkey.UserId == owner, token))
                throw new AccountException("passkey_needed_first", "Set up Face ID or Touch ID for your own profile first, so you can still manage the server.", 409);
            var saved = settings.Update(new SecuritySettings(request.SecurityLogDays, request.RequirePasskeysForAdministrators));
            if (saved.RequirePasskeysForAdministrators != previous.RequirePasskeysForAdministrators)
                log.Record(context, "passkey_requirement_changed", SecurityLog.Changed, saved.RequirePasskeysForAdministrators ? "Required" : "Optional");
            if (saved.SecurityLogDays != previous.SecurityLogDays)
                log.Record(context, "security_settings_changed", SecurityLog.Changed, $"Log kept {saved.SecurityLogDays} days");
            return new SecuritySettingsResponse(saved.SecurityLogDays, saved.RequirePasskeysForAdministrators, await database.ManagementPasskeys.CountAsync(token));
        });

        app.MapGet("/api/v1/server/security/alerts", async (long? version, int? waitSeconds, SecurityAlertSignal alerts, PasskeyService passkeys,
            AureliaDbContext database, TimeProvider clock, HttpContext context, CancellationToken token) =>
        {
            await alerts.WaitAsync(version ?? 0, TimeSpan.FromSeconds(Math.Clamp(waitSeconds ?? 0, 0, 30)), token);
            var current = alerts.Version;
            var owner = context.User.IsInRole(nameof(UserRole.Owner));
            var userId = context.User.RequireUserId();
            var sessionId = context.User.RequireSessionId();
            var devices = owner ? await DevicesAsync(database, clock, sessionId, onlyNew: true, token) : [];
            var canConfirm = await database.ManagementPasskeys.AnyAsync(passkey => passkey.UserId == userId && passkey.DeviceSessionId == sessionId, token);
            var unlocks = canConfirm ? passkeys.PendingFor(userId, owner) : [];
            return new SecurityAlertsResponse(current, devices, unlocks);
        }).RequireAuthorization("Administrator");

        var management = app.MapGroup("/api/v1/management").RequireAuthorization("Administrator");

        management.MapPost("/passkey-challenge", (PasskeyService passkeys, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            return passkeys.CreateChallenge(context.User.RequireProfileSessionId());
        });

        management.MapGet("/passkeys", async (AureliaDbContext database, HttpContext context, CancellationToken token) =>
        {
            var owner = context.User.IsInRole(nameof(UserRole.Owner));
            var userId = context.User.RequireUserId();
            var session = context.User.RequireSessionId();
            var keys = await database.ManagementPasskeys.AsNoTracking().Include(passkey => passkey.User)
                .Where(passkey => owner || passkey.UserId == userId).ToListAsync(token);
            return keys.OrderByDescending(passkey => passkey.CreatedAt)
                .Select(passkey => PasskeyService.Summary(passkey, passkey.User.DisplayName ?? passkey.User.Username, session));
        });

        management.MapPost("/passkeys", async (RegisterPasskeyRequest request, PasskeyService passkeys, AureliaDbContext database,
            SecurityLog log, HttpContext context, CancellationToken token) =>
        {
            RequirePrivateTransport(context);
            var summary = await passkeys.RegisterAsync(database, context.User.RequireUserId(), context.User.RequireSessionId(),
                context.User.RequireProfileSessionId(), request, token);
            log.Record(context, "passkey_added", SecurityLog.Changed, summary.Name);
            return summary;
        }).RequireRateLimiting("authentication");

        management.MapDelete("/passkeys/{id:guid}", async (Guid id, AureliaDbContext database, SecurityLog log, SecuritySettingsStore settings,
            HttpContext context, CancellationToken token) =>
        {
            var owner = context.User.IsInRole(nameof(UserRole.Owner));
            var userId = context.User.RequireUserId();
            var passkey = await database.ManagementPasskeys.SingleOrDefaultAsync(value => value.Id == id && (owner || value.UserId == userId), token)
                ?? throw new AccountException("passkey_not_found", "This key was not found.", 404);
            if (settings.Current.RequirePasskeysForAdministrators && passkey.UserId == userId
                && await database.ManagementPasskeys.CountAsync(value => value.UserId == userId, token) == 1
                && owner)
                throw new AccountException("passkey_last_required", "This is your last key while Face ID or Touch ID is required. Turn the requirement off first.", 409);
            database.ManagementPasskeys.Remove(passkey);
            await database.SaveChangesAsync(token);
            log.Record(context, "passkey_removed", SecurityLog.Changed, passkey.Name);
            return Results.NoContent();
        });

        management.MapPost("/passkey-unlock", async (PasskeyUnlockRequest request, PasskeyService passkeys, ProfileSessionStore sessions,
            AureliaDbContext database, SecurityLog log, HttpContext context, CancellationToken token) =>
        {
            RequirePrivateTransport(context);
            var profile = context.User.RequireProfileSessionId();
            var epoch = sessions.ManagementEpoch(profile);
            var passkey = await passkeys.VerifyAsync(database, context.User.RequireUserId(), context.User.RequireSessionId(), profile,
                request.PasskeyId, request.Challenge, request.Signature, "unlock", token);
            var expires = sessions.UnlockManagement(profile, epoch);
            log.Record(context, "management_unlocked", SecurityLog.Succeeded, "Face ID or Touch ID · " + passkey.Name);
            return new ManagementUnlockResponse(expires);
        });

        management.MapPost("/remote-unlock", async (PasskeyService passkeys, AureliaDbContext database, HttpContext context, CancellationToken token) =>
        {
            RequirePrivateTransport(context);
            var userId = context.User.RequireUserId();
            var sessionId = context.User.RequireSessionId();
            var user = await database.Users.AsNoTracking().SingleAsync(value => value.Id == userId, token);
            var device = await database.DeviceSessions.AsNoTracking().SingleAsync(value => value.Id == sessionId, token);
            return passkeys.StartRemoteUnlock(context.User.RequireProfileSessionId(), userId, sessionId, user.DisplayName ?? user.Username,
                device.DeviceName, ClientIdentity.From(context).IpAddress);
        });

        management.MapGet("/remote-unlock/{id:guid}", (Guid id, PasskeyService passkeys, ProfileSessionStore sessions, SecurityLog log, HttpContext context) =>
        {
            var profile = context.User.RequireProfileSessionId();
            var (status, grant) = passkeys.RemoteStatus(id, profile);
            if (!grant) return status;
            var expires = sessions.UnlockManagement(profile);
            log.Record(context, "management_unlocked", SecurityLog.Succeeded, "Confirmed on another device");
            return status with { ManagementExpiresAt = expires };
        });

        management.MapPost("/remote-unlock/{id:guid}/decide", async (Guid id, DecideRemoteUnlockRequest request, PasskeyService passkeys,
            AureliaDbContext database, SecurityLog log, HttpContext context, CancellationToken token) =>
        {
            RequirePrivateTransport(context);
            var owner = context.User.IsInRole(nameof(UserRole.Owner));
            var userId = context.User.RequireUserId();
            var pending = passkeys.FindRemote(id) ?? throw new AccountException("remote_unlock_not_found", "This request was not found.", 404);
            if (request.Approve)
            {
                if (request.PasskeyId is not { } passkeyId) throw PasskeyService.Invalid();
                await passkeys.VerifyAsync(database, userId, context.User.RequireSessionId(), context.User.RequireProfileSessionId(),
                    passkeyId, request.Challenge, request.Signature, "remote:" + id.ToString("N"), token);
            }
            passkeys.DecideRemote(id, userId, owner, request.Approve);
            log.Record(context, request.Approve ? "remote_unlock_approved" : "remote_unlock_denied", SecurityLog.Changed,
                $"{pending.ProfileName} on {pending.DeviceName}");
            return Results.NoContent();
        });
    }

    internal static async Task<SecurityDeviceSummary[]> DevicesAsync(AureliaDbContext database, TimeProvider clock, Guid currentSession,
        bool onlyNew, CancellationToken token)
    {
        var now = clock.GetUtcNow();
        var sessions = await database.DeviceSessions.AsNoTracking().Include(session => session.User)
            .Where(session => session.RevokedAt == null && session.ExpiresAt > now && (!onlyNew || (session.AcknowledgedAt == null && session.Id != currentSession)))
            .ToListAsync(token);
        return sessions.OrderByDescending(session => session.CreatedAt)
            .Select(session => new SecurityDeviceSummary(session.Id, session.UserId, session.User.DisplayName ?? session.User.Username,
                session.DeviceName, session.Platform, session.ClientVersion, session.LastIpAddress, session.CreatedAt, session.LastSeenAt,
                session.AcknowledgedAt is null, session.Id != currentSession, session.Id == currentSession))
            .ToArray();
    }

    private static void RequirePrivateTransport(HttpContext context)
    {
        if (!context.Request.IsHttps && context.Connection.RemoteIpAddress is not null && !ClientIdentity.IsLoopback(context))
            throw new AccountException("https_required", "Credentials require the verified HTTPS connection.", 403);
    }
}
