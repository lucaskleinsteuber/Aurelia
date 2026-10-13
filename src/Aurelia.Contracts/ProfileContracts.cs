namespace Aurelia.Contracts;

public enum ProfileAccessMode { LegacyLibraries, EntireLibrary, SelectedTitles }
public sealed record WatchingProfile(Guid Id, string Name, UserRole Role, bool NeedsPinSetup, bool PinProtectionEnabled = true);
public sealed record ProfilePickerResponse(int FormatVersion, string MinimumClientVersion, bool ManagementSetupRequired, IReadOnlyList<WatchingProfile> Profiles);
public sealed record InitializeProfilesRequest(string Password, string Pin);
public sealed record UnlockProfileRequest(string? Pin = null);
public sealed record ChangeProfilePinRequest(string CurrentPin, string NewPin);
public sealed record ResetProfilePinRequest(string Pin);
public sealed record UnlockManagementRequest(string Password);
public sealed record ManagementUnlockResponse(DateTimeOffset ExpiresAt);
public sealed record ProfileSessionResponse(UserSummary User, Guid SessionId, string Token, DateTimeOffset ExpiresAt);
public sealed record ProfileTitleAccessResponse(ProfileAccessMode Mode, IReadOnlyList<Guid> TitleIds, long Revision);
public sealed record UpdateProfileTitleAccessRequest(ProfileAccessMode Mode, IReadOnlyList<Guid> TitleIds, long Revision);
public sealed record SetProfileEnabledRequest(bool IsEnabled);
public sealed record ProfileEditorResponse(UserSummary User, bool IsEnabled, ProfileTitleAccessResponse Access, long Revision);
public sealed record UpdateProfileRequest(long Revision, UserRole Role, bool IsEnabled, bool PinProtectionEnabled,
    string? Pin = null, ProfileAccessMode? AccessMode = null, IReadOnlyList<Guid>? TitleIds = null);
public sealed record UpdateOwnPinProtectionRequest(bool PinProtectionEnabled, string? CurrentPin = null, string? Pin = null);
