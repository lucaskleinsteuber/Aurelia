using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class ServerUser
{
    public Guid Id { get; set; }

    public required string Username { get; set; }

    public required string NormalizedUsername { get; set; }

    public required string PasswordHash { get; set; }

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
