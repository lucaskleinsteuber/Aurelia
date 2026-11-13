using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class DeviceAuthorizationService(
    AureliaDbContext database,
    TokenService tokens,
    ServerConfigurationStore configuration,
    TimeProvider clock,
    DeviceAuthorizationGuard guard,
    IDataProtectionProvider protection,
    ProfileSessionStore profiles,
    CatalogMutationGate mutations,
    IHttpContextAccessor http,
    SecurityLog securityLog,
    SecurityAlertSignal securityAlerts)
{
    private const int PollIntervalSeconds = 5;
    private static readonly JsonSerializerOptions Json = CreateJsonOptions();

    public async Task<DeviceAuthorizationStartResponse> StartAsync(string deviceName, string address, CancellationToken token)
    {
        guard.Admit("start", address);
        RequireEnabled();
        var name = (deviceName ?? string.Empty).Trim().Normalize(NormalizationForm.FormKC);
        if (name.Length is < 1 or > 128 || name.Any(char.IsControl))
            throw new AccountException("invalid_device_name", "The device name must contain 1 to 128 visible characters.", 400);
        using var lease = await guard.EnterAsync(token);
        var now = clock.GetUtcNow();
        if (!await database.Users.AnyAsync(user => user.IsEnabled && user.Role == UserRole.Owner, token))
            throw new AccountException("server_setup_required", "Set up an owner before pairing another device.", 409);
        var identity = ClientIdentity.From(http.HttpContext);
        if (identity.InstallationId is { } installation && await database.BlockedDevices.AnyAsync(blocked => blocked.InstallationId == installation, token))
            throw AccountService.DeviceBlocked();
        if (await database.DeviceAuthorizationRequests.CountAsync(request => request.ExpiresAt > now, token) >= 1000)
            throw new AccountException("device_pairing_limit", "Too many pending device pairings. Try again shortly.", 429);
        string code;
        string codeHash;
        do
        {
            code = tokens.CreatePairingCode();
            codeHash = tokens.Hash(code);
        } while (await database.DeviceAuthorizationRequests.AnyAsync(request => request.CodeHash == codeHash, token));
        var secret = tokens.CreateDeviceToken();
        var request = new DeviceAuthorizationRequest
        {
            Id = Guid.NewGuid(),
            DeviceName = name,
            CodeHash = codeHash,
            SecretHash = tokens.Hash(secret),
            State = DeviceAuthorizationState.Pending,
            CreatedAt = now,
            ExpiresAt = now.AddMinutes(5),
        };
        database.DeviceAuthorizationRequests.Add(request);
        await database.SaveChangesAsync(token);
        return new(request.Id, code, secret, request.ExpiresAt, PollIntervalSeconds);
    }

    public async Task<DeviceAuthorizationPreview> LookupAsync(string code, Guid ownerId, Guid deviceId, Guid profileId, string address, CancellationToken token)
    {
        guard.Admit("lookup", address + ":" + profileId);
        RequireEnabled();
        using var lease = await guard.EnterAsync(token);
        await RequireOwnerAsync(ownerId, deviceId, profileId, token);
        var normalized = code?.Trim() ?? string.Empty;
        if (normalized.Length != 8 || normalized.Any(character => !char.IsAsciiDigit(character))) throw InvalidCode();
        var hash = tokens.Hash(normalized);
        var request = await database.DeviceAuthorizationRequests.Include(value => value.DeviceSession).ThenInclude(session => session!.User)
            .SingleOrDefaultAsync(value => value.CodeHash == hash, token) ?? throw InvalidCode();
        await ExpireAsync(request, token);
        if (request.State != DeviceAuthorizationState.Pending) throw InvalidCode();
        return await PreviewAsync(request, token);
    }

    public async Task<DeviceAuthorizationPreview> DecideAsync(Guid id, bool approve, Guid ownerId, Guid deviceId, Guid profileId,
        CancellationToken token)
    {
        using var lease = await guard.EnterAsync(token);
        using var mutation = await mutations.EnterAsync(token);
        await using var transaction = await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, token);
        RequireEnabled();
        var owner = await RequireOwnerAsync(ownerId, deviceId, profileId, token);
        var request = await database.DeviceAuthorizationRequests.Include(value => value.DeviceSession).ThenInclude(session => session!.User)
            .SingleOrDefaultAsync(value => value.Id == id, token) ?? throw Missing();
        await ExpireAsync(request, token);
        var desired = approve ? DeviceAuthorizationState.Approved : DeviceAuthorizationState.Denied;
        if (request.State != DeviceAuthorizationState.Pending && request.State != desired)
            throw new AccountException("device_pairing_not_pending", "This device pairing is no longer awaiting approval.", 409);
        if (request.State == DeviceAuthorizationState.Pending)
        {
            if (approve)
            {
                var now = clock.GetUtcNow();
                var rawToken = tokens.CreateDeviceToken();
                var session = new DeviceSession
                {
                    Id = Guid.NewGuid(),
                    UserId = owner.Id,
                    User = owner,
                    DeviceName = request.DeviceName,
                    TokenHash = tokens.Hash(rawToken),
                    CreatedAt = now,
                    LastSeenAt = now,
                    ExpiresAt = now.AddDays(configuration.Current.DeviceSessionDays),
                };
                database.DeviceSessions.Add(session);
                securityLog.Record("signed_in", SecurityLog.Succeeded, owner.Id, session.Id, "Code shown on the device",
                    deviceName: request.DeviceName);
                securityAlerts.Bump();
                request.DeviceSession = session;
                request.DeviceSessionId = session.Id;
                request.ProtectedAuthentication = Protector(id).Protect(JsonSerializer.Serialize(
                    new AuthenticationResponse(ProfileService.ToSummary(owner), session.Id, rawToken, session.ExpiresAt), Json));
            }
            request.State = desired;
            RequireEnabled();
            if (!profiles.IsActive(profileId, deviceId, ownerId))
                throw new AccountException("profile_session_expired", "Unlock the owner profile again before approving a device.", 403);
            await database.SaveChangesAsync(token);
        }
        await transaction.CommitAsync(token);
        return await PreviewAsync(request, token);
    }

    public async Task<DeviceAuthorizationStatusResponse> StatusAsync(Guid id, string secret, string address, CancellationToken token)
    {
        guard.Admit("poll", address);
        using var lease = await guard.EnterAsync(token);
        var request = await AuthenticateAsync(id, secret, token);
        var now = clock.GetUtcNow();
        if (request.LastPolledAt is { } last && now - last < TimeSpan.FromSeconds(PollIntervalSeconds))
            throw new AccountException("device_pairing_slow_down", "Wait at least five seconds before checking this device pairing again.", 429);
        request.LastPolledAt = now;
        await ExpireAsync(request, token);
        await database.SaveChangesAsync(token);
        AuthenticationResponse? authentication = null;
        if (request.State == DeviceAuthorizationState.Approved && request.AcknowledgedAt is null)
        {
            try
            {
                authentication = JsonSerializer.Deserialize<AuthenticationResponse>(
                    Protector(id).Unprotect(request.ProtectedAuthentication ?? throw new CryptographicException()), Json)
                    ?? throw new CryptographicException();
            }
            catch (Exception exception) when (exception is CryptographicException or JsonException)
            {
                await InvalidateAsync(request, DeviceAuthorizationState.Cancelled, token);
                throw new AccountException("device_pairing_unavailable", "The device pairing cannot be completed. Start a new pairing.", 409);
            }
        }
        return new(request.State, request.ExpiresAt, PollIntervalSeconds, authentication, request.AcknowledgedAt is not null);
    }

    public async Task<DeviceAuthorizationStatusResponse> AcknowledgeAsync(Guid id, string secret, string address, CancellationToken token)
    {
        guard.Admit("ack", address);
        using var lease = await guard.EnterAsync(token);
        var request = await AuthenticateAsync(id, secret, token);
        await ExpireAsync(request, token);
        if (request.State != DeviceAuthorizationState.Approved)
            throw new AccountException("device_pairing_not_approved", "This device pairing has not been approved or has expired.", 409);
        request.AcknowledgedAt ??= clock.GetUtcNow();
        request.ProtectedAuthentication = null;
        await database.SaveChangesAsync(token);
        return new(request.State, request.ExpiresAt, PollIntervalSeconds, Acknowledged: true);
    }

    public async Task<DeviceAuthorizationStatusResponse> CancelAsync(Guid id, string secret, string address, CancellationToken token)
    {
        guard.Admit("cancel", address);
        using var lease = await guard.EnterAsync(token);
        var request = await AuthenticateAsync(id, secret, token);
        await ExpireAsync(request, token);
        if (request.AcknowledgedAt is null && request.State is DeviceAuthorizationState.Pending or DeviceAuthorizationState.Approved)
            await InvalidateAsync(request, DeviceAuthorizationState.Cancelled, token);
        return new(request.State, request.ExpiresAt, PollIntervalSeconds, Acknowledged: request.AcknowledgedAt is not null);
    }

    public async Task PruneAsync(CancellationToken token)
    {
        using var lease = await guard.EnterAsync(token);
        var now = clock.GetUtcNow();
        var expired = await database.DeviceAuthorizationRequests.Include(request => request.DeviceSession).ThenInclude(session => session!.User)
            .Where(request => request.ExpiresAt <= now && request.AcknowledgedAt == null
                && (request.State == DeviceAuthorizationState.Pending || request.State == DeviceAuthorizationState.Approved))
            .OrderBy(request => request.ExpiresAt).Take(100).ToListAsync(token);
        foreach (var request in expired) await ExpireAsync(request, token);
        var cutoff = now.AddDays(-1);
        var stale = await database.DeviceAuthorizationRequests.Where(request => request.ExpiresAt < cutoff)
            .OrderBy(request => request.ExpiresAt).Select(request => request.Id).Take(100).ToListAsync(token);
        await database.DeviceAuthorizationRequests.Where(request => stale.Contains(request.Id)).ExecuteDeleteAsync(token);
    }

    private async Task<DeviceAuthorizationRequest> AuthenticateAsync(Guid id, string secret, CancellationToken token)
    {
        if (secret is null || secret.Length is < 32 or > 256) throw Missing();
        var request = await database.DeviceAuthorizationRequests.Include(value => value.DeviceSession).ThenInclude(session => session!.User)
            .SingleOrDefaultAsync(value => value.Id == id, token) ?? throw Missing();
        if (!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(tokens.Hash(secret)), Encoding.ASCII.GetBytes(request.SecretHash)))
            throw Missing();
        return request;
    }

    private async Task ExpireAsync(DeviceAuthorizationRequest request, CancellationToken token)
    {
        if (request.AcknowledgedAt is not null) return;
        if (request.State is DeviceAuthorizationState.Pending or DeviceAuthorizationState.Approved
            && (request.ExpiresAt <= clock.GetUtcNow() || !configuration.Current.PairingEnabled
                || request.State == DeviceAuthorizationState.Approved && (request.DeviceSession is null
                    || request.DeviceSession.RevokedAt is not null || request.DeviceSession.ExpiresAt <= clock.GetUtcNow()
                    || !request.DeviceSession.User.IsEnabled)))
            await InvalidateAsync(request, DeviceAuthorizationState.Expired, token);
    }

    private async Task InvalidateAsync(DeviceAuthorizationRequest request, DeviceAuthorizationState state, CancellationToken token)
    {
        request.State = state;
        request.ProtectedAuthentication = null;
        if (request.DeviceSession is { } session) session.RevokedAt ??= clock.GetUtcNow();
        await database.SaveChangesAsync(token);
    }

    private async Task<ServerUser> RequireOwnerAsync(Guid ownerId, Guid deviceId, Guid profileId, CancellationToken token)
    {
        var now = clock.GetUtcNow();
        if (!profiles.IsActive(profileId, deviceId, ownerId))
            throw new AccountException("profile_session_expired", "Unlock the owner profile again before approving a device.", 403);
        if (!await database.DeviceSessions.AnyAsync(session => session.Id == deviceId && session.RevokedAt == null
            && session.ExpiresAt > now && session.User.IsEnabled, token))
            throw new AccountException("device_session_revoked", "The paired device is no longer authorized.", 403);
        return await database.Users.SingleOrDefaultAsync(user => user.Id == ownerId && user.IsEnabled && user.Role == UserRole.Owner, token)
            ?? throw new AccountException("owner_required", "Only an owner may approve another device.", 403);
    }

    private async Task<DeviceAuthorizationPreview> PreviewAsync(DeviceAuthorizationRequest request, CancellationToken token)
    {
        var serverId = await database.ServerIdentities.Select(identity => identity.ServerId).SingleAsync(token);
        return new(request.Id, request.DeviceName, serverId, configuration.Current.ServerName, request.State, request.ExpiresAt);
    }

    private void RequireEnabled()
    {
        if (!configuration.Current.PairingEnabled)
            throw new AccountException("pairing_disabled", "Device pairing is disabled on this server.", 403);
    }

    private IDataProtector Protector(Guid id) => protection.CreateProtector("Aurelia.DeviceAuthorization.v1", id.ToString("D"));
    private static AccountException InvalidCode() => new("invalid_device_pairing_code", "The device code is invalid or has expired.", 404);
    private static AccountException Missing() => new("device_pairing_not_found", "The device pairing was not found.", 404);
    private static AccountException ManagementLocked() => new("management_locked", "Unlock server management before approving a device.", 403);

    private static JsonSerializerOptions CreateJsonOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }
}
