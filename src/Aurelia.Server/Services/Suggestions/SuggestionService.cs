using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services.Suggestions;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// What to watch next (<see cref="SuggestionScoring"/>): for one title, and for Home's "Because You
/// Watched …" rails and its hero. Only titles the profile may open count (the catalog's own
/// access filters, so a children's profile is limited by its age), and finished ones are left out.
/// </summary>
public sealed class SuggestionService(AureliaDbContext database, PresentationService presentation)
{
    public const int DefaultLimit = 10;
    public const int MaximumLimit = 30;
    private const int RailCount = 3;
    private const int RailLength = 12;

    /// <summary>The library as suggestions see it, for one profile.</summary>
    private sealed record Library(IReadOnlyList<SuggestionTitle> Titles, IReadOnlyDictionary<Guid, SuggestionTitle> ById, IReadOnlySet<Guid> Finished, SuggestionScoring.Rarity Rarity);

    public async Task<MediaSuggestionsResponse> SuggestAsync(Guid userId, Guid mediaId, int limit, CancellationToken cancellationToken)
    {
        if (limit is < 1 or > MaximumLimit)
            throw new MetadataException("invalid_limit", $"Ask for 1 to {MaximumLimit} suggestions.", StatusCodes.Status400BadRequest);
        var item = await database.MediaItems.AsNoTracking().Where(candidate => candidate.Id == mediaId)
            .Select(candidate => new { candidate.Id, candidate.Kind, candidate.ParentId })
            .SingleOrDefaultAsync(cancellationToken)
            ?? throw new MetadataException("media_not_found", "The media item was not found.", StatusCodes.Status404NotFound);
        var seedId = item.Kind == MediaKind.Episode && item.ParentId is { } series ? series : item.Id;
        var library = await LoadAsync(userId, cancellationToken);
        if (!library.ById.TryGetValue(seedId, out var seed)) return new MediaSuggestionsResponse(mediaId, []);
        var ranked = SuggestionScoring.Rank(seed, library.Titles, library.Finished, library.Rarity, limit);
        return new MediaSuggestionsResponse(mediaId, await CardsAsync(userId, ranked, cancellationToken));
    }

    /// <summary>
    /// "Because You Watched …" for the profile's latest finished or watched titles, each rail with
    /// titles no earlier rail shows, and the personal top ten the hero is chosen from.
    /// </summary>
    public async Task<(IReadOnlyList<HomeSuggestionRail> Rails, IReadOnlyList<Guid> TopTen)> HomeAsync(Guid userId, CancellationToken cancellationToken)
    {
        var library = await LoadAsync(userId, cancellationToken);
        if (library.Titles.Count < 2) return ([], []);
        // The latest titles watched to the end or at least a while: a movie itself, a series by its episodes.
        var watched = await database.PlaybackProgress.AsNoTracking()
            .Where(progress => progress.UserId == userId && (progress.IsCompleted || progress.PositionMilliseconds > 600_000))
            .Select(progress => new { Id = progress.MediaItem.Kind == MediaKind.Episode ? progress.MediaItem.ParentId : progress.MediaItemId, progress.LastPlayedAt })
            .ToListAsync(cancellationToken);
        var seeds = watched.Where(entry => entry.Id is { } id && library.ById.ContainsKey(id))
            .GroupBy(entry => entry.Id!.Value)
            .Select(group => (Id: group.Key, Played: group.Max(entry => entry.LastPlayedAt)))
            .OrderByDescending(entry => entry.Played).ThenBy(entry => entry.Id)
            .Take(8).Select(entry => library.ById[entry.Id]).ToList();
        if (seeds.Count == 0) return ([], []);

        var shown = new HashSet<Guid>();
        var totals = new Dictionary<Guid, double>();
        var rails = new List<HomeSuggestionRail>();
        foreach (var seed in seeds)
        {
            var ranked = SuggestionScoring.Rank(seed, library.Titles, library.Finished, library.Rarity, 40);
            foreach (var scored in ranked)
            {
                // A title that follows several watched ones well ranks high in the top ten.
                if (!seeds.Any(other => other.Id == scored.Title.Id)) totals[scored.Title.Id] = totals.GetValueOrDefault(scored.Title.Id) + scored.Score;
            }
            if (rails.Count >= RailCount) continue;
            var fresh = ranked.Where(scored => !shown.Contains(scored.Title.Id)).Take(RailLength).ToList();
            if (fresh.Count < 3) continue;
            foreach (var scored in fresh) shown.Add(scored.Title.Id);
            rails.Add(new HomeSuggestionRail(seed.Id, seed.Title, await CardsAsync(userId, fresh, cancellationToken)));
        }
        var topTen = totals.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key).Take(10).Select(pair => pair.Key).ToList();
        return (rails, topTen);
    }

    private async Task<IReadOnlyList<MediaSuggestion>> CardsAsync(Guid userId, IReadOnlyList<ScoredSuggestion> ranked, CancellationToken cancellationToken)
    {
        var cards = (await presentation.SummariesAsync(userId, [.. ranked.Select(scored => scored.Title.Id)], cancellationToken)).ToDictionary(card => card.Id);
        return [.. ranked.Where(scored => cards.ContainsKey(scored.Title.Id)).Select(scored => new MediaSuggestion(cards[scored.Title.Id], scored.Kind, scored.Reason))];
    }

    private async Task<Library> LoadAsync(Guid userId, CancellationToken cancellationToken)
    {
        // The catalog's access filters apply here: only what this profile may open.
        var rows = await database.MediaItems.AsNoTracking()
            .Where(item => (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series) && item.Availability == MediaAvailability.Available)
            .Select(item => new
            {
                item.Id,
                item.Kind,
                item.DetectedTitle,
                item.OverrideTitle,
                item.Year,
                Title = item.Metadata == null ? null : item.Metadata.ManualTitle ?? item.Metadata.ProviderTitle,
                Release = item.Metadata == null ? null : item.Metadata.ManualReleaseDate ?? item.Metadata.ProviderReleaseDate,
                Genres = item.Metadata == null ? null : item.Metadata.ManualGenresJson ?? item.Metadata.ProviderGenresJson,
                Studios = item.Metadata == null ? null : item.Metadata.ManualStudiosJson ?? item.Metadata.ProviderStudiosJson,
                Rating = item.Metadata == null ? null : item.Metadata.ManualContentRating ?? item.Metadata.ProviderContentRating,
            })
            .ToListAsync(cancellationToken);
        var ids = rows.Select(row => row.Id).ToHashSet();
        var keywords = (await database.MediaKeywords.AsNoTracking().Select(row => new { row.MediaItemId, row.KeywordsJson }).ToListAsync(cancellationToken))
            .Where(row => ids.Contains(row.MediaItemId)).ToDictionary(row => row.MediaItemId, row => row.KeywordsJson);

        var credits = (await database.MediaCredits.AsNoTracking()
                .Where(credit => (credit.Department == "Acting" && credit.SortOrder < SuggestionScoring.LeadingActors)
                    || credit.Job == "Director" || credit.Job == "Creator")
                .Select(credit => new { credit.MediaItemId, credit.Name, credit.Department, credit.Job, credit.SortOrder })
                .ToListAsync(cancellationToken))
            .Where(credit => ids.Contains(credit.MediaItemId))
            .GroupBy(credit => credit.MediaItemId)
            .ToDictionary(group => group.Key, group => group.ToList());

        var franchises = (await database.Set<MediaCollectionMember>().AsNoTracking()
                .Where(member => member.Collection.Provider == "tmdb" || member.Collection.Provider == MediaUniverses.Provider)
                .Select(member => new { member.MediaItemId, member.Collection.Id, member.Collection.Provider, member.Collection.ProviderCollectionId, member.Collection.Name })
                .ToListAsync(cancellationToken))
            .Where(member => ids.Contains(member.MediaItemId))
            .GroupBy(member => member.MediaItemId)
            .ToDictionary(group => group.Key, group => group
                .Select(member => new SuggestionFranchise($"{member.Provider}:{member.ProviderCollectionId ?? member.Id.ToString()}", member.Name, member.Provider == "tmdb"))
                .Distinct().ToList());

        var titles = rows.Select(row =>
        {
            var people = credits.GetValueOrDefault(row.Id) ?? [];
            return new SuggestionTitle(
                row.Id,
                row.Kind,
                row.Title ?? row.OverrideTitle ?? row.DetectedTitle,
                row.Release is { Length: >= 4 } release ? release : row.Year?.ToString("0000", System.Globalization.CultureInfo.InvariantCulture),
                MetadataPresentation.ParseList(row.Genres),
                MetadataPresentation.ParseList(row.Studios),
                MetadataPresentation.ParseList(keywords.GetValueOrDefault(row.Id)),
                franchises.GetValueOrDefault(row.Id) ?? [],
                [.. people.Where(credit => credit.Department == "Acting").OrderBy(credit => credit.SortOrder).Select(credit => credit.Name)],
                [.. people.Where(credit => credit.Job is "Director" or "Creator").Select(credit => credit.Name).Distinct()],
                AgeRatings.MinimumAge(row.Rating));
        }).ToList();

        var finishedMovies = await database.PlaybackProgress.AsNoTracking()
            .Where(progress => progress.UserId == userId && progress.IsCompleted && progress.MediaItem.Kind == MediaKind.Movie)
            .Select(progress => progress.MediaItemId).ToListAsync(cancellationToken);
        // A series is finished when every regular episode is.
        var finishedSeries = await database.MediaItems.AsNoTracking()
            .Where(series => series.Kind == MediaKind.Series
                && series.Children.Any(episode => episode.Kind == MediaKind.Episode && episode.SeasonNumber > 0)
                && !series.Children.Any(episode => episode.Kind == MediaKind.Episode && episode.SeasonNumber > 0
                    && !episode.PlaybackProgress.Any(progress => progress.UserId == userId && progress.IsCompleted)))
            .Select(series => series.Id).ToListAsync(cancellationToken);
        var finished = finishedMovies.Concat(finishedSeries).ToHashSet();
        return new Library(titles, titles.ToDictionary(title => title.Id), finished, SuggestionScoring.Weigh(titles));
    }
}
