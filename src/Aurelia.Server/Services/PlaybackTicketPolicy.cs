using System.Globalization;

namespace Aurelia.Server.Services;

/// <summary>A short lifetime is available only to isolated integration hosts.</summary>
public sealed record PlaybackTicketPolicy(TimeSpan Lifetime)
{
    public static readonly TimeSpan ProductionLifetime = TimeSpan.FromHours(12);

    public static PlaybackTicketPolicy Resolve(bool isTesting, string? testSeconds)
    {
        if (!isTesting || string.IsNullOrEmpty(testSeconds))
            return new PlaybackTicketPolicy(ProductionLifetime);
        if (!int.TryParse(testSeconds, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds)
            || seconds is < 30 or > 43_200)
            throw new InvalidOperationException("The isolated playback ticket lifetime is invalid.");
        return new PlaybackTicketPolicy(TimeSpan.FromSeconds(seconds));
    }
}
