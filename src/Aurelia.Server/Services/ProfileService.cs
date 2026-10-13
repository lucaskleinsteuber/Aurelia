using System.Data;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class ProfileService(AureliaDbContext database, IPasswordHasher<ServerUser> hasher,
    CredentialAttemptGuard passwords, ProfilePinAttemptGuard pins, ProfileSessionStore sessions,
    CatalogMutationGate mutations, ActiveStreamRegistry streams)
{
    public async Task<ProfilePickerResponse> PickerAsync(CancellationToken token) => new(1, "1.5.0",
        !await database.AdministrationCredentials.AnyAsync(token),
        await database.Users.AsNoTracking().Where(user => user.IsEnabled).OrderBy(user => user.Username)
            .Select(user => new WatchingProfile(user.Id, user.Username, user.Role, user.PinHash == null)).ToListAsync(token));

    public async Task InitializeAsync(Guid deviceId, InitializeProfilesRequest request, CancellationToken token)
    {
        ValidatePin(request.Pin);
        using var lease = await mutations.EnterAsync(token);
        await using var transaction = await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, token);
        if (await database.AdministrationCredentials.AnyAsync(token))
            throw new AccountException("profiles_already_initialized", "Profile setup has already been completed.", 409);
        var owner = await database.DeviceSessions.Where(device => device.Id == deviceId && device.RevokedAt == null)
            .Select(device => device.User).SingleAsync(token);
        if (owner.Role != UserRole.Owner || !owner.IsEnabled) throw Forbidden();
        await VerifyAsync(owner, owner.PasswordHash, request.Password, token);
        // Preserve the confirmed credential's hash; it is no longer a viewing password.
        database.AdministrationCredentials.Add(new ServerAdministrationCredential { PasswordHash = owner.PasswordHash });
        owner.PinHash = await HashPinAsync(owner, request.Pin, token);
        owner.AccessMode = ProfileAccessMode.EntireLibrary;
        await database.SaveChangesAsync(token);
        await transaction.CommitAsync(token);
    }

    public async Task<ProfileSessionResponse> UnlockAsync(Guid deviceId, Guid userId, string pin, CancellationToken token)
    {
        if (!await database.AdministrationCredentials.AnyAsync(token))
            throw new AccountException("profile_setup_required", "The owner must finish profile setup first.", 409);
        // Keep verification and session issuance ordered with PIN resets. A reset
        // must not retire sessions just before an old, in-flight PIN creates one.
        using var lease = await mutations.EnterAsync(token);
        pins.Check(deviceId, userId);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId && user.IsEnabled, token);
        var validInput = IsPin(pin);
        using (await passwords.EnterAsync(token))
        {
            var result = user?.PinHash is { } hash && validInput
                ? hasher.VerifyHashedPassword(user, hash, pin) : PasswordVerificationResult.Failed;
            if (user?.PinHash is null || !validInput)
                _ = hasher.HashPassword(user ?? new ServerUser { Username = "unknown", NormalizedUsername = "UNKNOWN", PasswordHash = "" }, "invalid-pin-input");
            var success = result != PasswordVerificationResult.Failed;
            pins.Record(deviceId, userId, success);
            if (!success) throw new AccountException("invalid_profile_pin", "The PIN is incorrect or this profile still needs PIN setup.", 401);
            if (result == PasswordVerificationResult.SuccessRehashNeeded) user!.PinHash = hasher.HashPassword(user!, pin);
        }
        await database.SaveChangesAsync(token);
        var issued = sessions.Issue(deviceId, userId);
        return new(new UserSummary(user!.Id, user.Username, user.Role, user.CreatedAt, user.AccessMode), issued.Session.Id, issued.Token, issued.Session.ExpiresAt);
    }

    public async Task ChangePinAsync(Guid deviceId, Guid userId, ChangeProfilePinRequest request, CancellationToken token)
    {
        ValidatePin(request.NewPin);
        pins.Check(deviceId, userId);
        using var lease = await mutations.EnterAsync(token);
        var user = await database.Users.SingleAsync(user => user.Id == userId, token);
        bool valid;
        using (await passwords.EnterAsync(token))
            valid = IsPin(request.CurrentPin) && user.PinHash is { } hash && hasher.VerifyHashedPassword(user, hash, request.CurrentPin) != PasswordVerificationResult.Failed;
        pins.Record(deviceId, userId, valid);
        if (!valid) throw new AccountException("invalid_profile_pin", "The current PIN is incorrect.", 401);
        user.PinHash = await HashPinAsync(user, request.NewPin, token);
        await database.SaveChangesAsync(token);
        sessions.RevokeUser(userId);
    }

    public async Task ResetPinAsync(Guid actorId, Guid userId, string pin, CancellationToken token)
    {
        ValidatePin(pin);
        if (!await database.Users.AnyAsync(user => user.Id == actorId && user.Role == UserRole.Owner && user.IsEnabled, token)) throw Forbidden();
        using var lease = await mutations.EnterAsync(token);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        user.PinHash = await HashPinAsync(user, pin, token);
        await database.SaveChangesAsync(token);
        sessions.RevokeUser(userId);
    }

    public async Task VerifyManagementAsync(Guid userId, string password, CancellationToken token)
    {
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId && user.IsEnabled, token);
        if (user?.Role is not (UserRole.Owner or UserRole.Admin)) throw Forbidden();
        var credential = await database.AdministrationCredentials.SingleOrDefaultAsync(token)
            ?? throw new AccountException("profile_setup_required", "The owner must finish profile setup first.", 409);
        await VerifyAsync(user, credential.PasswordHash, password, token);
    }

    public async Task<ProfileTitleAccessResponse> AccessAsync(Guid userId, CancellationToken token)
    {
        var user = await database.Users.AsNoTracking().SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        return new(user.AccessMode, await database.UserTitleGrants.Where(grant => grant.UserId == userId).Select(grant => grant.MediaItemId).ToListAsync(token), user.AccessRevision);
    }

    public async Task SetEnabledAsync(Guid actorId, Guid userId, bool enabled, CancellationToken token)
    {
        if (!await database.Users.AnyAsync(user => user.Id == actorId && user.Role == UserRole.Owner && user.IsEnabled, token)) throw Forbidden();
        using var lease = await mutations.EnterAsync(token);
        await using var transaction = await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, token);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        if (!enabled && user.IsEnabled && user.Role == UserRole.Owner && await database.Users.CountAsync(user => user.Role == UserRole.Owner && user.IsEnabled, token) <= 1)
            throw new AccountException("last_owner_required", "The final active owner cannot be disabled.", 409);
        user.IsEnabled = enabled;
        database.SyncChanges.Add(new SyncChange { UserId = userId, Area = SyncChangeArea.Catalog, CreatedAt = DateTimeOffset.UtcNow });
        await database.SaveChangesAsync(token);
        await transaction.CommitAsync(token);
        if (!enabled) sessions.RevokeUser(userId);
        streams.RevokeUser(userId);
    }

    public async Task<ProfileTitleAccessResponse> UpdateAccessAsync(Guid actorId, Guid userId, UpdateProfileTitleAccessRequest request, CancellationToken token)
    {
        if (request.Mode is not (ProfileAccessMode.EntireLibrary or ProfileAccessMode.SelectedTitles) || request.TitleIds is null || request.TitleIds.Count > 10000)
            throw new AccountException("invalid_title_access", "Choose the entire library or explicit films and series.", 400);
        if (!await database.Users.AnyAsync(user => user.Id == actorId && user.Role == UserRole.Owner && user.IsEnabled, token)) throw Forbidden();
        using var lease = await mutations.EnterAsync(token);
        await using var transaction = await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, token);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        if (user.AccessRevision != request.Revision) throw new AccountException("profile_access_conflict", "Profile access changed on another device. Reload before saving.", 409);
        if (user.Role == UserRole.Owner && request.Mode != ProfileAccessMode.EntireLibrary) throw Forbidden();
        var ids = request.Mode == ProfileAccessMode.SelectedTitles ? request.TitleIds.Distinct().ToArray() : [];
        if (await database.MediaItems.CountAsync(item => ids.Contains(item.Id) && item.ParentId == null && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series), token) != ids.Length)
            throw new AccountException("invalid_title_access", "A selected film or series does not exist.", 400);
        database.UserTitleGrants.RemoveRange(await database.UserTitleGrants.Where(grant => grant.UserId == userId).ToListAsync(token));
        database.UserTitleGrants.AddRange(ids.Select(id => new UserTitleGrant { UserId = userId, MediaItemId = id }));
        user.AccessMode = request.Mode;
        user.AccessRevision++;
        database.SyncChanges.Add(new SyncChange { UserId = userId, Area = SyncChangeArea.Catalog, CreatedAt = DateTimeOffset.UtcNow });
        await database.SaveChangesAsync(token);
        await transaction.CommitAsync(token);
        streams.RevokeUser(userId);
        return new(user.AccessMode, ids, user.AccessRevision);
    }

    public static bool IsPin(string? value) => value is { Length: >= 4 and <= 8 } && value.All(char.IsAsciiDigit);
    private static void ValidatePin(string? pin)
    { if (!IsPin(pin)) throw new AccountException("invalid_pin_format", "Use a numeric PIN with 4 to 8 digits.", 400); }
    private async Task<string> HashPinAsync(ServerUser user, string pin, CancellationToken token)
    { using (await passwords.EnterAsync(token)) return hasher.HashPassword(user, pin); }
    private async Task VerifyAsync(ServerUser user, string hash, string password, CancellationToken token)
    {
        if (password is null || password.Length is < 1 or > 1024) throw new AccountException("invalid_credentials", "The server management password is incorrect.", 401);
        passwords.Check(user.Id, DateTimeOffset.UtcNow);
        using var slot = await passwords.EnterAsync(token);
        var valid = hasher.VerifyHashedPassword(user, hash, password) != PasswordVerificationResult.Failed;
        passwords.Record(user.Id, valid, DateTimeOffset.UtcNow);
        if (!valid) throw new AccountException("invalid_credentials", "The server management password is incorrect.", 401);
    }
    private static AccountException Forbidden() => new("forbidden", "This profile cannot perform that action.", 403);
}
