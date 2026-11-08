using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Playback;

/// <summary>
/// A profile remembered for the offline mode, as on the Mac: its name and picture and, for a PIN,
/// only a salted PBKDF2 check value, never the PIN. Written each time the profile opens with the server.
/// </summary>
public sealed record OfflineProfileCard(
    Guid ServerId,
    Guid UserId,
    string Name,
    string? PictureKey,
    long PictureRevision,
    bool PinProtected,
    byte[]? Salt,
    byte[]? Check,
    DateTimeOffset RememberedAt)
{
    public const int Rounds = 210_000;

    public bool Accepts(string? pin)
    {
        if (!PinProtected) return true;
        if (Salt is null || Check is null || !ProfilePin.IsValid(pin)) return false;
        return CryptographicOperations.FixedTimeEquals(Derive(pin!, Salt), Check);
    }

    /// <summary>A card for a profile that just opened; deriving the PIN check takes a moment, so call it off the UI thread.</summary>
    public static OfflineProfileCard Make(Guid serverId, WatchingProfile profile, string? pin, DateTimeOffset now)
    {
        byte[]? salt = null;
        byte[]? check = null;
        var protectedByPin = profile.PinProtectionEnabled && ProfilePin.IsValid(pin);
        if (protectedByPin)
        {
            salt = RandomNumberGenerator.GetBytes(16);
            check = Derive(pin!, salt);
        }
        return new OfflineProfileCard(serverId, profile.Id, profile.Name, profile.PictureKey, profile.PictureRevision,
            protectedByPin, salt, check, now);
    }

    internal static byte[] Derive(string pin, byte[] salt) =>
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(pin), salt, Rounds, HashAlgorithmName.SHA256, 32);
}

/// <summary>
/// The offline cards of this computer in a private file beside the downloads (0600, like their
/// list). Linux keeps only the server connection in the keyring; the cards hold no secret beyond the
/// PIN check, which guards the profiles' downloads that lie in the same folder.
/// </summary>
public sealed class OfflineProfileStore(string? path)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly object gate = new();
    private List<OfflineProfileCard>? memory;

    public IReadOnlyList<OfflineProfileCard> Cards(Guid serverId)
    {
        lock (gate) return [.. Load().Where(card => card.ServerId == serverId)];
    }

    public void Remember(OfflineProfileCard card)
    {
        lock (gate)
        {
            var cards = Load();
            cards.RemoveAll(each => each.ServerId == card.ServerId && each.UserId == card.UserId);
            cards.Add(card);
            Save(cards);
        }
    }

    /// <summary>Removes the cards of a server this computer leaves.</summary>
    public void Forget(Guid serverId)
    {
        lock (gate)
        {
            var cards = Load();
            if (cards.RemoveAll(card => card.ServerId == serverId) > 0) Save(cards);
        }
    }

    private List<OfflineProfileCard> Load()
    {
        if (memory is not null) return memory;
        memory = [];
        if (path is null || !File.Exists(path)) return memory;
        try
        {
            memory = JsonSerializer.Deserialize<List<OfflineProfileCard>>(File.ReadAllText(path), Json) ?? [];
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or JsonException)
        {
            // Unreadable cards are written again when their profiles open with the server.
        }
        return memory;
    }

    private void Save(List<OfflineProfileCard> cards)
    {
        memory = cards;
        if (path is null) return;
        try
        {
            PrivateFiles.CreateDirectory(Path.GetDirectoryName(path)!);
            var partial = path + ".tmp";
            PrivateFiles.WriteAllText(partial, JsonSerializer.Serialize(cards, Json));
            File.Move(partial, path, overwrite: true);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
        {
            // Kept in memory; written again next time.
        }
    }
}

/// <summary>The profile whose downloads the offline mode shows.</summary>
public sealed record OfflineSession(Guid ServerId, Guid UserId, string Name, string? PictureKey, long PictureRevision)
{
    public static OfflineSession From(OfflineProfileCard card) => new(card.ServerId, card.UserId, card.Name, card.PictureKey, card.PictureRevision);
}

/// <summary>A profile with downloads on this computer, and its offline card if it has one.</summary>
public sealed record OfflineProfileChoice(Guid UserId, OfflineProfileCard? Card);

/// <summary>How the offline library arranges a profile's downloads, as on the Mac.</summary>
public sealed class OfflineLibraryLayout
{
    public sealed record Series(string Id, string Title, IReadOnlyList<OfflineTitle> Episodes);

    public OfflineLibraryLayout(IReadOnlyList<OfflineTitle> titles)
    {
        var inProgress = titles.Where(IsInProgress).OrderByDescending(title => title.ProgressSavedAt ?? title.DownloadedAt).ToList();
        Featured = inProgress.FirstOrDefault() ?? titles.MaxBy(title => title.DownloadedAt);
        ContinueWatching = inProgress;
        Movies = [.. titles.Where(title => title.Kind != MediaKind.Episode).OrderBy(title => title.Title, StringComparer.CurrentCultureIgnoreCase)];
        SeriesList = [.. titles.Where(title => title.Kind == MediaKind.Episode)
            .GroupBy(episode => episode.ParentId?.ToString() ?? SeriesName(episode))
            .Select(group => new Series(group.Key, SeriesName(group.First()),
                [.. group.OrderBy(e => e.SeasonNumber ?? 0).ThenBy(e => e.EpisodeNumber ?? 0).ThenBy(e => e.Title, StringComparer.CurrentCultureIgnoreCase)]))
            .OrderBy(series => series.Title, StringComparer.CurrentCultureIgnoreCase)];
    }

    /// <summary>The title the large picture at the top shows: the last one in progress, else the newest.</summary>
    public OfflineTitle? Featured { get; }

    public IReadOnlyList<OfflineTitle> ContinueWatching { get; }

    public IReadOnlyList<OfflineTitle> Movies { get; }

    public IReadOnlyList<Series> SeriesList { get; }

    public static bool IsInProgress(OfflineTitle title) => title.PositionMilliseconds > 0 && !title.IsCompleted;

    /// <summary>The series of an episode; older downloads only have it in front of "S1 E3" in the subtitle.</summary>
    public static string SeriesName(OfflineTitle episode)
    {
        if (!string.IsNullOrEmpty(episode.ParentTitle)) return episode.ParentTitle;
        if (episode.Subtitle?.Split(" · ")[0] is { Length: > 0 } name) return name;
        return "TV Show";
    }

    /// <summary>"S1 E3" for an episode.</summary>
    public static string? EpisodeLabel(OfflineTitle title) =>
        title.Kind == MediaKind.Episode && title.SeasonNumber is { } season ? $"S{season} E{title.EpisodeNumber ?? 0}" : null;
}

/// <summary>
/// The offline mode: Aurelia without the server, showing only the downloads on this computer. It
/// first chooses whose downloads to show (a card's PIN opens it), then shows that profile's.
/// </summary>
public sealed class OfflineModeModel : ObservableObject
{
    private readonly OfflineDownloads downloads;
    private readonly OfflineProfileStore store;
    private readonly TimeProvider time;
    private OfflineSession? session;
    private int failures;
    private DateTimeOffset? lockedUntil;

    public OfflineModeModel(OfflineDownloads downloads, OfflineProfileStore store, Guid serverId, string serverName, TimeProvider time, OfflineSession? open = null)
    {
        this.downloads = downloads;
        this.store = store;
        this.time = time;
        ServerId = serverId;
        ServerName = serverName;
        var choices = Choices;
        session = open ?? (choices.Count == 1 && choices[0].Card is { PinProtected: false } only ? OfflineSession.From(only) : null);
    }

    public Guid ServerId { get; }

    public string ServerName { get; }

    /// <summary>Whether to offer the offline mode: downloads of this server on this computer.</summary>
    public static bool CanOffer(OfflineDownloads? downloads, Guid? serverId) =>
        downloads is not null && serverId is { } server && downloads.Titles.Any(title => title.ServerId == server);

    /// <summary>The open profile; null while choosing one.</summary>
    public OfflineSession? Session
    {
        get => session;
        private set
        {
            if (SetProperty(ref session, value)) OnPropertyChanged(nameof(Titles));
        }
    }

    /// <summary>The profiles with downloads here; one without a card has not been opened here since the offline mode exists.</summary>
    public IReadOnlyList<OfflineProfileChoice> Choices
    {
        get
        {
            var cards = store.Cards(ServerId);
            var owners = downloads.Titles.Where(title => title.ServerId == ServerId).Select(title => title.UserId).Distinct().ToList();
            return [.. cards.Where(card => owners.Contains(card.UserId)).OrderBy(card => card.Name, StringComparer.CurrentCultureIgnoreCase)
                    .Select(card => new OfflineProfileChoice(card.UserId, card)),
                .. owners.Where(owner => cards.All(card => card.UserId != owner)).Select(owner => new OfflineProfileChoice(owner, null))];
        }
    }

    public IReadOnlyList<OfflineTitle> Titles => Session is { } open ? downloads.For(open.ServerId, open.UserId) : [];

    /// <summary>Until when the next PIN must wait after five wrong ones in a row.</summary>
    public DateTimeOffset? LockedUntil
    {
        get => lockedUntil;
        private set => SetProperty(ref lockedUntil, value);
    }

    /// <summary>Opens a profile's downloads. False for a wrong PIN or while tries must wait; after five wrong PINs each further try waits, doubling up to five minutes.</summary>
    public bool OpenProfile(OfflineProfileCard card, string? pin)
    {
        if (card.ServerId != ServerId) return false;
        if (LockedUntil is { } until && until > time.GetUtcNow()) return false;
        if (!card.Accepts(pin))
        {
            failures++;
            if (failures >= 5) LockedUntil = time.GetUtcNow().AddSeconds(Math.Min(300, 30 * Math.Pow(2, failures - 5)));
            return false;
        }
        failures = 0;
        LockedUntil = null;
        Session = OfflineSession.From(card);
        return true;
    }

    /// <summary>Back to the profiles.</summary>
    public void ChooseOtherProfile() => Session = null;

    /// <summary>Downloads changed (one was removed, progress was saved): pages read <see cref="Titles"/> again.</summary>
    public void Refresh() => OnPropertyChanged(nameof(Titles));
}
