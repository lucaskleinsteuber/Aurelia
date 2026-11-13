using System.Data;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class AccountService(
    AureliaDbContext database,
    IPasswordHasher<ServerUser> passwordHasher,
    TokenService tokenService,
    ServerConfigurationStore configuration,
    CredentialAttemptGuard credentialAttempts,
    ActiveStreamRegistry streams,
    ProfileSessionStore profiles,
    ProfileService profileService,
    CatalogMutationGate mutations,
    PairingCodeAttemptGuard pairingAttempts,
    IHttpContextAccessor http,
    SecurityLog securityLog,
    SecurityAlertSignal securityAlerts)
{
    private static readonly TimeSpan PairingCodeLifetime = TimeSpan.FromMinutes(5);

    public async Task<AuthenticationResponse> SetupOwnerAsync(
        SetupOwnerRequest request,
        CancellationToken cancellationToken)
    {
        var username = ValidateUsername(request.Username);
        ValidatePassword(request.Password);
        var deviceName = ValidateDeviceName(request.DeviceName);

        await using var transaction = await database.Database.BeginTransactionAsync(
            IsolationLevel.Serializable,
            cancellationToken);

        if (await database.Users.AnyAsync(cancellationToken))
        {
            throw new AccountException(
                "server_already_setup",
                "The first owner has already been created.",
                StatusCodes.Status409Conflict);
        }

        var now = DateTimeOffset.UtcNow;
        var user = new ServerUser
        {
            Id = Guid.NewGuid(),
            Username = username,
            NormalizedUsername = NormalizeUsername(username),
            PasswordHash = string.Empty,
            Role = UserRole.Owner,
            CreatedAt = now,
        };
        using (await credentialAttempts.EnterAsync(cancellationToken)) user.PasswordHash = passwordHasher.HashPassword(user, request.Password);
        database.Users.Add(user);

        var response = CreateSession(user, deviceName, now, acknowledged: true);
        await database.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        RecordSignIn(response, deviceName, "Set up the server");
        return response;
    }

    public async Task<AuthenticationResponse> LoginAsync(
        LoginRequest request,
        CancellationToken cancellationToken)
    {
        var normalizedUsername = NormalizeUsername(ValidateUsername(request.Username));
        if (request.Password is null || request.Password.Length is < 1 or > 1024)
            throw new AccountException("invalid_credentials", "The owner profile name or Server Password is incorrect.", 401);
        var deviceName = ValidateDeviceName(request.DeviceName);
        var user = await database.Users.SingleOrDefaultAsync(
            candidate => candidate.NormalizedUsername == normalizedUsername,
            cancellationToken);

        if (user?.Role != UserRole.Owner) await VerifyPasswordAsync(null, request.Password, cancellationToken);
        if (await database.AdministrationCredentials.AnyAsync(cancellationToken))
            await profileService.VerifyManagementAsync(user!.Id, request.Password, cancellationToken);
        else await VerifyPasswordAsync(user, request.Password, cancellationToken);

        await RefuseBlockedAsync(cancellationToken);
        var response = CreateSession(user!, deviceName, DateTimeOffset.UtcNow);
        await database.SaveChangesAsync(cancellationToken);
        RecordSignIn(response, deviceName, "Server Password");
        return response;
    }

    public async Task<IReadOnlyList<UserSummary>> ListUsersAsync(CancellationToken cancellationToken)
    {
        return await database.Users
            .AsNoTracking()
            .OrderBy(user => user.Username)
            .Select(user => ToSummary(user))
            .ToListAsync(cancellationToken);
    }

    public async Task<UserSummary> GetUserAsync(Guid userId, CancellationToken cancellationToken)
    {
        return ToSummary(await RequireUserAsync(userId, cancellationToken));
    }

    public Task<UserSummary> CreateUserAsync(
        Guid actorId,
        CreateUserRequest request,
        CancellationToken cancellationToken)
    {
        return profileService.CreateAsync(actorId, request, cancellationToken);
    }

    public Task<UserSummary> ChangeRoleAsync(
        Guid actorId,
        Guid targetId,
        UserRole newRole,
        CancellationToken cancellationToken)
    {
        return profileService.ChangeRoleAsync(actorId, targetId, newRole, cancellationToken);
    }

    public async Task DeleteUserAsync(
        Guid actorId,
        Guid targetId,
        CancellationToken cancellationToken)
    {
        using var lease = await mutations.EnterAsync(cancellationToken);
        await using var transaction = await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, cancellationToken);
        var actor = await RequireUserAsync(actorId, cancellationToken);
        var target = await RequireUserAsync(targetId, cancellationToken);

        if (actorId == targetId)
        {
            throw new AccountException(
                "cannot_delete_current_user",
                "The current account cannot delete itself.",
                StatusCodes.Status409Conflict);
        }

        if (actor.Role != UserRole.Owner)
        {
            throw Forbidden();
        }

        if (target.Role == UserRole.Owner)
        {
            var ownerCount = await database.Users.CountAsync(
                user => user.Role == UserRole.Owner && user.IsEnabled,
                cancellationToken);
            if (target.IsEnabled && ownerCount == 1)
            {
                throw new AccountException(
                    "last_owner_required",
                    "The final owner cannot be deleted.",
                    StatusCodes.Status409Conflict);
            }
        }

        // A viewing profile can use a device paired by another owner. Such tickets
        // do not cascade through the target's devices, and their user FK is NoAction.
        await database.PlaybackTickets.IgnoreQueryFilters()
            .Where(ticket => ticket.UserId == targetId)
            .ExecuteDeleteAsync(cancellationToken);
        database.Users.Remove(target);
        await database.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        streams.RevokeUser(targetId);
        profiles.RevokeUser(targetId);
    }

    public async Task<PairingCodeResponse> CreatePairingCodeAsync(
        Guid userId,
        CancellationToken cancellationToken)
    {
        var user = await RequireUserAsync(userId, cancellationToken);
        if (!configuration.Current.PairingEnabled || !user.IsEnabled || user.Role != UserRole.Owner) throw Forbidden();
        var now = DateTimeOffset.UtcNow;

        var activeCodes = await database.PairingCodes
            .Where(code => code.UserId == userId && code.ConsumedAt == null)
            .ToListAsync(cancellationToken);
        foreach (var activeCode in activeCodes)
        {
            activeCode.ConsumedAt = now;
        }

        var rawCode = tokenService.CreatePairingCode();
        var expiresAt = now.Add(PairingCodeLifetime);
        database.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(),
            User = user,
            UserId = user.Id,
            CodeHash = tokenService.Hash(rawCode),
            CreatedAt = now,
            ExpiresAt = expiresAt,
        });
        await database.SaveChangesAsync(cancellationToken);
        pairingAttempts.CodeCreated();
        return new PairingCodeResponse(rawCode, expiresAt);
    }

    public async Task<AuthenticationResponse> RedeemPairingCodeAsync(
        RedeemPairingCodeRequest request,
        CancellationToken cancellationToken)
    {
        var deviceName = ValidateDeviceName(request.DeviceName);
        if (!configuration.Current.PairingEnabled) throw Forbidden();
        var normalizedCode = request.Code?.Trim() ?? string.Empty;
        if (normalizedCode.Length != 8 || normalizedCode.Any(character => !char.IsAsciiDigit(character)))
        {
            throw InvalidPairingCode();
        }

        await using var transaction = await database.Database.BeginTransactionAsync(
            IsolationLevel.Serializable,
            cancellationToken);
        var now = DateTimeOffset.UtcNow;
        var codeHash = tokenService.Hash(normalizedCode);
        var code = await database.PairingCodes
            .Include(candidate => candidate.User)
            .SingleOrDefaultAsync(candidate => candidate.CodeHash == codeHash, cancellationToken);

        if (code is null || code.ConsumedAt is not null || code.ExpiresAt <= now || !code.User.IsEnabled || code.User.Role != UserRole.Owner)
        {
            // Too many wrong guesses, from however many addresses, end every waiting code.
            if (pairingAttempts.RecordFailure())
            {
                var waiting = await database.PairingCodes.Where(candidate => candidate.ConsumedAt == null).ToListAsync(cancellationToken);
                foreach (var candidate in waiting) candidate.ConsumedAt = now;
                await database.SaveChangesAsync(cancellationToken);
                await transaction.CommitAsync(cancellationToken);
            }

            throw InvalidPairingCode();
        }

        await RefuseBlockedAsync(cancellationToken);
        code.ConsumedAt = now;
        var response = CreateSession(code.User, deviceName, now);
        await database.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        RecordSignIn(response, deviceName, "Device code");
        return response;
    }

    public async Task<IReadOnlyList<DeviceSessionSummary>> ListSessionsAsync(
        Guid userId,
        Guid currentSessionId,
        CancellationToken cancellationToken)
    {
        return await database.DeviceSessions
            .AsNoTracking()
            .Where(session => session.UserId == userId)
            .OrderByDescending(session => session.LastSeenAt)
            .Select(session => new DeviceSessionSummary(
                session.Id,
                session.UserId,
                session.DeviceName,
                session.CreatedAt,
                session.LastSeenAt,
                session.ExpiresAt,
                session.RevokedAt,
                session.Id == currentSessionId))
            .ToListAsync(cancellationToken);
    }

    public async Task RevokeSessionAsync(
        Guid actorId,
        Guid currentSessionId,
        Guid targetSessionId,
        CancellationToken cancellationToken)
    {
        var actor = await RequireUserAsync(actorId, cancellationToken);
        var target = await database.DeviceSessions
            .Include(session => session.User)
            .SingleOrDefaultAsync(session => session.Id == targetSessionId, cancellationToken)
            ?? throw NotFound("session_not_found", "The device session was not found.");

        if (target.UserId != actorId && actor.Role != UserRole.Owner)
        {
            throw Forbidden();
        }

        if (target.User.Role == UserRole.Owner && actor.Role == UserRole.Admin)
        {
            throw Forbidden();
        }

        target.RevokedAt ??= DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
        streams.RevokeSession(targetSessionId);
        profiles.RevokeDevice(targetSessionId);
    }

    /// <summary>A device on the owner's block list may not sign in or pair again.</summary>
    private async Task RefuseBlockedAsync(CancellationToken cancellationToken)
    {
        if (ClientIdentity.From(http.HttpContext).InstallationId is { } installation
            && await database.BlockedDevices.AnyAsync(blocked => blocked.InstallationId == installation, cancellationToken))
            throw DeviceBlocked();
    }

    public static AccountException DeviceBlocked() =>
        new("device_blocked", "The owner blocked this device. Ask them to unblock it in Settings › Profiles and Devices › Security.", 403);

    private void RecordSignIn(AuthenticationResponse response, string deviceName, string how)
    {
        securityLog.Record("signed_in", SecurityLog.Succeeded, response.User.Id, response.SessionId, how,
            ClientIdentity.From(http.HttpContext), deviceName);
        securityAlerts.Bump();
    }

    private AuthenticationResponse CreateSession(
        ServerUser user,
        string deviceName,
        DateTimeOffset now,
        bool acknowledged = false)
    {
        var rawToken = tokenService.CreateDeviceToken();
        var identity = ClientIdentity.From(http.HttpContext);
        var session = new DeviceSession
        {
            Id = Guid.NewGuid(),
            User = user,
            UserId = user.Id,
            DeviceName = deviceName,
            TokenHash = tokenService.Hash(rawToken),
            CreatedAt = now,
            LastSeenAt = now,
            ExpiresAt = now.AddDays(configuration.Current.DeviceSessionDays),
            InstallationId = identity.InstallationId,
            Platform = identity.Platform,
            ClientVersion = identity.Version,
            FirstIpAddress = identity.IpAddress,
            LastIpAddress = identity.IpAddress,
            // The very first device, which set the server up, is the owner's own.
            AcknowledgedAt = acknowledged ? now : null,
        };
        database.DeviceSessions.Add(session);
        return new AuthenticationResponse(
            ToSummary(user),
            session.Id,
            rawToken,
            session.ExpiresAt);
    }

    public async Task RevokeOwnDeviceAsync(Guid deviceId, CancellationToken token)
    {
        var device = await database.DeviceSessions.SingleOrDefaultAsync(device => device.Id == deviceId, token)
            ?? throw NotFound("session_not_found", "The paired device was not found.");
        device.RevokedAt ??= DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(token);
        profiles.RevokeDevice(deviceId);
    }

    private async Task<ServerUser> RequireUserAsync(
        Guid id,
        CancellationToken cancellationToken)
    {
        return await database.Users.SingleOrDefaultAsync(user => user.Id == id, cancellationToken)
            ?? throw NotFound("user_not_found", "The user was not found.");
    }

    public async Task ConfirmPasswordAsync(Guid userId, string password, CancellationToken cancellationToken)
    {
        await profileService.VerifyManagementAsync(userId, password, cancellationToken);
    }

    private async Task VerifyPasswordAsync(ServerUser? user, string password, CancellationToken cancellationToken)
    {
        if (password is null || password.Length is < 1 or > 1024)
            throw new AccountException("invalid_credentials", "The owner profile name or Server Password is incorrect.", 401);
        var now = DateTimeOffset.UtcNow;
        var key = user?.Id ?? Guid.Empty;
        credentialAttempts.Check(key, now);
        using var work = await credentialAttempts.EnterAsync(cancellationToken);
        // Unknown accounts still do password work; no fast username-existence oracle.
        var result = PasswordVerificationResult.Failed;
        if (user is null)
            _ = passwordHasher.HashPassword(new ServerUser { Username = "unknown", NormalizedUsername = "UNKNOWN", PasswordHash = "" }, password);
        else result = passwordHasher.VerifyHashedPassword(user, user.PasswordHash, password);
        var success = user?.IsEnabled == true && result != PasswordVerificationResult.Failed;
        credentialAttempts.Record(key, success, now);
        if (!success) throw new AccountException("invalid_credentials", "The owner profile name or Server Password is incorrect.", 401);
        if (result == PasswordVerificationResult.SuccessRehashNeeded)
            user!.PasswordHash = passwordHasher.HashPassword(user, password);
    }

    public async Task<IReadOnlyList<UserAccessSummary>> ListAccessAsync(CancellationToken cancellationToken)
    {
        return await database.Users.AsNoTracking().Include(user => user.LibraryGrants).OrderBy(user => user.Username)
            .Select(user => new UserAccessSummary(ToSummary(user), user.IsEnabled,
                user.LibraryGrants.Select(grant => grant.LibraryRootId).ToList())).ToListAsync(cancellationToken);
    }

    public async Task UpdateAccessAsync(Guid actorId, Guid targetId, UpdateUserAccessRequest request, CancellationToken cancellationToken)
    {
        using var lease = await mutations.EnterAsync(cancellationToken);
        await using var transaction = await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, cancellationToken);
        var actor = await RequireUserAsync(actorId, cancellationToken);
        if (actor.Role != UserRole.Owner) throw Forbidden();
        var target = await database.Users.Include(user => user.LibraryGrants).SingleOrDefaultAsync(user => user.Id == targetId, cancellationToken)
            ?? throw NotFound("user_not_found", "The user was not found.");
        if (target.Role == UserRole.Owner && target.IsEnabled && !request.IsEnabled
            && await database.Users.CountAsync(user => user.Role == UserRole.Owner && user.IsEnabled, cancellationToken) <= 1)
            throw new AccountException("last_owner_required", "The final active owner cannot be disabled.", 409);
        if (request.LibraryIds is null || request.LibraryIds.Count > 1_000) throw new AccountException("invalid_libraries", "Invalid library grants.", 400);
        var ids = request.LibraryIds.Distinct().ToArray();
        if (await database.LibraryRoots.CountAsync(root => ids.Contains(root.Id), cancellationToken) != ids.Length)
            throw new AccountException("invalid_libraries", "A selected library does not exist.", 400);
        database.UserLibraryGrants.RemoveRange(target.LibraryGrants.Where(grant => !ids.Contains(grant.LibraryRootId)));
        var old = target.LibraryGrants.Select(grant => grant.LibraryRootId).ToHashSet();
        database.UserLibraryGrants.AddRange(ids.Where(id => !old.Contains(id)).Select(id => new UserLibraryGrant { UserId = targetId, LibraryRootId = id }));
        target.IsEnabled = request.IsEnabled;
        target.AccessMode = ProfileAccessMode.LegacyLibraries;
        target.AccessRevision++;
        database.SyncChanges.Add(new SyncChange { Area = SyncChangeArea.Catalog, UserId = targetId, CreatedAt = DateTimeOffset.UtcNow });
        if (!target.IsEnabled)
        {
            var sessions = await database.DeviceSessions.Where(session => session.UserId == targetId && session.RevokedAt == null).ToListAsync(cancellationToken);
            foreach (var session in sessions) session.RevokedAt = DateTimeOffset.UtcNow;
            var codes = await database.PairingCodes.Where(code => code.UserId == targetId && code.ConsumedAt == null).ToListAsync(cancellationToken);
            foreach (var code in codes) code.ConsumedAt = DateTimeOffset.UtcNow;
        }
        await database.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        streams.RevokeUser(targetId);
        if (!target.IsEnabled) profiles.RevokeUser(targetId);
    }

    public async Task ResetPasswordAsync(Guid actorId, Guid targetId, string password, CancellationToken cancellationToken)
    {
        await Task.CompletedTask;
        throw new AccountException("profile_pin_required", "Profiles use optional PIN protection, not account passwords. Manage the profile PIN instead.", 409);
    }

    public async Task RevokeAllSessionsAsync(Guid actorId, Guid targetId, CancellationToken cancellationToken)
    {
        await using var transaction = await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, cancellationToken);
        if (actorId != targetId && (await RequireUserAsync(actorId, cancellationToken)).Role != UserRole.Owner) throw Forbidden();
        var sessions = await database.DeviceSessions.Where(session => session.UserId == targetId && session.RevokedAt == null).ToListAsync(cancellationToken);
        foreach (var session in sessions) session.RevokedAt = DateTimeOffset.UtcNow;
        var codes = await database.PairingCodes.Where(code => code.UserId == targetId && code.ConsumedAt == null).ToListAsync(cancellationToken);
        foreach (var code in codes) code.ConsumedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        streams.RevokeUser(targetId);
        profiles.RevokeUser(targetId);
        foreach (var session in sessions) profiles.RevokeDevice(session.Id);
    }

    private static UserSummary ToSummary(ServerUser user)
    {
        return ProfileService.ToSummary(user);
    }

    private static string ValidateUsername(string? value)
    {
        var username = (value ?? string.Empty).Trim().Normalize(NormalizationForm.FormKC);
        if (username.Length is < 3 or > 64 || username.Any(char.IsControl))
        {
            throw new AccountException(
                "invalid_username",
                "The username must contain 3 to 64 visible characters.",
                StatusCodes.Status400BadRequest);
        }

        return username;
    }

    private static string NormalizeUsername(string? value)
    {
        return (value ?? string.Empty)
            .Trim()
            .Normalize(NormalizationForm.FormKC)
            .ToUpperInvariant();
    }

    private static void ValidatePassword(string? value)
    {
        if (value is null || value.Length is < 12 or > 1024)
        {
            throw new AccountException(
                "invalid_password",
                "The Server Password must contain at least 12 characters.",
                StatusCodes.Status400BadRequest);
        }
    }

    private static string ValidateDeviceName(string? value)
    {
        var deviceName = (value ?? string.Empty).Trim().Normalize(NormalizationForm.FormKC);
        if (deviceName.Length is < 1 or > 128 || deviceName.Any(char.IsControl))
        {
            throw new AccountException(
                "invalid_device_name",
                "The device name must contain 1 to 128 visible characters.",
                StatusCodes.Status400BadRequest);
        }

        return deviceName;
    }

    private static AccountException InvalidPairingCode()
    {
        return new AccountException(
            "invalid_pairing_code",
            "The pairing code is invalid or has expired.",
            StatusCodes.Status401Unauthorized);
    }

    private static AccountException Forbidden()
    {
        return new AccountException(
            "forbidden",
            "This account does not have permission for that action.",
            StatusCodes.Status403Forbidden);
    }

    private static AccountException NotFound(string code, string message)
    {
        return new AccountException(code, message, StatusCodes.Status404NotFound);
    }
}
