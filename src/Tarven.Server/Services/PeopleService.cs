using System.Text.Json;
using Tarven.Contracts;
using Tarven.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Tarven.Server.Services;

/// <summary>
/// People ("people-v1", owner's wish 16.11.2026): everyone in the library's credits, with search,
/// and a person's life and the titles TMDB knows them for. The profile is read from TMDB when a
/// page opens and kept for 30 days; only what TMDB publishes is kept, and only when the owner
/// turned TMDB on.
/// </summary>
public sealed partial class PeopleService(
    TarvenDbContext database,
    MetadataProviderSettingsStore metadataSettings,
    ITmdbClient tmdb,
    WishService wishes,
    TimeProvider clock,
    ILogger<PeopleService> logger)
{
    public const int MaximumPage = 120;
    public const int KnownForShown = 20;
    public static readonly TimeSpan ProfileLifetime = TimeSpan.FromDays(30);
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>
    /// The people of the movies and shows this profile may see, those in the most titles first;
    /// `query` finds them by name. Only people TMDB identified are listed: a credit typed by hand
    /// has no page of its own to open.
    /// </summary>
    public async Task<PeoplePageResponse> ListAsync(string? query, int offset, int limit, CancellationToken cancellationToken)
    {
        TextInputValidation.ValidatePage(offset, limit, MaximumPage);
        var titles = database.MediaItems.AsNoTracking().Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series);
        var credits = database.MediaCredits.AsNoTracking()
            .Where(credit => credit.ProviderPersonId != null)
            .Join(titles, credit => credit.MediaItemId, item => item.Id, (credit, _) => credit);
        var trimmed = query?.Trim();
        if (!string.IsNullOrEmpty(trimmed))
        {
            if (trimmed.Length > 128) trimmed = trimmed[..128];
            var pattern = $"%{EscapeLike(trimmed)}%";
            credits = credits.Where(credit => EF.Functions.Like(credit.Name, pattern, "\\"));
        }
        var grouped = credits.GroupBy(credit => credit.ProviderPersonId!)
            .Select(group => new
            {
                Key = group.Key,
                Titles = group.Select(credit => credit.MediaItemId).Distinct().Count(),
                Name = group.Max(credit => credit.Name),
            });
        var total = await grouped.CountAsync(cancellationToken);
        var page = await grouped.OrderByDescending(person => person.Titles).ThenBy(person => person.Name).ThenBy(person => person.Key)
            .Skip(offset).Take(limit).ToListAsync(cancellationToken);
        if (page.Count == 0) return new PeoplePageResponse([], total, offset, limit);

        var keys = page.Select(person => person.Key).ToList();
        var details = await credits.Where(credit => keys.Contains(credit.ProviderPersonId!))
            .Select(credit => new { Key = credit.ProviderPersonId!, credit.Department, credit.Job, credit.ProfileAssetId, credit.SortOrder })
            .ToListAsync(cancellationToken);
        var byPerson = details.GroupBy(detail => detail.Key).ToDictionary(group => group.Key, group => group.ToList());
        var assetIds = details.Where(detail => detail.ProfileAssetId.HasValue).Select(detail => detail.ProfileAssetId!.Value).Distinct().ToList();
        var assets = await database.ArtworkAssets.AsNoTracking().Where(asset => assetIds.Contains(asset.Id))
            .ToDictionaryAsync(asset => asset.Id, cancellationToken);
        var people = page.Select(person =>
        {
            var entries = byPerson.GetValueOrDefault(person.Key) ?? [];
            var picture = entries.OrderBy(entry => entry.SortOrder)
                .Select(entry => entry.ProfileAssetId is { } id && assets.TryGetValue(id, out var asset) ? asset : null)
                .FirstOrDefault(asset => asset is not null);
            var department = entries.Any(entry => string.Equals(entry.Department, "Acting", StringComparison.OrdinalIgnoreCase))
                ? "Acting"
                : entries.GroupBy(entry => entry.Job ?? entry.Department).OrderByDescending(group => group.Count()).Select(group => group.Key).FirstOrDefault();
            return new PersonSummary(person.Name ?? "Unknown", $"tmdb:person:{person.Key}",
                picture is null ? null : MetadataPresentation.ToArtwork(picture), person.Titles, department);
        }).ToList();
        return new PeoplePageResponse(people, total, offset, limit);
    }

    /// <summary>
    /// A person's life and the titles the library doesn't have that they are known for. Empty
    /// without TMDB, for a person TMDB doesn't know, or when TMDB can't be reached and nothing was
    /// kept; the page then shows the library's titles only.
    /// </summary>
    public async Task<PersonProfileResponse> ProfileAsync(
        Guid callerId,
        string personKey,
        CancellationToken cancellationToken)
    {
        if (ProviderPersonId(personKey) is not { } personId) return new PersonProfileResponse(null, []);
        var inVisibleLibrary = await database.MediaCredits.AsNoTracking()
            .Where(credit => credit.ProviderPersonId == personId)
            .Join(
                database.MediaItems.AsNoTracking().Where(item => item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series),
                credit => credit.MediaItemId,
                item => item.Id,
                (credit, _) => credit.Id)
            .AnyAsync(cancellationToken);
        if (!inVisibleLibrary) return new PersonProfileResponse(null, []);
        var configuration = metadataSettings.Load();
        var stored = await database.PersonProfiles.SingleOrDefaultAsync(
            profile => profile.Provider == "tmdb" && profile.ProviderPersonId == personId, cancellationToken);
        var fresh = stored is not null && stored.Language == configuration.Language && clock.GetUtcNow() - stored.FetchedAt < ProfileLifetime;
        if (!fresh && configuration.Enabled && !string.IsNullOrWhiteSpace(configuration.Token))
        {
            try
            {
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                deadline.CancelAfter(TimeSpan.FromSeconds(8));
                var person = await tmdb.GetPersonAsync(configuration.Token, configuration.Language, personId, deadline.Token);
                if (person is not null) stored = await KeepAsync(stored, person, configuration.Language, cancellationToken);
            }
            catch (Exception exception) when (!cancellationToken.IsCancellationRequested
                && exception is MetadataException or JsonException or HttpRequestException or OperationCanceledException)
            {
                // TMDB is slow or away: what was kept still shows; without it, the library's titles.
                LogProfileUnavailable(logger, exception.Message);
            }
        }
        if (stored is null) return new PersonProfileResponse(null, []);
        var about = new PersonAbout(stored.Biography, stored.Birthday, stored.Deathday, stored.PlaceOfBirth, stored.KnownForDepartment, "tmdb", personId);
        var caller = await database.Users.AsNoTracking().SingleOrDefaultAsync(user => user.Id == callerId, cancellationToken);
        if (caller is not null && caller.Role == UserRole.User && caller.AccessMode == ProfileAccessMode.EntireLibrary && caller.AgeLimit is not null)
        {
            // External TMDB "Known for" credits carry no age rating; child profiles only see their library titles.
            return new PersonProfileResponse(about, []);
        }
        List<TmdbPersonCredit> credits;
        try { credits = JsonSerializer.Deserialize<List<TmdbPersonCredit>>(stored.CreditsJson, JsonOptions) ?? []; }
        catch (JsonException) { credits = []; }
        var candidates = credits.Select(credit => new WishCandidate(
            credit.MediaType == "tv" ? MediaKind.Series : MediaKind.Movie, credit.ProviderMediaId, credit.Title, credit.Year, credit.Overview, credit.PosterPath)).ToList();
        var described = await wishes.DescribeAsync(callerId, candidates, cancellationToken);
        return new PersonProfileResponse(about, described.Where(hit => !hit.AlreadyInLibrary).Take(KnownForShown).ToList());
    }

    private async Task<PersonProfile> KeepAsync(PersonProfile? stored, TmdbPerson person, string language, CancellationToken cancellationToken)
    {
        static string? Trim(string? value, int length)
        {
            if (string.IsNullOrWhiteSpace(value)) return null;
            var text = value.Trim();
            return text.Length > length ? text[..length] : text;
        }
        static string? Date(string? value) => value is { Length: 10 } && DateOnly.TryParseExact(value, "yyyy-MM-dd", out _) ? value : null;
        if (stored is null)
        {
            stored = new PersonProfile { Provider = "tmdb", ProviderPersonId = person.Id };
            database.PersonProfiles.Add(stored);
        }
        stored.Language = language;
        stored.Name = Trim(person.Name, 256) ?? "Unknown";
        stored.Biography = Trim(person.Biography, 8192);
        stored.Birthday = Date(person.Birthday);
        stored.Deathday = Date(person.Deathday);
        stored.PlaceOfBirth = Trim(person.PlaceOfBirth, 256);
        stored.KnownForDepartment = Trim(person.KnownForDepartment, 64);
        stored.ProfilePath = WishPosterCache.IsSafePosterPath(person.ProfilePath) ? person.ProfilePath : null;
        stored.CreditsJson = JsonSerializer.Serialize(person.Credits, JsonOptions);
        stored.FetchedAt = clock.GetUtcNow();
        try
        {
            await database.SaveChangesAsync(cancellationToken);
        }
        catch (DbUpdateException)
        {
            // Two pages opened the same person at once; the other one kept it.
            database.ChangeTracker.Clear();
            stored = await database.PersonProfiles.AsNoTracking().SingleAsync(
                profile => profile.Provider == "tmdb" && profile.ProviderPersonId == person.Id, cancellationToken);
        }
        return stored;
    }

    /// <summary>"tmdb:person:17419" → "17419"; other keys have no TMDB page.</summary>
    public static string? ProviderPersonId(string? personKey)
    {
        const string prefix = "tmdb:person:";
        if (personKey is null || !personKey.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return null;
        var id = personKey[prefix.Length..].Trim();
        return id.Length is > 0 and <= 16 && id.All(char.IsAsciiDigit) ? id : null;
    }

    private static string EscapeLike(string value) =>
        value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("%", "\\%", StringComparison.Ordinal).Replace("_", "\\_", StringComparison.Ordinal);

    [LoggerMessage(LogLevel.Information, "A person's TMDB profile could not be read: {Message}")]
    private static partial void LogProfileUnavailable(ILogger logger, string message);
}
