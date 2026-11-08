using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class ServerUser
{
    public Guid Id { get; set; }

    public required string Username { get; set; }

    public required string NormalizedUsername { get; set; }

    public required string PasswordHash { get; set; }
    public string? PinHash { get; set; }
    public bool PinProtectionEnabled { get; set; } = true;
    public long ProfileRevision { get; set; }
    public ProfileAccessMode AccessMode { get; set; } = ProfileAccessMode.LegacyLibraries;
    public long AccessRevision { get; set; }

    /// <summary>The name to show, when it differs from the sign-in name <see cref="Username"/>.</summary>
    public string? DisplayName { get; set; }

    /// <summary>A built-in picture key, "photo" for <see cref="ProfilePhoto"/>, or null for the initial.</summary>
    public string? PictureKey { get; set; }
    public long PictureRevision { get; set; }

    /// <summary>A children's profile: the highest FSK age it may watch; unrated titles stay hidden.</summary>
    public int? AgeLimit { get; set; }

    public UserRole Role { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public bool IsEnabled { get; set; } = true;

    public List<UserLibraryGrant> LibraryGrants { get; set; } = [];

    public List<DeviceSession> Sessions { get; set; } = [];

    public List<PairingCode> PairingCodes { get; set; } = [];

    public List<PlaybackTicket> PlaybackTickets { get; set; } = [];

    public List<PlaybackProgress> PlaybackProgress { get; set; } = [];

    public List<UserFavorite> Favorites { get; set; } = [];
}
