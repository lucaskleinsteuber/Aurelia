namespace Aurelia.Contracts;

public enum ProfileAccessMode { LegacyLibraries, EntireLibrary, SelectedTitles }
/// <summary>A profile in "Who's watching?". <paramref name="Name"/> is the name to show (the display name when one is set).</summary>
public sealed record WatchingProfile(Guid Id, string Name, UserRole Role, bool NeedsPinSetup, bool PinProtectionEnabled = true,
    string? PictureKey = null, long PictureRevision = 0, int? AgeLimit = null);
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

/// <summary>A new name to show for a profile. The owner's sign-in name stays as it is.</summary>
public sealed record UpdateProfileNameRequest(string Name);

/// <summary>A built-in picture (<c>symbol:palette</c>, see <see cref="ProfilePictures"/>), or null for the initial.</summary>
public sealed record UpdateProfilePictureRequest(string? Builtin);

/// <summary>
/// A children's profile: <paramref name="AgeLimit"/> is the highest FSK age it may watch (0, 6, 12 or 16), null
/// for none. Titles without a rating are hidden. <paramref name="AllowedTitleIds"/> may be watched anyway and
/// <paramref name="HiddenTitleIds"/> are always hidden; both are films or series.
/// </summary>
public sealed record ProfileAgeLimitResponse(int? AgeLimit, IReadOnlyList<Guid> AllowedTitleIds, IReadOnlyList<Guid> HiddenTitleIds, long Revision);
public sealed record UpdateProfileAgeLimitRequest(int? AgeLimit, IReadOnlyList<Guid> AllowedTitleIds, IReadOnlyList<Guid> HiddenTitleIds, long Revision);

/// <summary>The built-in profile pictures every client draws the same way: a symbol on a palette gradient.</summary>
public static class ProfilePictures
{
    public const string PhotoKey = "photo";
    public const int PhotoSize = 512;
    public const long MaximumUploadBytes = 8 * 1024 * 1024;

    /// <summary>Symbol names; each client maps them to its own icon set.</summary>
    public static IReadOnlyList<string> Symbols { get; } = Array.AsReadOnly(new[]
    {
        "star", "rocket", "cat", "dog", "heart", "bolt", "leaf", "moon", "music", "gamecontroller", "film", "crown",
    });

    /// <summary>Palette names, in the order of the clients' existing profile gradients.</summary>
    public static IReadOnlyList<string> Palettes { get; } = Array.AsReadOnly(new[]
    {
        "blue", "purple", "pink", "orange", "teal", "green", "indigo", "red",
    });

    public static string Builtin(string symbol, string palette) => $"{symbol}:{palette}";

    public static bool IsBuiltin(string? key) => key?.Split(':') is [var symbol, var palette]
        && Symbols.Contains(symbol) && Palettes.Contains(palette);
}

/// <summary>
/// Age ratings as Aurelia stores them: German FSK ("FSK 12") first, US ratings where TMDB has no FSK.
/// Children's profiles are limited to the FSK steps 0, 6, 12 and 16.
/// </summary>
public static class AgeRatings
{
    public static IReadOnlyList<int> Limits { get; } = Array.AsReadOnly(new[] { 0, 6, 12, 16 });

    // A US rating, used only where a title has no German one, counts as the next FSK at or above
    // its age (owner's choice, 08.11.2026): a children's profile never sees a title rated for older
    // children than its limit, at the cost of some titles a looser reading would allow.
    private static readonly (string Rating, int Age)[] Known =
    [
        ("FSK 0", 0), ("FSK 6", 6), ("FSK 12", 12), ("FSK 16", 16), ("FSK 18", 18),
        ("G", 0), ("TV-Y", 0), ("TV-G", 0),
        ("PG", 6), ("TV-PG", 6),
        ("TV-Y7", 12), ("TV-Y7-FV", 12),
        ("PG-13", 16), ("TV-14", 16),
        ("R", 18), ("TV-MA", 18), ("NC-17", 18),
    ];

    public static bool IsLimit(int? age) => age is null || Limits.Contains(age.Value);

    /// <summary>The age a rating allows, or null when it is unknown or missing.</summary>
    public static int? MinimumAge(string? rating) =>
        rating is null ? null : Known.Where(known => string.Equals(known.Rating, rating.Trim(), StringComparison.OrdinalIgnoreCase))
            .Select(known => (int?)known.Age).FirstOrDefault();

    /// <summary>Every stored rating a profile limited to <paramref name="limit"/> may watch.</summary>
    public static string[] AllowedFor(int? limit) => limit is { } age
        ? [.. Known.Where(known => known.Age <= age).Select(known => known.Rating)]
        : [];
}
