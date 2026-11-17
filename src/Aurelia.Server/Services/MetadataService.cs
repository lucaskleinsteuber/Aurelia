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
    CatalogMutationGate mutations,
    MetadataJobStore jobs,
    CollectionArtworkService? collectionArtwork = null,
    WishService? wishes = null)
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
        return await jobs.StartAsync(request, cancellationToken);
    }

    public async Task<MetadataJobSummary> GetJobAsync(Guid id, CancellationToken cancellationToken) =>
        ToSummary(await database.MetadataJobs.AsNoTracking().SingleOrDefaultAsync(job => job.Id == id, cancellationToken)
            ?? throw NotFound("metadata_job_not_found", "The metadata job was not found."));
    public async Task<MetadataJobSummary> RetryJobAsync(Guid id, CancellationToken token)
    {
        RequireEnabled();
        return await jobs.RetryAsync(id, token);
    }

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
        job.NextAttemptAt = null;
        job.WaitReason = null;
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
        return MetadataPresentation.ToSummary(item);
    }

    public async Task<MediaMetadataSummary> UpdateAsync(Guid mediaId, UpdateMediaMetadataRequest request, CancellationToken cancellationToken)
    {
        using var lease = await mutations.EnterAsync(cancellationToken);
        var item = await database.MediaItems.Include(media => media.Metadata)!
            .ThenInclude(metadata => metadata!.Artwork)
            .Include(media => media.Metadata)!.ThenInclude(metadata => metadata!.Credits)
            .AsSplitQuery()
            .SingleOrDefaultAsync(media => media.Id == mediaId, cancellationToken)
            ?? throw NotFound("media_not_found", "The media item was not found.");
        if (item.Metadata is null)
        {
            item.Metadata = new MediaMetadata { MediaItemId = item.Id, UpdatedAt = DateTimeOffset.UtcNow };
            database.MediaMetadata.Add(item.Metadata);
        }
        var metadata = item.Metadata;
        if (request.Title is not null) metadata.ManualTitle = Clean(request.Title, 512);
        if (request.OriginalTitle is not null) metadata.ManualOriginalTitle = Clean(request.OriginalTitle, 512);
        if (request.Overview is not null) metadata.ManualOverview = Clean(request.Overview, 8192) ?? "";
        if (request.ReleaseDate is not null) { metadata.ManualReleaseDate = Clean(request.ReleaseDate, 32); metadata.ManualReleaseYear = null; }
        if (request.RuntimeMinutes is not null && item.Kind == MediaKind.Movie) metadata.ManualRuntimeMinutes = ValidateRuntime(request.RuntimeMinutes);
        if (request.Rating is not null) metadata.ManualRating = ValidateRating(request.Rating);
        if (request.ContentRating is not null) metadata.ManualContentRating = Clean(request.ContentRating, 32) ?? "";
        metadata.ManualGenresJson = request.Genres is null ? metadata.ManualGenresJson : MetadataPresentation.SerializeList(request.Genres);
        metadata.ManualStudiosJson = request.Studios is null ? metadata.ManualStudiosJson : MetadataPresentation.SerializeList(request.Studios);
        metadata.ManualCountriesJson = request.Countries is null ? metadata.ManualCountriesJson : MetadataPresentation.SerializeList(request.Countries);
        foreach (var field in request.ClearFields ?? []) ClearField(metadata, field);
        metadata.UpdatedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
        return MetadataPresentation.ToSummary(item);
    }

    public async Task<MediaMetadataSummary> ClearMatchAsync(Guid mediaId, CancellationToken cancellationToken)
    {
        using var lease = await mutations.EnterAsync(cancellationToken);
        var item = await database.MediaItems.Include(media => media.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
            .Include(media => media.Metadata)!.ThenInclude(metadata => metadata!.Credits)
            .AsSplitQuery()
            .SingleOrDefaultAsync(media => media.Id == mediaId, cancellationToken)
            ?? throw NotFound("media_not_found", "The media item was not found.");
        var staleFiles = await RemoveStaleAutomaticMembershipsAsync(
            mediaId, syncTmdb: true, keepTmdbId: null, syncUniverse: true, keepUniverseKeys: EmptyStringSet, cancellationToken);
        if (item.Metadata is not null)
        {
            if (!MetadataPresentation.ManualFields(item.Metadata).Contains("credits")) database.MediaCredits.RemoveRange(item.Metadata.Credits);
            database.ArtworkAssets.RemoveRange(item.Metadata.Artwork.Where(asset => !asset.IsManual));
            item.Metadata.ProviderCreditsJson = "[]";
            ClearProvider(item.Metadata);
            item.Metadata.ReviewState = MetadataReviewState.NeedsReview;
            item.Metadata.UpdatedAt = DateTimeOffset.UtcNow;
        }
        if (database.ChangeTracker.HasChanges())
        {
            await database.SaveChangesAsync(cancellationToken);
        }
        collectionArtwork?.DeleteFileNames(staleFiles);
        return MetadataPresentation.ToSummary(item);
    }

    internal async Task ApplyAsync(MediaItem item, TmdbMetadata provider, double confidence, CancellationToken cancellationToken, Func<CancellationToken, Task<bool>>? canApply = null)
    {
        using var lease = await mutations.EnterAsync(cancellationToken);
        if (canApply is not null && !await canApply(cancellationToken)) return;
        // Refresh catalog entities after waiting for an editor/deletion transaction,
        // without detaching the worker's durable job counters and completion state.
        foreach (var entry in database.ChangeTracker.Entries().Where(entry => entry.Entity is
            MediaItem or MediaMetadata or MediaCredit or ArtworkAsset or MetadataReview
            or MediaCollectionRecord or MediaCollectionMember or MediaKeywords).ToArray())
            entry.State = EntityState.Detached;
        var fresh = await database.MediaItems.Include(media => media.Metadata)!.ThenInclude(meta => meta!.Credits)
            .Include(media => media.Metadata)!.ThenInclude(meta => meta!.Artwork).AsSplitQuery()
            .SingleOrDefaultAsync(media => media.Id == item.Id, cancellationToken);
        if (fresh is null) return;
        var original = item;
        item = fresh;
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
        await StoreKeywordsAsync(item.Id, provider.Keywords, cancellationToken);
        metadata.ReviewState = MetadataReviewState.Matched;
        metadata.ProviderUpdatedAt = DateTimeOffset.UtcNow;
        metadata.UpdatedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(cancellationToken);
        var credits = ReplaceCredits(item, metadata, provider.Credits);
        await artworkStore.StoreAsync(database, item.Id, ArtworkKind.Poster, provider.PosterPath, cancellationToken, canApply);
        await artworkStore.StoreAsync(database, item.Id, item.Kind == MediaKind.Episode ? ArtworkKind.Still : ArtworkKind.Backdrop, provider.BackdropPath, cancellationToken, canApply);
        await StoreProfilesAsync(item.Id, credits, canApply, cancellationToken);
        if (canApply is not null && !await canApply(cancellationToken)) return;
        metadata.ProviderCreditsJson = JsonSerializer.Serialize(credits.Select(credit => MediaEditorService.Credit(item, credit)), MediaEditorService.Json);
        var review = await database.MetadataReviews.SingleOrDefaultAsync(value => value.MediaItemId == item.Id, cancellationToken);
        if (review is not null) review.State = MetadataReviewState.Matched;
        var universeKeys = UniverseKeysFor(item, provider.Keywords);
        var keepTmdbId = item.Kind == MediaKind.Movie ? provider.Collection?.ProviderId : null;
        var staleFiles = await RemoveStaleAutomaticMembershipsAsync(
            item.Id, syncTmdb: true, keepTmdbId, syncUniverse: true, universeKeys, cancellationToken);
        if (provider.Collection is not null && item.Kind == MediaKind.Movie)
            await UpsertCollectionAsync(item, "tmdb", provider.Collection.ProviderId, provider.Collection.Name, provider.Collection, cancellationToken);
        await JoinUniversesAsync(item, provider.Keywords, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
        collectionArtwork?.DeleteFileNames(staleFiles);
        if (wishes is not null)
            await wishes.AutoFulfillForMediaAsync(item.Id, item.Kind, metadata.Provider, metadata.ProviderMediaId, cancellationToken);
        original.Metadata = metadata;
    }

    /// <summary>A title's keywords for suggestions: at most 60, each short, so the column stays small.</summary>
    internal static string KeywordsJson(IReadOnlyList<string>? keywords) => MetadataPresentation.SerializeList(
        [.. (keywords ?? []).Select(keyword => keyword.Trim()).Where(keyword => keyword.Length is > 0 and <= 80)
            .Distinct(StringComparer.OrdinalIgnoreCase).Take(60)]);

    /// <summary>Stores a matched title's keywords again; its match, texts, credits and hand edits stay.</summary>
    internal async Task<bool> RefreshKeywordsAsync(Guid itemId, TmdbMetadata provider, CancellationToken cancellationToken)
    {
        using var lease = await mutations.EnterAsync(cancellationToken);
        if (!await database.MediaMetadata.AnyAsync(value => value.MediaItemId == itemId, cancellationToken)) return false;
        await StoreKeywordsAsync(itemId, provider.Keywords, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
        return true;
    }

    /// <summary>Keeps the title's keywords; the caller saves.</summary>
    private async Task StoreKeywordsAsync(Guid itemId, IReadOnlyList<string>? keywords, CancellationToken cancellationToken)
    {
        var row = await database.MediaKeywords.SingleOrDefaultAsync(value => value.MediaItemId == itemId, cancellationToken);
        if (row is null)
        {
            row = new MediaKeywords { MediaItemId = itemId };
            database.MediaKeywords.Add(row);
        }
        row.KeywordsJson = KeywordsJson(keywords);
        row.UpdatedAt = DateTimeOffset.UtcNow;
    }

    // Pictures of the first people only: everyone's picture for every title would fill the
    // artwork limit; the others show their initials.
    private const int ProfilePictures = 20;

    /// <summary>Replaces a title's provider credits unless someone edited them by hand.</summary>
    private List<MediaCredit> ReplaceCredits(MediaItem item, MediaMetadata metadata, IReadOnlyList<TmdbCredit> providerCredits)
    {
        var manualCredits = MetadataPresentation.ManualFields(metadata).Contains("credits");
        if (!manualCredits) { database.MediaCredits.RemoveRange(metadata.Credits); metadata.Credits.Clear(); }
        var credits = MetadataCreditDeduplicator.Deduplicate(providerCredits).Select(credit => new MediaCredit
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
        if (!manualCredits) database.MediaCredits.AddRange(credits);
        return credits;
    }

    private async Task StoreProfilesAsync(Guid itemId, IEnumerable<MediaCredit> credits, Func<CancellationToken, Task<bool>>? canApply, CancellationToken cancellationToken)
    {
        foreach (var profilePath in credits.Select(credit => credit.ProfilePath).Where(path => path is not null).Distinct().Take(ProfilePictures))
            await artworkStore.StoreAsync(database, itemId, ArtworkKind.Profile, profilePath, cancellationToken, canApply);
    }

    /// <summary>
    /// Gives an already matched title the full cast and crew from its provider again and places it in
    /// its shared universes; its match, texts, artwork and hand edits stay. False when the title is
    /// gone or its credits were edited.
    /// </summary>
    internal async Task<bool> RefreshCreditsAsync(Guid itemId, TmdbMetadata provider, CancellationToken cancellationToken)
    {
        using var lease = await mutations.EnterAsync(cancellationToken);
        var item = await database.MediaItems.Include(media => media.Metadata)!.ThenInclude(meta => meta!.Credits)
            .Include(media => media.Metadata)!.ThenInclude(meta => meta!.Artwork)
            .AsSplitQuery()
            .SingleOrDefaultAsync(media => media.Id == itemId, cancellationToken);
        if (item?.Metadata is not { } metadata) return false;
        var universeKeys = UniverseKeysFor(item, provider.Keywords);
        var staleFiles = await RemoveStaleAutomaticMembershipsAsync(
            item.Id, syncTmdb: false, keepTmdbId: null, syncUniverse: true, universeKeys, cancellationToken);
        await StoreKeywordsAsync(item.Id, provider.Keywords, cancellationToken);
        await JoinUniversesAsync(item, provider.Keywords, cancellationToken);
        if (MetadataPresentation.ManualFields(metadata).Contains("credits"))
        {
            await database.SaveChangesAsync(cancellationToken);
            collectionArtwork?.DeleteFileNames(staleFiles);
            return false;
        }
        var credits = ReplaceCredits(item, metadata, provider.Credits);
        try { await StoreProfilesAsync(item.Id, credits, null, cancellationToken); }
        catch (MetadataException exception) when (exception.Code == "artwork_limit_reached") { }
        metadata.ProviderCreditsJson = JsonSerializer.Serialize(credits.Select(credit => MediaEditorService.Credit(item, credit)), MediaEditorService.Json);
        await database.SaveChangesAsync(cancellationToken);
        collectionArtwork?.DeleteFileNames(staleFiles);
        return true;
    }

    internal async Task ApplyEpisodesAsync(MediaItem series, TmdbMetadata provider, MetadataProviderConfiguration configuration, CancellationToken cancellationToken, Func<CancellationToken, Task<bool>>? canApply = null)
    {
        if (series.Kind != MediaKind.Series) return;
        var episodes = await database.MediaItems.Include(item => item.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
            .Where(item => item.ParentId == series.Id && item.Kind == MediaKind.Episode && item.SeasonNumber != null && item.EpisodeNumber != null)
            .ToListAsync(cancellationToken);
        foreach (var season in episodes.GroupBy(item => item.SeasonNumber!.Value).OrderBy(group => group.Key))
        {
            if (canApply is not null && !await canApply(cancellationToken)) return;
            var providerEpisodes = await tmdb.GetEpisodesAsync(configuration.Token!, configuration.Language, provider.ProviderId, season.Key, cancellationToken);
            foreach (var item in season)
            {
                var match = providerEpisodes.SingleOrDefault(value => value.EpisodeNumber == item.EpisodeNumber);
                if (match is null) continue;
                using var lease = await mutations.EnterAsync(cancellationToken);
                if (canApply is not null && !await canApply(cancellationToken)) return;
                if (!await database.MediaItems.AsNoTracking().AnyAsync(value => value.Id == item.Id, cancellationToken)) continue;
                await database.Entry(item).ReloadAsync(cancellationToken);
                if (database.Entry(item).State == EntityState.Detached) continue;
                if (item.Metadata is not null) await database.Entry(item.Metadata).ReloadAsync(cancellationToken);
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
                await artworkStore.StoreAsync(database, item.Id, ArtworkKind.Still, match.StillPath, cancellationToken, canApply);
                if (canApply is not null && !await canApply(cancellationToken)) return;
                await database.SaveChangesAsync(cancellationToken);
            }
        }
    }

    private static readonly IReadOnlySet<string> EmptyStringSet = new HashSet<string>(StringComparer.Ordinal);

    private static IReadOnlySet<string> UniverseKeysFor(MediaItem item, IReadOnlyList<string>? keywords) =>
        item.Kind is MediaKind.Movie or MediaKind.Series
            ? MediaUniverses.Find(keywords).Select(entry => entry.Key).ToHashSet(StringComparer.Ordinal)
            : EmptyStringSet;

    private async Task<IReadOnlyList<string>> RemoveStaleAutomaticMembershipsAsync(
        Guid mediaId,
        bool syncTmdb,
        string? keepTmdbId,
        bool syncUniverse,
        IReadOnlySet<string> keepUniverseKeys,
        CancellationToken cancellationToken)
    {
        var memberships = await database.MediaCollectionMembers
            .Include(member => member.Collection)
            .ThenInclude(collection => collection.Members)
            .Where(member => member.MediaItemId == mediaId
                && !member.Collection.IsManual
                && !member.Collection.IsSmart
                && member.Collection.Provider != null)
            .ToListAsync(cancellationToken);
        if (memberships.Count == 0) return [];

        var emptied = new List<MediaCollectionRecord>();
        foreach (var membership in memberships)
        {
            var collection = membership.Collection;
            var remove = collection.Provider switch
            {
                "tmdb" => syncTmdb && !string.Equals(collection.ProviderCollectionId, keepTmdbId, StringComparison.Ordinal),
                MediaUniverses.Provider => syncUniverse && (collection.ProviderCollectionId is null || !keepUniverseKeys.Contains(collection.ProviderCollectionId)),
                _ => false,
            };
            if (!remove) continue;

            collection.Members.Remove(membership);
            database.MediaCollectionMembers.Remove(membership);
            collection.UpdatedAt = DateTimeOffset.UtcNow;
            collectionArtwork?.InvalidateCollectionCache(collection.Id);
            if (collection.Members.Count == 0)
            {
                emptied.Add(collection);
            }
        }

        IReadOnlyList<string> staleFiles = [];
        if (emptied.Count > 0)
        {
            if (collectionArtwork is not null)
            {
                staleFiles = await collectionArtwork.FileNamesForCollectionsAsync(
                    database, emptied.Select(c => c.Id).ToArray(), cancellationToken);
            }
            database.MediaCollections.RemoveRange(emptied);
        }
        return staleFiles;
    }

    private async Task JoinUniversesAsync(MediaItem item, IReadOnlyList<string>? keywords, CancellationToken cancellationToken)
    {
        if (item.Kind is not (MediaKind.Movie or MediaKind.Series)) return;
        foreach (var (key, name) in MediaUniverses.Find(keywords))
            await UpsertCollectionAsync(item, MediaUniverses.Provider, key, name, null, cancellationToken);
    }

    private async Task UpsertCollectionAsync(
        MediaItem item,
        string providerName,
        string providerId,
        string name,
        TmdbCollectionInfo? tmdbInfo,
        CancellationToken cancellationToken)
    {
        var collection = database.MediaCollections.Local.FirstOrDefault(value => value.Provider == providerName && value.ProviderCollectionId == providerId)
            ?? await database.MediaCollections.Include(value => value.Members).SingleOrDefaultAsync(
                value => value.Provider == providerName && value.ProviderCollectionId == providerId, cancellationToken);
        if (collection is null)
        {
            collection = new MediaCollectionRecord
            {
                Id = Guid.NewGuid(),
                Name = name,
                Provider = providerName,
                ProviderCollectionId = providerId,
                SortMode = "release",
                CreatedAt = DateTimeOffset.UtcNow,
            };
            database.MediaCollections.Add(collection);
        }
        collection.Name = name;
        collection.UpdatedAt = DateTimeOffset.UtcNow;
        if (!collection.Members.Any(member => member.MediaItemId == item.Id && member.SeasonNumber == null))
        {
            var added = new MediaCollectionMember
            {
                Id = Guid.NewGuid(),
                CollectionId = collection.Id,
                MediaItemId = item.Id,
                SortOrder = collection.Members.Count,
            };
            collection.Members.Add(added);
            database.MediaCollectionMembers.Add(added);
            collectionArtwork?.InvalidateCollectionCache(collection.Id);
        }

        if (providerName != "tmdb") return;

        var posterPath = tmdbInfo?.PosterPath;
        var backdropPath = tmdbInfo?.BackdropPath;
        var configuration = settings.Load();
        if (configuration.Enabled && !string.IsNullOrWhiteSpace(configuration.Token))
        {
            TmdbCollectionDetail? detail = null;
            try
            {
                detail = await tmdb.GetCollectionAsync(configuration.Token, configuration.Language, providerId, cancellationToken);
            }
            catch (Exception error) when (error is MetadataException or MetadataProviderException or HttpRequestException or OperationCanceledException && !cancellationToken.IsCancellationRequested)
            {
                detail = null;
            }

            if (detail is not null)
            {
                if (!string.IsNullOrWhiteSpace(detail.Name)) collection.Name = detail.Name.Trim();
                if (!collection.IsManual && !string.IsNullOrWhiteSpace(detail.Overview)) collection.Overview = detail.Overview.Trim();
                if (!string.IsNullOrWhiteSpace(detail.PosterPath)) posterPath = detail.PosterPath;
                if (!string.IsNullOrWhiteSpace(detail.BackdropPath)) backdropPath = detail.BackdropPath;
            }
        }

        if (!string.IsNullOrWhiteSpace(posterPath)) collection.ProviderPosterPath = posterPath;
        if (!string.IsNullOrWhiteSpace(backdropPath)) collection.ProviderBackdropPath = backdropPath;
        if (collectionArtwork is not null)
        {
            await collectionArtwork.StoreProviderArtworkAsync(database, collection, ArtworkKind.Poster, posterPath, cancellationToken);
            await collectionArtwork.StoreProviderArtworkAsync(database, collection, ArtworkKind.Backdrop, backdropPath, cancellationToken);
        }
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
            .AsSplitQuery()
            .SingleOrDefaultAsync(item => item.Id == id && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series), cancellationToken)
            ?? throw NotFound("media_not_found", "A matchable movie or series was not found.");

    internal static MetadataJobSummary ToSummary(MetadataJob job) => new(job.Id, job.LibraryRootId, job.MediaItemId, job.State, job.ItemsTotal, job.ItemsProcessed, job.ItemsMatched, job.ItemsNeedingReview, job.ItemsFailed, job.Error, job.CreatedAt, job.StartedAt, job.CompletedAt, job.Mode, job.Attempt, job.NextAttemptAt, job.WaitReason, job.ItemsSkipped);

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
        var fields = MetadataPresentation.ManualFields(metadata);
        fields.Remove(field.Trim().ToLowerInvariant() switch { "releasedate" => "releaseYear", "runtimeminutes" => "runtimeMinutes", "contentrating" => "fsk", "countries" => "country", var name => name });
        metadata.ManualFieldsJson = JsonSerializer.Serialize(fields, JsonOptions);
        switch (field.Trim().ToLowerInvariant())
        {
            case "title": metadata.ManualTitle = null; break;
            case "originaltitle": metadata.ManualOriginalTitle = null; break;
            case "overview": metadata.ManualOverview = null; break;
            case "releasedate": metadata.ManualReleaseDate = null; metadata.ManualReleaseYear = null; break;
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
