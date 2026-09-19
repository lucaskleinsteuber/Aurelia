using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class MetadataService(
    AureliaDbContext database,
    MetadataProviderSettingsStore settings,
    ITmdbClient tmdb,
    MetadataJobScheduler scheduler,
    ArtworkStore artworkStore,
    MediaSearchIndexService searchIndex)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task<MetadataProviderStatus> GetStatusAsync(CancellationToken cancellationToken)
    {
        var configuration = settings.Load();
        return new MetadataProviderStatus(
            configuration.Enabled,
            configuration.Token is not null,
            configuration.Language,
            await artworkStore.UsedBytesAsync(database, cancellationToken),
            configuration.ArtworkLimitBytes,
            "TMDB",
            "This product uses the TMDB API but is not endorsed or certified by TMDB.");
    }

    public async Task<MetadataProviderStatus> ConfigureAsync(UpdateMetadataProviderRequest request, CancellationToken cancellationToken)
    {
        if (request.Token is not null)
        {
            await tmdb.ValidateAsync(request.Token.Trim(), cancellationToken);
        }
        settings.Save(request);
        return await GetStatusAsync(cancellationToken);
    }

    public async Task<MetadataProviderStatus> RemoveTokenAsync(CancellationToken cancellationToken)
    {
        settings.RemoveToken();
        return await GetStatusAsync(cancellationToken);
    }

    public async Task<MetadataJobSummary> StartAsync(Guid? libraryId, Guid? mediaId, CancellationToken cancellationToken)
        => await StartAsync(
            new StartMetadataJobRequest(
                mediaId.HasValue ? MetadataJobMode.SingleItem : MetadataJobMode.FullRefresh,
                libraryId,
                mediaId),
            cancellationToken);

    public async Task<MetadataJobSummary> StartAsync(
        StartMetadataJobRequest request,
        CancellationToken cancellationToken)
    {
        RequireEnabled();
        var libraryId = request.LibraryId;
        var mediaId = request.MediaId;
        if (libraryId.HasValue && !await database.LibraryRoots.AnyAsync(item => item.Id == libraryId, cancellationToken))
            throw NotFound("library_not_found", "The storage location was not found.");
        if (mediaId.HasValue && !await database.MediaItems.AnyAsync(item => item.Id == mediaId, cancellationToken))
            throw NotFound("media_not_found", "The media item was not found.");
        if (request.Mode == MetadataJobMode.SingleItem && !mediaId.HasValue)
            throw new MetadataException("metadata_item_required", "Single-item metadata refresh requires a media ID.", StatusCodes.Status400BadRequest);
        if (await database.MetadataJobs.AnyAsync(job => job.State == MetadataJobState.Queued || job.State == MetadataJobState.Running, cancellationToken))
            throw new MetadataException("metadata_job_active", "A metadata job is already running.", StatusCodes.Status409Conflict);

        var job = new MetadataJob
        {
            Id = Guid.NewGuid(),
            LibraryRootId = libraryId,
            MediaItemId = mediaId,
            Mode = request.Mode,
            State = MetadataJobState.Queued,
            CreatedAt = DateTimeOffset.UtcNow,
        };
        database.MetadataJobs.Add(job);
        await database.SaveChangesAsync(cancellationToken);
        scheduler.Pulse();
        return ToSummary(job);
    }

    public async Task<MetadataJobSummary> GetJobAsync(Guid id, CancellationToken cancellationToken) =>
        ToSummary(await database.MetadataJobs.AsNoTracking().SingleOrDefaultAsync(job => job.Id == id, cancellationToken)
            ?? throw NotFound("metadata_job_not_found", "The metadata job was not found."));

    public async Task<IReadOnlyList<MetadataJobSummary>> ListJobsAsync(
        bool activeOnly,
        int limit,
        CancellationToken cancellationToken)
    {
        if (limit is < 1 or > 100)
            throw new MetadataException("invalid_page", "Limit must be between 1 and 100.", StatusCodes.Status400BadRequest);
        var query = database.MetadataJobs.AsNoTracking();
        if (activeOnly)
            query = query.Where(job => job.State == MetadataJobState.Queued || job.State == MetadataJobState.Running);
        return (await query.OrderByDescending(job => job.CreatedAt).Take(limit).ToListAsync(cancellationToken))
            .Select(ToSummary).ToList();
    }

    public async Task CancelJobAsync(Guid id, CancellationToken cancellationToken)
    {
        var job = await database.MetadataJobs.SingleOrDefaultAsync(value => value.Id == id, cancellationToken)
            ?? throw NotFound("metadata_job_not_found", "The metadata job was not found.");
        if (job.State is MetadataJobState.Completed or MetadataJobState.Failed
            or MetadataJobState.Interrupted or MetadataJobState.Cancelled)
            return;
        job.CancelRequestedAt ??= DateTimeOffset.UtcNow;
        if (job.State == MetadataJobState.Queued)
        {
            job.State = MetadataJobState.Cancelled;
            job.CompletedAt = DateTimeOffset.UtcNow;
        }
        await database.SaveChangesAsync(cancellationToken);
        scheduler.RequestCancellation(id);
    }

    public async Task<IReadOnlyList<MetadataReviewSummary>> ReviewsAsync(CancellationToken cancellationToken)
    {
        var reviews = await database.MetadataReviews.AsNoTracking().Include(review => review.MediaItem)
            .Where(review => review.State == MetadataReviewState.NeedsReview)
            .OrderBy(review => review.MediaItem.DetectedTitle).Take(500).ToListAsync(cancellationToken);
        return reviews.Select(ToReview).ToList();
    }

    public async Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(Guid mediaId, string? query, CancellationToken cancellationToken)
    {
        var configuration = RequireEnabled();
        var item = await RequireMatchableItemAsync(mediaId, cancellationToken);
        return await tmdb.SearchAsync(
            configuration.Token!, configuration.Language, item.Kind,
            string.IsNullOrWhiteSpace(query) ? item.OverrideTitle ?? item.DetectedTitle : query.Trim(),
            item.Year, cancellationToken);
    }

    public async Task<MediaMetadataSummary> SelectAsync(Guid mediaId, SelectMetadataMatchRequest request, CancellationToken cancellationToken)
    {
        var configuration = RequireEnabled();
        var item = await RequireMatchableItemAsync(mediaId, cancellationToken);
        var expectedType = item.Kind == MediaKind.Movie ? "movie" : "tv";
        if (!string.Equals(request.MediaType, expectedType, StringComparison.Ordinal))
            throw new MetadataException("metadata_type_mismatch", "The selected result has the wrong media type.", StatusCodes.Status400BadRequest);
        var provider = await tmdb.GetAsync(configuration.Token!, configuration.Language, request.MediaType, request.ProviderMediaId, cancellationToken);
        await ApplyAsync(item, provider, 1, cancellationToken);
        // Manual matching must enrich the whole series just like the automatic
        // metadata job does. Previously only the series record was updated, so
        // choosing a TV result from the review queue left its episodes unmatched.
        await ApplyEpisodesAsync(item, provider, configuration, cancellationToken);
        await searchIndex.RebuildAsync(cancellationToken);
        return MetadataPresentation.ToSummary(item);
    }

    public async Task<MediaMetadataSummary> UpdateAsync(Guid mediaId, UpdateMediaMetadataRequest request, CancellationToken cancellationToken)
    {
        var item = await database.MediaItems.Include(media => media.Metadata)!
            .ThenInclude(metadata => metadata!.Artwork)
            .Include(media => media.Metadata)!.ThenInclude(metadata => metadata!.Credits)
            .SingleOrDefaultAsync(media => media.Id == mediaId, cancellationToken)
            ?? throw NotFound("media_not_found", "The media item was not found.");
        if (item.Metadata is null)
        {
            item.Metadata = new MediaMetadata { MediaItemId = item.Id, UpdatedAt = DateTimeOffset.UtcNow };
            database.MediaMetadata.Add(item.Metadata);
        }
        var metadata = item.Metadata;
        metadata.ManualTitle = Clean(request.Title, 512);
        metadata.ManualOriginalTitle = Clean(request.OriginalTitle, 512);
        metadata.ManualOverview = Clean(request.Overview, 8192);
        metadata.ManualReleaseDate = Clean(request.ReleaseDate, 32);
        metadata.ManualRuntimeMinutes = ValidateRuntime(request.RuntimeMinutes);
        metadata.ManualRating = ValidateRating(request.Rating);
        metadata.ManualContentRating = Clean(request.ContentRating, 32);
        metadata.ManualGenresJson = request.Genres is null ? metadata.ManualGenresJson : MetadataPresentation.SerializeList(request.Genres);
        metadata.ManualStudiosJson = request.Studios is null ? metadata.ManualStudiosJson : MetadataPresentation.SerializeList(request.Studios);
        metadata.ManualCountriesJson = request.Countries is null ? metadata.ManualCountriesJson : MetadataPresentation.SerializeList(request.Countries);
        foreach (var field in request.ClearFields ?? []) ClearField(metadata, field);
        metadata.UpdatedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
        await searchIndex.RebuildAsync(cancellationToken);
        return MetadataPresentation.ToSummary(item);
    }

    public async Task<MediaMetadataSummary> ClearMatchAsync(Guid mediaId, CancellationToken cancellationToken)
    {
        var item = await database.MediaItems.Include(media => media.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
            .Include(media => media.Metadata)!.ThenInclude(metadata => metadata!.Credits)
            .SingleOrDefaultAsync(media => media.Id == mediaId, cancellationToken)
            ?? throw NotFound("media_not_found", "The media item was not found.");
        if (item.Metadata is not null)
        {
            database.MediaCredits.RemoveRange(item.Metadata.Credits);
            database.ArtworkAssets.RemoveRange(item.Metadata.Artwork);
            ClearProvider(item.Metadata);
            item.Metadata.ReviewState = MetadataReviewState.NeedsReview;
            item.Metadata.UpdatedAt = DateTimeOffset.UtcNow;
            await database.SaveChangesAsync(cancellationToken);
        }
        await searchIndex.RebuildAsync(cancellationToken);
        return MetadataPresentation.ToSummary(item);
    }

    internal async Task ApplyAsync(MediaItem item, TmdbMetadata provider, double confidence, CancellationToken cancellationToken)
    {
        if (item.Metadata is null)
        {
            item.Metadata = new MediaMetadata { MediaItemId = item.Id };
            database.MediaMetadata.Add(item.Metadata);
        }
        var metadata = item.Metadata;
        metadata.Provider = "tmdb";
        metadata.ProviderMediaId = provider.ProviderId;
        metadata.ProviderMediaType = provider.MediaType;
        metadata.MatchConfidence = confidence;
        metadata.ProviderTitle = provider.Title;
        metadata.ProviderOriginalTitle = provider.OriginalTitle;
        metadata.ProviderOverview = provider.Overview;
        metadata.ProviderReleaseDate = provider.ReleaseDate;
        metadata.ProviderRuntimeMinutes = provider.RuntimeMinutes;
        metadata.ProviderRating = provider.Rating;
        metadata.ProviderContentRating = provider.ContentRating;
        metadata.ProviderGenresJson = MetadataPresentation.SerializeList(provider.Genres);
        metadata.ProviderStudiosJson = MetadataPresentation.SerializeList(provider.Studios);
        metadata.ProviderCountriesJson = MetadataPresentation.SerializeList(provider.Countries);
        metadata.ReviewState = MetadataReviewState.Matched;
        metadata.ProviderUpdatedAt = DateTimeOffset.UtcNow;
        metadata.UpdatedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
        await database.MediaCredits.Where(credit => credit.MediaItemId == item.Id)
            .ExecuteDeleteAsync(cancellationToken);
        metadata.Credits.Clear();
        var credits = provider.Credits.Select(credit => new MediaCredit
        {
            Id = Guid.NewGuid(),
            MediaItemId = item.Id,
            ProviderPersonId = credit.ProviderId,
            Name = credit.Name,
            Department = credit.Department,
            Job = credit.Job,
            Character = credit.Character,
            SortOrder = credit.Order,
            ProfilePath = credit.ProfilePath,
        }).ToList();
        database.MediaCredits.AddRange(credits);
        metadata.Credits.AddRange(credits);
        await artworkStore.StoreAsync(database, item.Id, ArtworkKind.Poster, provider.PosterPath, cancellationToken);
        await artworkStore.StoreAsync(database, item.Id, item.Kind == MediaKind.Episode ? ArtworkKind.Still : ArtworkKind.Backdrop, provider.BackdropPath, cancellationToken);
        foreach (var profilePath in provider.Credits.Select(credit => credit.ProfilePath).Where(path => path is not null).Distinct().Take(20))
            await artworkStore.StoreAsync(database, item.Id, ArtworkKind.Profile, profilePath, cancellationToken);
        var review = await database.MetadataReviews.SingleOrDefaultAsync(value => value.MediaItemId == item.Id, cancellationToken);
        if (review is not null) review.State = MetadataReviewState.Matched;
        if (provider.Collection is not null && item.Kind == MediaKind.Movie)
            await UpsertCollectionAsync(item, provider.Collection, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
    }

    internal async Task ApplyEpisodesAsync(MediaItem series, TmdbMetadata provider, MetadataProviderConfiguration configuration, CancellationToken cancellationToken)
    {
        if (series.Kind != MediaKind.Series) return;
        var episodes = await database.MediaItems.Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
            .Where(item => item.ParentId == series.Id && item.Kind == MediaKind.Episode && item.SeasonNumber != null && item.EpisodeNumber != null)
            .ToListAsync(cancellationToken);
        foreach (var season in episodes.GroupBy(item => item.SeasonNumber!.Value))
        {
            var providerEpisodes = await tmdb.GetEpisodesAsync(configuration.Token!, configuration.Language, provider.ProviderId, season.Key, cancellationToken);
            foreach (var item in season)
            {
                var match = providerEpisodes.SingleOrDefault(value => value.EpisodeNumber == item.EpisodeNumber);
                if (match is null) continue;
                if (item.Metadata is null)
                {
                    item.Metadata = new MediaMetadata { MediaItemId = item.Id };
                    database.MediaMetadata.Add(item.Metadata);
                }
                item.Metadata.Provider = "tmdb";
                item.Metadata.ProviderMediaId = match.ProviderId;
                item.Metadata.ProviderMediaType = "episode";
                item.Metadata.MatchConfidence = 1;
                item.Metadata.ProviderTitle = match.Title;
                item.Metadata.ProviderOverview = match.Overview;
                item.Metadata.ProviderReleaseDate = match.AirDate;
                item.Metadata.ProviderRuntimeMinutes = match.RuntimeMinutes;
                item.Metadata.ProviderRating = match.Rating;
                item.Metadata.ReviewState = MetadataReviewState.Matched;
                item.Metadata.ProviderUpdatedAt = DateTimeOffset.UtcNow;
                item.Metadata.UpdatedAt = DateTimeOffset.UtcNow;
                await database.SaveChangesAsync(cancellationToken);
                await artworkStore.StoreAsync(database, item.Id, ArtworkKind.Still, match.StillPath, cancellationToken);
                await database.SaveChangesAsync(cancellationToken);
            }
        }
    }

    private async Task UpsertCollectionAsync(MediaItem item, TmdbCollectionInfo provider, CancellationToken cancellationToken)
    {
        var collection = await database.MediaCollections.Include(value => value.Members).SingleOrDefaultAsync(
            value => value.Provider == "tmdb" && value.ProviderCollectionId == provider.ProviderId, cancellationToken);
        if (collection is null)
        {
            collection = new MediaCollectionRecord { Id = Guid.NewGuid(), Name = provider.Name, Provider = "tmdb", ProviderCollectionId = provider.ProviderId, CreatedAt = DateTimeOffset.UtcNow };
            database.MediaCollections.Add(collection);
        }
        collection.Name = provider.Name;
        collection.UpdatedAt = DateTimeOffset.UtcNow;
        if (!collection.Members.Any(member => member.MediaItemId == item.Id))
            collection.Members.Add(new MediaCollectionMember { CollectionId = collection.Id, MediaItemId = item.Id, SortOrder = collection.Members.Count });
    }

    private MetadataProviderConfiguration RequireEnabled()
    {
        var configuration = settings.Load();
        if (!configuration.Enabled || configuration.Token is null)
            throw new MetadataException("metadata_provider_disabled", "Enable TMDB and enter a token first.", StatusCodes.Status409Conflict);
        return configuration;
    }

    private async Task<MediaItem> RequireMatchableItemAsync(Guid id, CancellationToken cancellationToken) =>
        await database.MediaItems.Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Credits)
            .Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
            .SingleOrDefaultAsync(item => item.Id == id && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series), cancellationToken)
            ?? throw NotFound("media_not_found", "A matchable movie or series was not found.");

    internal static MetadataJobSummary ToSummary(MetadataJob job) => new(job.Id, job.LibraryRootId, job.MediaItemId, job.State, job.ItemsTotal, job.ItemsProcessed, job.ItemsMatched, job.ItemsNeedingReview, job.ItemsFailed, job.Error, job.CreatedAt, job.StartedAt, job.CompletedAt, job.Mode, job.Attempt);

    private static MetadataReviewSummary ToReview(MetadataReview review) => new(
        review.Id, review.MediaItemId, review.MediaItem.OverrideTitle ?? review.MediaItem.DetectedTitle,
        review.Reason, review.State,
        JsonSerializer.Deserialize<List<MetadataCandidateSummary>>(review.CandidatesJson, JsonOptions) ?? [], review.UpdatedAt);

    private static MetadataException NotFound(string code, string message) => new(code, message, StatusCodes.Status404NotFound);
    private static string? Clean(string? value, int max) => string.IsNullOrWhiteSpace(value) ? null : value.Trim().Length <= max ? value.Trim() : throw new MetadataException("invalid_metadata", "A metadata value is too long.", StatusCodes.Status400BadRequest);
    private static int? ValidateRuntime(int? value) => value is null or >= 0 and <= 14400 ? value : throw new MetadataException("invalid_metadata", "Runtime must be between 0 and 14400 minutes.", StatusCodes.Status400BadRequest);
    private static double? ValidateRating(double? value) => value is null or >= 0 and <= 10 ? value : throw new MetadataException("invalid_metadata", "Rating must be between 0 and 10.", StatusCodes.Status400BadRequest);
    private static void ClearField(MediaMetadata metadata, string field)
    {
        switch (field.Trim().ToLowerInvariant())
        {
            case "title": metadata.ManualTitle = null; break;
            case "originaltitle": metadata.ManualOriginalTitle = null; break;
            case "overview": metadata.ManualOverview = null; break;
            case "releasedate": metadata.ManualReleaseDate = null; break;
            case "runtimeminutes": metadata.ManualRuntimeMinutes = null; break;
            case "rating": metadata.ManualRating = null; break;
            case "contentrating": metadata.ManualContentRating = null; break;
            case "genres": metadata.ManualGenresJson = null; break;
            case "studios": metadata.ManualStudiosJson = null; break;
            case "countries": metadata.ManualCountriesJson = null; break;
            default: throw new MetadataException("invalid_metadata_field", "An unknown metadata field was requested.", StatusCodes.Status400BadRequest);
        }
    }
    private static void ClearProvider(MediaMetadata metadata)
    {
        metadata.Provider = metadata.ProviderMediaId = metadata.ProviderMediaType = null;
        metadata.MatchConfidence = null;
        metadata.ProviderTitle = metadata.ProviderOriginalTitle = metadata.ProviderOverview = metadata.ProviderReleaseDate = metadata.ProviderContentRating = null;
        metadata.ProviderRuntimeMinutes = null; metadata.ProviderRating = null;
        metadata.ProviderGenresJson = metadata.ProviderStudiosJson = metadata.ProviderCountriesJson = "[]";
        metadata.ProviderUpdatedAt = null;
    }
}
