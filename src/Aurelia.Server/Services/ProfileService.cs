using System.Data;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class ProfileService(AureliaDbContext database, IPasswordHasher<ServerUser> hasher,
    CredentialAttemptGuard passwords, ProfilePinAttemptGuard pins, ProfileSessionStore sessions,
    CatalogMutationGate mutations, ActiveStreamRegistry streams, ScreenTimeService? screenTime = null)
{
    public async Task<ProfilePickerResponse> PickerAsync(CancellationToken token)
    {
        var profiles = await database.Users.AsNoTracking().Where(user => user.IsEnabled)
            .Select(user => new WatchingProfile(user.Id, user.DisplayName ?? user.Username, user.Role,
                user.PinProtectionEnabled && user.PinHash == null, user.PinProtectionEnabled, user.PictureKey, user.PictureRevision,
                user.Role == UserRole.User ? user.AgeLimit : null, null)).ToListAsync(token);
        if (screenTime is not null)
            for (var index = 0; index < profiles.Count; index++)
                if (profiles[index].Role == UserRole.User && await screenTime.ProfileClosedUntilAsync(profiles[index].Id, token) is { } until)
                    profiles[index] = profiles[index] with { ClosedUntil = until };
        return new(2, "1.5.1", !await database.AdministrationCredentials.AnyAsync(token),
            profiles.OrderBy(profile => profile.Name, StringComparer.CurrentCultureIgnoreCase).ToList());
    }

    /// <summary>A whole-profile screen time lock keeps a children's profile closed until its wake time.</summary>
    private async Task RequireOpenAsync(Guid userId, CancellationToken token)
    {
        if (screenTime is not null && await screenTime.ProfileClosedUntilAsync(userId, token) is { } until)
            throw new AccountException(ScreenTimeCodes.ProfileClosed,
                $"Good night! This profile opens again at {screenTime.LocalClock(until)}.", 403);
    }

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
        await VerifyAsync(owner, owner.PasswordHash, request.Password, token, deviceId);
        // Preserve the confirmed credential's hash; it is no longer a viewing password.
        database.AdministrationCredentials.Add(new ServerAdministrationCredential { PasswordHash = owner.PasswordHash });
        owner.PinHash = await HashPinAsync(owner, request.Pin, token);
        owner.PinProtectionEnabled = true;
        owner.AccessMode = ProfileAccessMode.EntireLibrary;
        await database.SaveChangesAsync(token);
        await transaction.CommitAsync(token);
    }

    public async Task<ProfileSessionResponse> UnlockAsync(Guid deviceId, Guid userId, string? pin, CancellationToken token)
    {
        if (!await database.AdministrationCredentials.AnyAsync(token))
            throw new AccountException("profile_setup_required", "The owner must finish profile setup first.", 409);
        // Keep verification and session issuance ordered with PIN resets. A reset
        // must not retire sessions just before an old, in-flight PIN creates one.
        using var lease = await mutations.EnterAsync(token);
        pins.Check(deviceId, userId);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId && user.IsEnabled, token);
        if (user is { Role: UserRole.User }) await RequireOpenAsync(user.Id, token);
        if (user is { Role: UserRole.User, PinProtectionEnabled: false })
        {
            // Even an unprotected profile receives a volatile, user-bound session.
            // A paired device token itself never becomes a viewing credential.
            pins.Record(deviceId, userId, true);
            var unprotected = sessions.Issue(deviceId, userId);
            return new(ToSummary(user), unprotected.Session.Id, unprotected.Token, unprotected.Session.ExpiresAt);
        }
        var validInput = IsPin(pin);
        using (await passwords.EnterAsync(token))
        {
            var result = user?.PinHash is { } hash && validInput
                ? hasher.VerifyHashedPassword(user, hash, pin!) : PasswordVerificationResult.Failed;
            if (user?.PinHash is null || !validInput)
                _ = hasher.HashPassword(user ?? new ServerUser { Username = "unknown", NormalizedUsername = "UNKNOWN", PasswordHash = "" }, "invalid-pin-input");
            var success = result != PasswordVerificationResult.Failed;
            pins.Record(deviceId, userId, success);
            if (!success) throw new AccountException("invalid_profile_pin", "The PIN is incorrect or this profile still needs PIN setup.", 401);
            if (result == PasswordVerificationResult.SuccessRehashNeeded) user!.PinHash = hasher.HashPassword(user!, pin!);
        }
        await database.SaveChangesAsync(token);
        var issued = sessions.Issue(deviceId, userId);
        return new(ToSummary(user!), issued.Session.Id, issued.Token, issued.Session.ExpiresAt);
    }

    public async Task ChangePinAsync(Guid deviceId, Guid userId, ChangeProfilePinRequest request, CancellationToken token)
    {
        await SetOwnPinProtectionAsync(deviceId, userId,
            new UpdateOwnPinProtectionRequest(true, request.CurrentPin, request.NewPin), token);
    }

    public async Task SetOwnPinProtectionAsync(Guid deviceId, Guid userId, UpdateOwnPinProtectionRequest request, CancellationToken token)
    {
        using var lease = await mutations.EnterAsync(token);
        var user = await database.Users.SingleAsync(user => user.Id == userId, token);
        if (!request.PinProtectionEnabled && user.Role != UserRole.User)
            throw new AccountException("pin_required_for_role", "Owner and Admin profiles must use a PIN.", 400);
        if (request.PinProtectionEnabled) ValidatePin(request.Pin);
        if (user.PinProtectionEnabled)
        {
            pins.Check(deviceId, userId);
            bool valid;
            using (await passwords.EnterAsync(token))
                valid = IsPin(request.CurrentPin) && user.PinHash is { } hash
                    && hasher.VerifyHashedPassword(user, hash, request.CurrentPin!) != PasswordVerificationResult.Failed;
            pins.Record(deviceId, userId, valid);
            if (!valid) throw new AccountException("invalid_profile_pin", "The current PIN is incorrect.", 401);
        }
        user.PinProtectionEnabled = request.PinProtectionEnabled;
        user.PinHash = request.PinProtectionEnabled ? await HashPinAsync(user, request.Pin!, token) : null;
        await database.SaveChangesAsync(token);
        sessions.RevokeUser(userId);
        streams.RevokeUser(userId);
    }

    public async Task ResetPinAsync(Guid actorId, Guid userId, string pin, CancellationToken token)
    {
        ValidatePin(pin);
        using var lease = await mutations.EnterAsync(token);
        await RequireOwnerAsync(actorId, token);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        user.PinHash = await HashPinAsync(user, pin, token);
        user.PinProtectionEnabled = true;
        await database.SaveChangesAsync(token);
        sessions.RevokeUser(userId);
    }

    /// <param name="deviceSessionId">
    /// The paired device asking, if any. Its failed attempts count on their own, so wrong
    /// passwords sent to the sign-in by anyone on the network cannot lock an owner's paired
    /// devices out of server management.
    /// </param>
    public async Task VerifyManagementAsync(Guid userId, string password, CancellationToken token, Guid? deviceSessionId = null)
    {
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId && user.IsEnabled, token);
        if (user?.Role is not (UserRole.Owner or UserRole.Admin)) throw Forbidden();
        var credential = await database.AdministrationCredentials.SingleOrDefaultAsync(token)
            ?? throw new AccountException("profile_setup_required", "The owner must finish profile setup first.", 409);
        await VerifyAsync(user, credential.PasswordHash, password, token, deviceSessionId);
    }

    public async Task<ProfileTitleAccessResponse> AccessAsync(Guid userId, CancellationToken token)
    {
        var user = await database.Users.AsNoTracking().SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        return new(user.AccessMode, await database.UserTitleGrants.Where(grant => grant.UserId == userId).Select(grant => grant.MediaItemId).ToListAsync(token), user.AccessRevision);
    }

    public async Task<ProfileEditorResponse> EditorAsync(Guid userId, CancellationToken token)
    {
        using var lease = await mutations.EnterAsync(token);
        var user = await database.Users.AsNoTracking().SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        var access = await AccessAsync(userId, token);
        return new(ToSummary(user), user.IsEnabled, access, user.ProfileRevision);
    }

    public async Task<UserSummary> CreateAsync(Guid actorId, CreateUserRequest request, CancellationToken token)
    {
        var name = (request.Username ?? "").Trim().Normalize(NormalizationForm.FormKC);
        // Only the owner signs in with a name (set up elsewhere); a profile name just has to be visible.
        if (name.Length is < 1 or > 64 || name.Any(char.IsControl))
            throw new AccountException("invalid_username", "The profile name must contain 1 to 64 visible characters.", 400);
        if (!Enum.IsDefined(request.Role)) throw new AccountException("invalid_role", "Choose a valid profile role.", 400);
        var protection = request.PinProtectionEnabled ?? (request.Role != UserRole.User || request.Pin is not null);
        if (request.Role != UserRole.User && !protection)
            throw new AccountException("pin_required_for_role", "Owner and Admin profiles must use a PIN.", 400);
        if (protection) ValidatePin(request.Pin);
        else if (request.Pin is not null) throw new AccountException("invalid_pin_format", "Do not send a PIN for an unprotected profile.", 400);
        var mode = request.AccessMode ?? (request.Role == UserRole.Owner ? ProfileAccessMode.EntireLibrary : ProfileAccessMode.SelectedTitles);
        ValidateAgeLimit(request.AgeLimit, request.Role);
        if (request.AgeLimit is not null) mode = ProfileAccessMode.EntireLibrary;
        var displayName = request.DisplayName is null ? null : ValidName(request.DisplayName);
        if (request.PictureKey is not null && !ProfilePictures.IsBuiltin(request.PictureKey))
            throw new AccountException("invalid_profile_picture", "Choose one of the built-in pictures.", 400);
        using var lease = await mutations.EnterAsync(token);
        await using var transaction = await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, token);
        await RequireOwnerAsync(actorId, token);
        var normalized = name.ToUpperInvariant();
        if (await database.Users.AnyAsync(user => user.NormalizedUsername == normalized, token)
            || await NameTakenAsync(displayName ?? name, null, token))
            throw new AccountException("username_in_use", "This profile name is already in use.", 409);
        var ids = await ValidateTitleAccessAsync(mode, request.TitleIds ?? [], request.Role, token);
        var user = new ServerUser
        {
            Id = Guid.NewGuid(),
            Username = name,
            NormalizedUsername = normalized,
            PasswordHash = "",
            Role = request.Role,
            IsEnabled = request.IsEnabled,
            PinProtectionEnabled = protection,
            AccessMode = mode,
            CreatedAt = DateTimeOffset.UtcNow,
            DisplayName = displayName == name ? null : displayName,
            PictureKey = request.PictureKey,
            PictureRevision = request.PictureKey is null ? 0 : 1,
            AgeLimit = request.AgeLimit,
        };
        using (await passwords.EnterAsync(token))
        {
            // Historic schema field only: no profile has a usable account password.
            user.PasswordHash = hasher.HashPassword(user, Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)));
            if (protection) user.PinHash = hasher.HashPassword(user, request.Pin!);
        }
        database.Users.Add(user);
        database.UserTitleGrants.AddRange(ids.Select(id => new UserTitleGrant { UserId = user.Id, MediaItemId = id }));
        await database.SaveChangesAsync(token);
        await transaction.CommitAsync(token);
        return ToSummary(user);
    }

    public async Task<ProfileEditorResponse> UpdateAsync(Guid actorId, Guid userId, UpdateProfileRequest request, CancellationToken token)
    {
        using var lease = await mutations.EnterAsync(token);
        await using var transaction = await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, token);
        await RequireOwnerAsync(actorId, token);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        if (request.Revision != user.ProfileRevision)
            throw new AccountException("profile_conflict", "This profile changed on another device. Reload before saving.", 409);
        if (!Enum.IsDefined(request.Role)) throw new AccountException("invalid_role", "Choose a valid profile role.", 400);
        if (user.Role == UserRole.Owner && user.IsEnabled && (request.Role != UserRole.Owner || !request.IsEnabled)
            && await database.Users.CountAsync(candidate => candidate.Role == UserRole.Owner && candidate.IsEnabled, token) <= 1)
            throw new AccountException("last_owner_required", "The final active owner cannot be disabled or demoted.", 409);
        if (request.Role != UserRole.User && !request.PinProtectionEnabled)
            throw new AccountException("pin_required_for_role", "Owner and Admin profiles must use a PIN.", 400);
        if (!request.PinProtectionEnabled && request.Pin is not null)
            throw new AccountException("invalid_pin_format", "Do not send a PIN for an unprotected profile.", 400);
        if (request.Pin is not null) ValidatePin(request.Pin);
        if (request.PinProtectionEnabled && request.Pin is null && (!user.PinProtectionEnabled
            || user.PinHash is null && request.Role != UserRole.User))
            throw new AccountException("pin_setup_required", "Enter a numeric PIN before enabling profile protection or assigning a privileged role.", 400);
        if (request.Role != UserRole.User && user.AgeLimit is not null)
            throw new AccountException("age_limit_role", "Remove the age limit before making this profile an Admin or Owner.", 400);
        if (request.AccessMode is null && request.TitleIds is not null)
            throw new AccountException("invalid_title_access", "Choose an access mode when changing selected titles.", 400);
        var mode = request.AccessMode ?? user.AccessMode;
        if (request.Role == UserRole.Owner && request.AccessMode is null) mode = ProfileAccessMode.EntireLibrary;
        var changeAccess = request.AccessMode is not null || mode != user.AccessMode;
        Guid[]? ids = changeAccess
            ? await ValidateTitleAccessAsync(mode, request.TitleIds ?? [], request.Role, token) : null;
        var oldRole = user.Role;
        var oldEnabled = user.IsEnabled;
        var protectionChanged = user.PinProtectionEnabled != request.PinProtectionEnabled || request.Pin is not null;
        // Validation completes before mutating any role, status, PIN or grants.
        var pinHash = request.Pin is not null ? await HashPinAsync(user, request.Pin, token) : user.PinHash;
        user.Role = request.Role;
        user.IsEnabled = request.IsEnabled;
        user.PinProtectionEnabled = request.PinProtectionEnabled;
        user.PinHash = request.PinProtectionEnabled ? pinHash : null;
        if (ids is not null)
        {
            database.UserTitleGrants.RemoveRange(await database.UserTitleGrants.Where(grant => grant.UserId == userId).ToListAsync(token));
            database.UserTitleGrants.AddRange(ids.Select(id => new UserTitleGrant { UserId = userId, MediaItemId = id }));
            user.AccessMode = mode;
            // Choosing individual titles replaces a children's age limit.
            if (mode != ProfileAccessMode.EntireLibrary) user.AgeLimit = null;
            user.AccessRevision++;
        }
        database.SyncChanges.Add(new SyncChange { UserId = userId, Area = SyncChangeArea.Catalog, CreatedAt = DateTimeOffset.UtcNow });
        await database.SaveChangesAsync(token);
        await transaction.CommitAsync(token);
        if (oldRole != user.Role || oldEnabled != user.IsEnabled || protectionChanged) sessions.RevokeUser(userId);
        if (oldRole != user.Role || oldEnabled != user.IsEnabled || protectionChanged || changeAccess) streams.RevokeUser(userId);
        return new(ToSummary(user), user.IsEnabled, await AccessAsync(userId, token), user.ProfileRevision);
    }

    public async Task<UserSummary> ChangeRoleAsync(Guid actorId, Guid userId, UserRole role, CancellationToken token)
    {
        var editor = await EditorAsync(userId, token);
        var result = await UpdateAsync(actorId, userId, new UpdateProfileRequest(editor.Revision, role,
            editor.IsEnabled, editor.User.PinProtectionEnabled), token);
        return result.User;
    }

    private async Task RequireOwnerAsync(Guid actorId, CancellationToken token)
    {
        if (!await database.Users.AnyAsync(user => user.Id == actorId && user.Role == UserRole.Owner && user.IsEnabled, token)) throw Forbidden();
    }

    private async Task<Guid[]> ValidateTitleAccessAsync(ProfileAccessMode mode, IReadOnlyList<Guid> titleIds, UserRole role, CancellationToken token)
    {
        if (mode is not (ProfileAccessMode.EntireLibrary or ProfileAccessMode.SelectedTitles) || titleIds.Count > 10000)
            throw new AccountException("invalid_title_access", "Choose the entire library or explicit films and series.", 400);
        if (role == UserRole.Owner && mode != ProfileAccessMode.EntireLibrary) throw Forbidden();
        var ids = mode == ProfileAccessMode.SelectedTitles ? titleIds.Distinct().ToArray() : [];
        if (await database.MediaItems.CountAsync(item => ids.Contains(item.Id) && item.ParentId == null
                && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series), token) != ids.Length)
            throw new AccountException("invalid_title_access", "A selected film or series does not exist.", 400);
        return ids;
    }

    public async Task SetEnabledAsync(Guid actorId, Guid userId, bool enabled, CancellationToken token)
    {
        using var lease = await mutations.EnterAsync(token);
        await RequireOwnerAsync(actorId, token);
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
        using var lease = await mutations.EnterAsync(token);
        await RequireOwnerAsync(actorId, token);
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
        if (request.Mode != ProfileAccessMode.EntireLibrary) user.AgeLimit = null;
        user.AccessRevision++;
        database.SyncChanges.Add(new SyncChange { UserId = userId, Area = SyncChangeArea.Catalog, CreatedAt = DateTimeOffset.UtcNow });
        await database.SaveChangesAsync(token);
        await transaction.CommitAsync(token);
        streams.RevokeUser(userId);
        return new(user.AccessMode, ids, user.AccessRevision);
    }

    /// <summary>Renames a profile. Its own profile may always be renamed; another only by an owner.</summary>
    public async Task<UserSummary> RenameAsync(Guid actorId, Guid userId, string name, CancellationToken token)
    {
        var clean = ValidName(name);
        using var lease = await mutations.EnterAsync(token);
        if (actorId != userId) await RequireOwnerAsync(actorId, token);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        if (await NameTakenAsync(clean, userId, token))
            throw new AccountException("username_in_use", "This profile name is already in use.", 409);
        // The sign-in name stays; only the shown name changes.
        user.DisplayName = clean == user.Username ? null : clean;
        await database.SaveChangesAsync(token);
        return ToSummary(user);
    }

    /// <summary>Sets a built-in picture, or the initial again when <paramref name="builtin"/> is null.</summary>
    public async Task<UserSummary> SetPictureAsync(Guid actorId, Guid userId, string? builtin, CancellationToken token)
    {
        if (builtin is not null && !ProfilePictures.IsBuiltin(builtin))
            throw new AccountException("invalid_profile_picture", "Choose one of the built-in pictures.", 400);
        using var lease = await mutations.EnterAsync(token);
        if (actorId != userId) await RequireOwnerAsync(actorId, token);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        if (await database.ProfilePhotos.SingleOrDefaultAsync(photo => photo.UserId == userId, token) is { } old) database.ProfilePhotos.Remove(old);
        user.PictureKey = builtin;
        user.PictureRevision++;
        await database.SaveChangesAsync(token);
        return ToSummary(user);
    }

    /// <summary>Stores an own photo: decoded, turned upright, cropped to a centered square and re-encoded small.</summary>
    public async Task<UserSummary> SetPhotoAsync(Guid actorId, Guid userId, Stream input, CancellationToken token)
    {
        using var bytes = new MemoryStream();
        var buffer = new byte[65_536];
        while (true)
        {
            var read = await input.ReadAsync(buffer, token);
            if (read == 0) break;
            if (bytes.Length + read > ProfilePictures.MaximumUploadBytes)
                throw new AccountException("profile_photo_too_large", "Choose a photo no larger than 8 MB.", 413);
            bytes.Write(buffer, 0, read);
        }
        var jpeg = ProfilePhotoEncoder.Encode(bytes.ToArray());
        using var lease = await mutations.EnterAsync(token);
        if (actorId != userId) await RequireOwnerAsync(actorId, token);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        var photo = await database.ProfilePhotos.SingleOrDefaultAsync(photo => photo.UserId == userId, token);
        if (photo is null) database.ProfilePhotos.Add(photo = new ProfilePhoto { UserId = userId });
        photo.Jpeg = jpeg;
        photo.UpdatedAt = DateTimeOffset.UtcNow;
        user.PictureKey = ProfilePictures.PhotoKey;
        user.PictureRevision++;
        await database.SaveChangesAsync(token);
        return ToSummary(user);
    }

    /// <summary>The photo of an enabled profile, for "Who's watching?" on every paired device.</summary>
    public async Task<byte[]?> PhotoAsync(Guid userId, CancellationToken token) =>
        await database.ProfilePhotos.AsNoTracking()
            .Where(photo => photo.UserId == userId && photo.User.IsEnabled && photo.User.PictureKey == ProfilePictures.PhotoKey)
            .Select(photo => photo.Jpeg).SingleOrDefaultAsync(token);

    public async Task<ProfileAgeLimitResponse> AgeLimitAsync(Guid userId, CancellationToken token)
    {
        var user = await database.Users.AsNoTracking().SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        var rules = await database.UserTitleRules.AsNoTracking().Where(rule => rule.UserId == userId)
            .Select(rule => new { rule.MediaItemId, rule.Allowed }).ToListAsync(token);
        return new(user.AgeLimit, [.. rules.Where(rule => rule.Allowed).Select(rule => rule.MediaItemId)],
            [.. rules.Where(rule => !rule.Allowed).Select(rule => rule.MediaItemId)], user.AccessRevision);
    }

    /// <summary>Makes a profile a children's profile (or a normal one again) and sets its exceptions.</summary>
    public async Task<ProfileAgeLimitResponse> UpdateAgeLimitAsync(Guid actorId, Guid userId, UpdateProfileAgeLimitRequest request, CancellationToken token)
    {
        if (request.AllowedTitleIds is null || request.HiddenTitleIds is null
            || request.AllowedTitleIds.Count + request.HiddenTitleIds.Count > 10000)
            throw new AccountException("invalid_title_access", "Choose up to 10,000 films and series.", 400);
        var allowed = request.AllowedTitleIds.Distinct().ToArray();
        var hidden = request.HiddenTitleIds.Distinct().Except(allowed).ToArray();
        using var lease = await mutations.EnterAsync(token);
        await RequireOwnerAsync(actorId, token);
        await using var transaction = await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, token);
        var user = await database.Users.SingleOrDefaultAsync(user => user.Id == userId, token)
            ?? throw new AccountException("profile_not_found", "The profile was not found.", 404);
        if (user.AccessRevision != request.Revision)
            throw new AccountException("profile_access_conflict", "Profile access changed on another device. Reload before saving.", 409);
        ValidateAgeLimit(request.AgeLimit, user.Role);
        var ids = allowed.Concat(hidden).ToArray();
        if (await database.MediaItems.CountAsync(item => ids.Contains(item.Id) && item.ParentId == null
                && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series), token) != ids.Length)
            throw new AccountException("invalid_title_access", "A selected film or series does not exist.", 400);
        database.UserTitleRules.RemoveRange(await database.UserTitleRules.Where(rule => rule.UserId == userId).ToListAsync(token));
        database.UserTitleRules.AddRange(allowed.Select(id => new UserTitleRule { UserId = userId, MediaItemId = id, Allowed = true }));
        database.UserTitleRules.AddRange(hidden.Select(id => new UserTitleRule { UserId = userId, MediaItemId = id, Allowed = false }));
        user.AgeLimit = request.AgeLimit;
        if (request.AgeLimit is not null && user.AccessMode != ProfileAccessMode.EntireLibrary)
        {
            database.UserTitleGrants.RemoveRange(await database.UserTitleGrants.Where(grant => grant.UserId == userId).ToListAsync(token));
            user.AccessMode = ProfileAccessMode.EntireLibrary;
        }
        user.AccessRevision++;
        database.SyncChanges.Add(new SyncChange { UserId = userId, Area = SyncChangeArea.Catalog, CreatedAt = DateTimeOffset.UtcNow });
        await database.SaveChangesAsync(token);
        await transaction.CommitAsync(token);
        streams.RevokeUser(userId);
        return new(user.AgeLimit, allowed, hidden, user.AccessRevision);
    }

    private static void ValidateAgeLimit(int? ageLimit, UserRole role)
    {
        if (!AgeRatings.IsLimit(ageLimit))
            throw new AccountException("invalid_age_limit", "Choose an age limit of FSK 0, 6, 12 or 16.", 400);
        if (ageLimit is not null && role != UserRole.User)
            throw new AccountException("age_limit_role", "Only profiles without server access can be children's profiles.", 400);
    }

    private static string ValidName(string name)
    {
        var clean = (name ?? "").Trim().Normalize(NormalizationForm.FormKC);
        if (clean.Length is < 1 or > 40 || clean.Any(char.IsControl))
            throw new AccountException("invalid_profile_name", "The name must contain 1 to 40 visible characters.", 400);
        return clean;
    }

    /// <summary>Another profile already shows this name (its display name or, without one, its sign-in name).</summary>
    private async Task<bool> NameTakenAsync(string name, Guid? except, CancellationToken token)
    {
        var names = await database.Users.AsNoTracking().Where(user => except == null || user.Id != except)
            .Select(user => user.DisplayName ?? user.Username).ToListAsync(token);
        return names.Any(other => string.Equals(other, name, StringComparison.OrdinalIgnoreCase));
    }

    public static bool IsPin(string? value) => value is { Length: >= 4 and <= 8 } && value.All(char.IsAsciiDigit);
    public static UserSummary ToSummary(ServerUser user) => new(user.Id, user.Username, user.Role, user.CreatedAt,
        user.AccessMode, user.PinProtectionEnabled, user.PinProtectionEnabled && user.PinHash is null, user.ProfileRevision,
        user.DisplayName ?? user.Username, user.PictureKey, user.PictureRevision, user.Role == UserRole.User ? user.AgeLimit : null);
    private static void ValidatePin(string? pin)
    { if (!IsPin(pin)) throw new AccountException("invalid_pin_format", "Use a numeric PIN with 4 to 8 digits.", 400); }
    private async Task<string> HashPinAsync(ServerUser user, string pin, CancellationToken token)
    { using (await passwords.EnterAsync(token)) return hasher.HashPassword(user, pin); }
    private async Task VerifyAsync(ServerUser user, string hash, string password, CancellationToken token, Guid? deviceSessionId = null)
    {
        if (password is null || password.Length is < 1 or > 1024) throw new AccountException("invalid_credentials", "The Server Password is incorrect.", 401);
        var attempts = deviceSessionId ?? user.Id;
        passwords.Check(attempts, DateTimeOffset.UtcNow);
        using var slot = await passwords.EnterAsync(token);
        var valid = hasher.VerifyHashedPassword(user, hash, password) != PasswordVerificationResult.Failed;
        passwords.Record(attempts, valid, DateTimeOffset.UtcNow);
        if (!valid) throw new AccountException("invalid_credentials", "The Server Password is incorrect.", 401);
    }
    private static AccountException Forbidden() => new("forbidden", "This profile cannot perform that action.", 403);
}
