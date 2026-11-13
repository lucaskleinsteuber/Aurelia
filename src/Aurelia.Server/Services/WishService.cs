using System.Globalization;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>Signals that a wish matches a title already in the profile's visible library.</summary>
public sealed class WishAlreadyInLibraryException(Guid mediaId, string title, MediaKind kind)
    : Exception("This title is already in your library.")
{
    public Guid MediaId { get; } = mediaId;
    public string Title { get; } = title;
    public MediaKind Kind { get; } = kind;
}

/// <summary>Manages family wishes, "Me Too" support, child age-limit filtering and auto-fulfillment.</summary>
public sealed class WishService(
    AureliaDbContext database,
    MetadataProviderSettingsStore metadataSettings,
    ITmdbClient tmdb,
    WishPosterCache posterCache,
    TimeProvider clock)
{
    private const int MaxListedWishes = 500;
    private const int MaxSuggestionsPerWish = 3;
    private const int MaxSuggestedWishes = 50;
    private const int MaxCandidatesPerWish = 50;

    public async Task<WishSummaryResponse> GetSummaryAsync(Guid callerId, CancellationToken cancellationToken)
    {
        var caller = await RequireUserAsync(callerId, cancellationToken);
        return await BuildSummaryCountsAsync(caller, cancellationToken);
    }

    public async Task<WishSearchResponse> SearchAsync(
        Guid callerId,
        string? query,
        MediaKind kind,
        CancellationToken cancellationToken)
    {
        if (kind is not (MediaKind.Movie or MediaKind.Series))
            throw new AccountException("invalid_wish_kind", "Choose movie or series.", StatusCodes.Status400BadRequest);

        var configuration = metadataSettings.Load();
        if (!configuration.Enabled || string.IsNullOrWhiteSpace(configuration.Token))
            throw new AccountException("provider_disabled", "TMDB search is currently disabled. Add your wish by title instead.", StatusCodes.Status409Conflict);

        var trimmed = (query ?? string.Empty).Trim();
        if (trimmed.Length == 0)
            return new WishSearchResponse([], true);
        if (trimmed.Length > 200)
            trimmed = trimmed[..200];

        var caller = await RequireUserAsync(callerId, cancellationToken);
        var hits = await tmdb.SearchAsync(configuration.Token, configuration.Language, kind, trimmed, year: null, cancellationToken);
        if (hits.Count == 0)
            return new WishSearchResponse([], true);

        posterCache.AllowRecent(hits.Select(hit => hit.PosterPath));

        var providerIds = hits.Select(hit => hit.ProviderMediaId).Where(id => !string.IsNullOrWhiteSpace(id)).Distinct(StringComparer.Ordinal).ToList();
        var existingLibrary = await (
            from meta in database.MediaMetadata.AsNoTracking()
            join media in database.MediaItems.AsNoTracking() on meta.MediaItemId equals media.Id
            where media.ParentId == null
                && media.Kind == kind
                && meta.Provider == "tmdb"
                && meta.ProviderMediaId != null
                && providerIds.Contains(meta.ProviderMediaId)
            select new { ProviderId = meta.ProviderMediaId!, media.Id })
            .ToListAsync(cancellationToken);

        var libraryByProviderId = existingLibrary
            .GroupBy(item => item.ProviderId, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.First().Id, StringComparer.Ordinal);

        var openWishes = await database.Wishes.AsNoTracking()
            .Include(wish => wish.Supports)
            .Where(wish => wish.State == WishState.Open
                && wish.Kind == kind
                && wish.Provider == "tmdb"
                && wish.ProviderMediaId != null
                && providerIds.Contains(wish.ProviderMediaId))
            .ToListAsync(cancellationToken);

        var visibleWishByProviderId = openWishes
            .Where(wish => CanViewWish(wish, caller))
            .GroupBy(wish => wish.ProviderMediaId!, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);

        var mapped = hits.Select(hit =>
        {
            libraryByProviderId.TryGetValue(hit.ProviderMediaId, out var mediaId);
            visibleWishByProviderId.TryGetValue(hit.ProviderMediaId, out var existingWish);
            var safePosterPath = WishPosterCache.IsSafePosterPath(hit.PosterPath) ? hit.PosterPath : null;
            return new WishSearchHit(
                "tmdb",
                hit.ProviderMediaId,
                kind,
                hit.Title,
                hit.Year,
                TrimOrNull(hit.Overview, 4096),
                safePosterPath,
                WishPosterCache.BuildPosterUrl(safePosterPath),
                AlreadyInLibrary: mediaId != Guid.Empty,
                ExistingMediaId: mediaId != Guid.Empty ? mediaId : null,
                AlreadyWished: existingWish is not null,
                ExistingWishId: existingWish?.Id,
                SupportedByCaller: existingWish is not null && (existingWish.UserId == callerId || existingWish.Supports.Any(support => support.UserId == callerId)));
        }).ToList();

        return new WishSearchResponse(mapped, true);
    }

    public async Task<WishListResponse> ListAsync(Guid callerId, WishState? filterState, CancellationToken cancellationToken)
    {
        var caller = await RequireUserAsync(callerId, cancellationToken);
        var isAdmin = IsAdmin(caller);
        var query = database.Wishes.AsNoTracking()
            .Include(wish => wish.User)
            .Include(wish => wish.ResolvedByUser)
            .Include(wish => wish.Supports)
            .ThenInclude(support => support.User)
            .AsQueryable();

        if (filterState is { } state)
            query = query.Where(wish => wish.State == state);

        var candidates = await query
            .OrderByDescending(wish => wish.CreatedAt)
            .Take(MaxListedWishes)
            .ToListAsync(cancellationToken);

        var visible = candidates
            .Where(wish => CanViewWish(wish, caller))
            .OrderBy(wish => wish.State == WishState.Open ? 0 : 1)
            .ThenByDescending(wish => wish.CreatedAt)
            .ToList();

        var suggestionsByWishId = isAdmin
            ? await LoadSuggestionsForAdminAsync(visible, cancellationToken)
            : new Dictionary<Guid, IReadOnlyList<WishFulfillmentSuggestion>>();

        var counts = await BuildSummaryCountsAsync(caller, cancellationToken);
        var configuration = metadataSettings.Load();
        var providerEnabled = configuration.Enabled && !string.IsNullOrWhiteSpace(configuration.Token);

        var items = visible
            .Select(wish => ToSummary(wish, callerId, suggestionsByWishId.GetValueOrDefault(wish.Id) ?? []))
            .ToList();

        return new WishListResponse(items, counts.OpenCount, counts.NewlyFulfilledCount, providerEnabled);
    }

    public async Task<CreateWishResponse> CreateAsync(Guid callerId, CreateWishRequest request, CancellationToken cancellationToken)
    {
        if (request.Kind is not (MediaKind.Movie or MediaKind.Series))
            throw new AccountException("invalid_wish_kind", "Choose movie or series.", StatusCodes.Status400BadRequest);

        var title = (request.Title ?? string.Empty).Trim();
        if (title.Length == 0 || title.Length > 512)
            throw new AccountException("invalid_wish_title", "Enter a title between 1 and 512 characters.", StatusCodes.Status400BadRequest);

        if (request.Year is < 1888 or > 2100)
            throw new AccountException("invalid_wish_year", "Enter a year between 1888 and 2100.", StatusCodes.Status400BadRequest);

        var note = TrimOrNull(request.Note, 1000);
        string? provider = null;
        string? providerMediaId = null;
        if (!string.IsNullOrWhiteSpace(request.Provider) || !string.IsNullOrWhiteSpace(request.ProviderMediaId))
        {
            if (!string.Equals(request.Provider?.Trim(), "tmdb", StringComparison.OrdinalIgnoreCase))
                throw new AccountException("invalid_wish_provider", "Only TMDB is supported for matched wishes.", StatusCodes.Status400BadRequest);
            var trimmedProviderId = (request.ProviderMediaId ?? string.Empty).Trim();
            if (trimmedProviderId.Length is 0 or > 64 || !trimmedProviderId.All(char.IsLetterOrDigit))
                throw new AccountException("invalid_wish_provider_id", "The provider media id is invalid.", StatusCodes.Status400BadRequest);
            provider = "tmdb";
            providerMediaId = trimmedProviderId;
        }

        var caller = await RequireUserAsync(callerId, cancellationToken);
        if (provider == "tmdb" && providerMediaId is not null)
        {
            var existingMedia = await (
                from meta in database.MediaMetadata.AsNoTracking()
                join media in database.MediaItems.AsNoTracking() on meta.MediaItemId equals media.Id
                where media.ParentId == null
                    && media.Kind == request.Kind
                    && meta.Provider == "tmdb"
                    && meta.ProviderMediaId == providerMediaId
                select new { media.Id, Title = meta.ManualTitle ?? meta.ProviderTitle ?? media.DetectedTitle, media.Kind })
                .FirstOrDefaultAsync(cancellationToken);

            if (existingMedia is not null)
                throw new WishAlreadyInLibraryException(existingMedia.Id, existingMedia.Title, existingMedia.Kind);

            var existingOpen = await database.Wishes
                .Include(wish => wish.User)
                .Include(wish => wish.ResolvedByUser)
                .Include(wish => wish.Supports)
                .ThenInclude(support => support.User)
                .FirstOrDefaultAsync(
                    wish => wish.State == WishState.Open
                        && wish.Kind == request.Kind
                        && wish.Provider == "tmdb"
                        && wish.ProviderMediaId == providerMediaId,
                    cancellationToken);

            if (existingOpen is not null)
            {
                if (IsChildAgeLimited(caller)
                    && AgeRatings.MinimumAge(existingOpen.AgeRating) is int existingMinAge
                    && existingMinAge > caller.AgeLimit!.Value)
                {
                    throw new AccountException("wish_age_restricted", "This title exceeds your profile's age limit.", StatusCodes.Status403Forbidden);
                }

                var now = clock.GetUtcNow();
                if (existingOpen.UserId != callerId && !existingOpen.Supports.Any(support => support.UserId == callerId))
                {
                    database.WishSupports.Add(new WishSupport
                    {
                        WishId = existingOpen.Id,
                        UserId = callerId,
                        CreatedAt = now,
                    });
                    await EmitUserStateChangesAsync([existingOpen.UserId, callerId], includeAdmins: true, now, cancellationToken);
                    await database.SaveChangesAsync(cancellationToken);
                }

                var reloaded = await LoadWishRequiredAsync(existingOpen.Id, cancellationToken);
                return new CreateWishResponse(ToSummary(reloaded, callerId, []), MergedIntoExistingSupport: true);
            }
        }

        var year = request.Year;
        var overview = TrimOrNull(request.Overview, 4096);
        var posterPath = WishPosterCache.IsSafePosterPath(request.PosterPath) ? request.PosterPath : null;
        string? ageRating = null;

        if (provider == "tmdb" && providerMediaId is not null)
        {
            var configuration = metadataSettings.Load();
            if (configuration.Enabled && !string.IsNullOrWhiteSpace(configuration.Token))
            {
                try
                {
                    var mediaType = request.Kind == MediaKind.Series ? "tv" : "movie";
                    var metadata = await tmdb.GetAsync(configuration.Token, configuration.Language, mediaType, providerMediaId, cancellationToken);
                    if (!string.IsNullOrWhiteSpace(metadata.Title))
                        title = metadata.Title.Trim().Length <= 512 ? metadata.Title.Trim() : metadata.Title.Trim()[..512];
                    if (ParseYear(metadata.ReleaseDate) is int parsedYear)
                        year = parsedYear;
                    if (!string.IsNullOrWhiteSpace(metadata.Overview))
                        overview = TrimOrNull(metadata.Overview, 4096);
                    if (WishPosterCache.IsSafePosterPath(metadata.PosterPath))
                        posterPath = metadata.PosterPath;
                    ageRating = TrimOrNull(metadata.ContentRating, 64);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception error) when (error is HttpRequestException or MetadataException or TaskCanceledException or InvalidDataException)
                {
                    // Fall back to the submitted search summary; ageRating remains null (hidden from other child profiles).
                }
            }
        }

        if (posterPath is not null)
            posterCache.AllowRecent([posterPath]);

        var createdNow = clock.GetUtcNow();
        var wish = new WishRecord
        {
            Id = Guid.NewGuid(),
            UserId = callerId,
            Kind = request.Kind,
            Provider = provider,
            ProviderMediaId = providerMediaId,
            Title = title,
            Year = year,
            Overview = overview,
            PosterPath = posterPath,
            AgeRating = ageRating,
            Note = note,
            State = WishState.Open,
            CreatedAt = createdNow,
        };
        database.Wishes.Add(wish);
        await EmitUserStateChangesAsync([callerId], includeAdmins: true, createdNow, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);

        var created = await LoadWishRequiredAsync(wish.Id, cancellationToken);
        return new CreateWishResponse(ToSummary(created, callerId, []), MergedIntoExistingSupport: false);
    }

    public async Task<WishSummary> SetSupportAsync(Guid callerId, Guid wishId, bool supported, CancellationToken cancellationToken)
    {
        var caller = await RequireUserAsync(callerId, cancellationToken);
        var wish = await database.Wishes
            .Include(w => w.User)
            .Include(w => w.ResolvedByUser)
            .Include(w => w.Supports)
            .ThenInclude(s => s.User)
            .FirstOrDefaultAsync(w => w.Id == wishId, cancellationToken);

        if (wish is null || !CanViewWish(wish, caller))
            throw new AccountException("wish_not_found", "Wish not found.", StatusCodes.Status404NotFound);
        if (wish.State != WishState.Open)
            throw new AccountException("wish_not_open", "Only open wishes can be supported.", StatusCodes.Status409Conflict);
        if (wish.UserId == callerId)
            throw new AccountException("cannot_support_own_wish", "You already requested this wish.", StatusCodes.Status409Conflict);

        var existingSupport = wish.Supports.FirstOrDefault(support => support.UserId == callerId);
        var now = clock.GetUtcNow();
        var changed = false;

        if (supported && existingSupport is null)
        {
            database.WishSupports.Add(new WishSupport
            {
                WishId = wish.Id,
                UserId = callerId,
                CreatedAt = now,
            });
            changed = true;
        }
        else if (!supported && existingSupport is not null)
        {
            database.WishSupports.Remove(existingSupport);
            changed = true;
        }

        if (changed)
        {
            await EmitUserStateChangesAsync([wish.UserId, callerId], includeAdmins: true, now, cancellationToken);
            await database.SaveChangesAsync(cancellationToken);
            wish = await LoadWishRequiredAsync(wish.Id, cancellationToken);
        }

        return ToSummary(wish, callerId, []);
    }

    public async Task<WishSummary> UpdateStateAsync(
        Guid adminUserId,
        Guid wishId,
        UpdateWishStateRequest request,
        CancellationToken cancellationToken)
    {
        if (!Enum.IsDefined(request.State))
            throw new AccountException("invalid_wish_state", "Invalid wish state.", StatusCodes.Status400BadRequest);

        var wish = await database.Wishes
            .Include(w => w.User)
            .Include(w => w.ResolvedByUser)
            .Include(w => w.Supports)
            .ThenInclude(s => s.User)
            .FirstOrDefaultAsync(w => w.Id == wishId, cancellationToken);

        if (wish is null)
            throw new AccountException("wish_not_found", "Wish not found.", StatusCodes.Status404NotFound);

        Guid? fulfilledMediaItemId = null;
        if (request.State == WishState.Fulfilled)
        {
            if (request.FulfilledMediaItemId is Guid requestedMediaId)
            {
                var exists = await database.MediaItems.AsNoTracking().AnyAsync(media => media.Id == requestedMediaId, cancellationToken);
                if (!exists)
                    throw new AccountException("media_not_found", "The linked media item was not found.", StatusCodes.Status404NotFound);
                fulfilledMediaItemId = requestedMediaId;
            }
            else if (wish.Provider == "tmdb" && wish.ProviderMediaId is not null)
            {
                fulfilledMediaItemId = await (
                    from meta in database.MediaMetadata.AsNoTracking()
                    join media in database.MediaItems.AsNoTracking() on meta.MediaItemId equals media.Id
                    where media.ParentId == null
                        && media.Kind == wish.Kind
                        && meta.Provider == "tmdb"
                        && meta.ProviderMediaId == wish.ProviderMediaId
                    select (Guid?)media.Id)
                    .FirstOrDefaultAsync(cancellationToken);
            }
        }

        var now = clock.GetUtcNow();
        wish.State = request.State;
        wish.ResolutionNote = TrimOrNull(request.ResolutionNote, 1000);

        if (request.State == WishState.Open)
        {
            wish.ResolvedByUserId = null;
            wish.ResolvedAt = null;
            wish.FulfilledMediaItemId = null;
            wish.SeenByWisherAt = null;
        }
        else
        {
            wish.ResolvedByUserId = adminUserId;
            wish.ResolvedAt = now;
            wish.FulfilledMediaItemId = fulfilledMediaItemId;
            wish.SeenByWisherAt = request.State == WishState.Fulfilled && adminUserId == wish.UserId ? now : null;
        }

        var recipients = new HashSet<Guid> { wish.UserId, adminUserId };
        foreach (var support in wish.Supports)
            recipients.Add(support.UserId);

        await EmitUserStateChangesAsync(recipients, includeAdmins: true, now, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);

        var updated = await LoadWishRequiredAsync(wish.Id, cancellationToken);
        var suggestions = await LoadSuggestionsForAdminAsync([updated], cancellationToken);
        return ToSummary(updated, adminUserId, suggestions.GetValueOrDefault(updated.Id) ?? []);
    }

    public async Task DeleteAsync(Guid callerId, Guid wishId, CancellationToken cancellationToken)
    {
        var caller = await RequireUserAsync(callerId, cancellationToken);
        var wish = await database.Wishes
            .Include(w => w.Supports)
            .FirstOrDefaultAsync(w => w.Id == wishId, cancellationToken);

        if (wish is null)
            throw new AccountException("wish_not_found", "Wish not found.", StatusCodes.Status404NotFound);

        var isAdmin = IsAdmin(caller);
        if (!isAdmin)
        {
            if (!CanViewWish(wish, caller))
                throw new AccountException("wish_not_found", "Wish not found.", StatusCodes.Status404NotFound);
            if (wish.UserId != callerId)
                throw new AccountException("wish_forbidden", "Only the wisher or an administrator can remove this wish.", StatusCodes.Status403Forbidden);
            if (wish.State != WishState.Open)
                throw new AccountException("wish_not_open", "Only open wishes can be withdrawn.", StatusCodes.Status409Conflict);
        }

        var recipients = new HashSet<Guid> { wish.UserId, callerId };
        foreach (var support in wish.Supports)
            recipients.Add(support.UserId);

        var now = clock.GetUtcNow();
        database.Wishes.Remove(wish);
        await EmitUserStateChangesAsync(recipients, includeAdmins: true, now, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
    }

    public async Task MarkSeenAsync(Guid callerId, CancellationToken cancellationToken)
    {
        var unseen = await database.Wishes
            .Where(wish => wish.UserId == callerId && wish.State == WishState.Fulfilled && wish.SeenByWisherAt == null)
            .ToListAsync(cancellationToken);
        if (unseen.Count == 0) return;

        var now = clock.GetUtcNow();
        foreach (var wish in unseen)
            wish.SeenByWisherAt = now;

        await EmitUserStateChangesAsync([callerId], includeAdmins: false, now, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
    }

    public async Task<int> AutoFulfillForMediaAsync(
        Guid mediaItemId,
        MediaKind kind,
        string? provider,
        string? providerMediaId,
        CancellationToken cancellationToken)
    {
        if (kind is not (MediaKind.Movie or MediaKind.Series)
            || !string.Equals(provider, "tmdb", StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrWhiteSpace(providerMediaId))
        {
            return 0;
        }

        var normalizedId = providerMediaId.Trim();
        var matching = await database.Wishes
            .Include(wish => wish.Supports)
            .Where(wish => wish.State == WishState.Open
                && wish.Kind == kind
                && wish.Provider == "tmdb"
                && wish.ProviderMediaId == normalizedId)
            .ToListAsync(cancellationToken);

        if (matching.Count == 0) return 0;

        var now = clock.GetUtcNow();
        var recipients = new HashSet<Guid>();
        foreach (var wish in matching)
        {
            wish.State = WishState.Fulfilled;
            wish.FulfilledMediaItemId = mediaItemId;
            wish.ResolvedByUserId = null;
            wish.ResolvedAt = now;
            wish.SeenByWisherAt = null;
            recipients.Add(wish.UserId);
            foreach (var support in wish.Supports)
                recipients.Add(support.UserId);
        }

        await EmitUserStateChangesAsync(recipients, includeAdmins: true, now, cancellationToken);
        await database.SaveChangesAsync(cancellationToken);
        return matching.Count;
    }

    private async Task<ServerUser> RequireUserAsync(Guid userId, CancellationToken cancellationToken) =>
        await database.Users.AsNoTracking().FirstOrDefaultAsync(user => user.Id == userId && user.IsEnabled, cancellationToken)
            ?? throw new AccountException("profile_not_found", "The active profile was not found.", StatusCodes.Status401Unauthorized);

    private async Task<WishRecord> LoadWishRequiredAsync(Guid wishId, CancellationToken cancellationToken) =>
        await database.Wishes.AsNoTracking()
            .Include(wish => wish.User)
            .Include(wish => wish.ResolvedByUser)
            .Include(wish => wish.Supports)
            .ThenInclude(support => support.User)
            .FirstAsync(wish => wish.Id == wishId, cancellationToken);

    private async Task<WishSummaryResponse> BuildSummaryCountsAsync(ServerUser caller, CancellationToken cancellationToken)
    {
        var openCount = IsAdmin(caller)
            ? await database.Wishes.CountAsync(wish => wish.State == WishState.Open, cancellationToken)
            : 0;
        var newlyFulfilledCount = await database.Wishes.CountAsync(
            wish => wish.UserId == caller.Id && wish.State == WishState.Fulfilled && wish.SeenByWisherAt == null,
            cancellationToken);
        return new WishSummaryResponse(openCount, newlyFulfilledCount);
    }

    private async Task EmitUserStateChangesAsync(
        IEnumerable<Guid> directRecipients,
        bool includeAdmins,
        DateTimeOffset timestamp,
        CancellationToken cancellationToken)
    {
        var targets = new HashSet<Guid>(directRecipients);
        if (includeAdmins)
        {
            var adminIds = await database.Users.AsNoTracking()
                .Where(user => user.IsEnabled && (user.Role == UserRole.Owner || user.Role == UserRole.Admin))
                .Select(user => user.Id)
                .ToListAsync(cancellationToken);
            foreach (var adminId in adminIds)
                targets.Add(adminId);
        }

        foreach (var target in targets)
        {
            database.SyncChanges.Add(new SyncChange
            {
                UserId = target,
                Area = SyncChangeArea.UserState,
                CreatedAt = timestamp,
            });
        }
    }

    private async Task<Dictionary<Guid, IReadOnlyList<WishFulfillmentSuggestion>>> LoadSuggestionsForAdminAsync(
        IReadOnlyList<WishRecord> wishes,
        CancellationToken cancellationToken)
    {
        var manualOpenWishes = wishes
            .Where(wish => wish.State == WishState.Open && (string.IsNullOrEmpty(wish.Provider) || string.IsNullOrEmpty(wish.ProviderMediaId)))
            .ToList();
        var result = new Dictionary<Guid, IReadOnlyList<WishFulfillmentSuggestion>>();
        if (manualOpenWishes.Count == 0) return result;

        // Only titles sharing the wish's longest word are read, never the whole library.
        var libraryItems = new List<(Guid Id, MediaKind Kind, string Title, int? ManualReleaseYear, string? ManualReleaseDate, string? ProviderReleaseDate, int? DetectedYear)>();
        var seenIds = new HashSet<Guid>();
        foreach (var wish in manualOpenWishes.Take(MaxSuggestedWishes))
        {
            var token = NormalizeTitle(wish.Title).Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .OrderByDescending(word => word.Length).FirstOrDefault();
            if (token is null || token.Length < 2) continue;
            var pattern = "%" + token.Replace("%", "", StringComparison.Ordinal).Replace("_", "", StringComparison.Ordinal) + "%";
            var rows = await (
                from media in database.MediaItems.AsNoTracking()
                join meta in database.MediaMetadata.AsNoTracking() on media.Id equals meta.MediaItemId into metas
                from meta in metas.DefaultIfEmpty()
                where media.ParentId == null
                    && media.Kind == wish.Kind
                    && media.Availability == MediaAvailability.Available
                    && (EF.Functions.Like(media.DetectedTitle, pattern)
                        || (meta != null && meta.ManualTitle != null && EF.Functions.Like(meta.ManualTitle, pattern))
                        || (meta != null && meta.ProviderTitle != null && EF.Functions.Like(meta.ProviderTitle, pattern)))
                select new
                {
                    media.Id,
                    media.Kind,
                    Title = (meta != null ? meta.ManualTitle ?? meta.ProviderTitle : null) ?? media.DetectedTitle,
                    ManualReleaseYear = meta != null ? meta.ManualReleaseYear : null,
                    ManualReleaseDate = meta != null ? meta.ManualReleaseDate : null,
                    ProviderReleaseDate = meta != null ? meta.ProviderReleaseDate : null,
                    DetectedYear = media.Year,
                })
                .Take(MaxCandidatesPerWish)
                .ToListAsync(cancellationToken);
            foreach (var row in rows.Where(row => seenIds.Add(row.Id)))
                libraryItems.Add((row.Id, row.Kind, row.Title, row.ManualReleaseYear, row.ManualReleaseDate, row.ProviderReleaseDate, row.DetectedYear));
        }

        var indexedByKindAndTitle = libraryItems
            .Select(item => (
                Key: (item.Kind, Normalized: NormalizeTitle(item.Title)),
                Suggestion: new WishFulfillmentSuggestion(
                    item.Id,
                    item.Title,
                    item.ManualReleaseYear ?? ParseYear(item.ManualReleaseDate) ?? ParseYear(item.ProviderReleaseDate) ?? item.DetectedYear,
                    item.Kind)))
            .Where(entry => entry.Key.Normalized.Length > 0)
            .GroupBy(entry => entry.Key)
            .ToDictionary(group => group.Key, group => group.Select(item => item.Suggestion).ToList());

        foreach (var wish in manualOpenWishes)
        {
            var normalized = NormalizeTitle(wish.Title);
            if (normalized.Length == 0) continue;
            if (!indexedByKindAndTitle.TryGetValue((wish.Kind, normalized), out var matches)) continue;

            var yearFiltered = matches
                .Where(candidate => wish.Year is null || candidate.Year is null || candidate.Year == wish.Year)
                .Take(MaxSuggestionsPerWish)
                .ToList();
            if (yearFiltered.Count > 0)
                result[wish.Id] = yearFiltered;
        }

        return result;
    }

    private static WishSummary ToSummary(
        WishRecord wish,
        Guid callerId,
        IReadOnlyList<WishFulfillmentSuggestion> suggestions)
    {
        var supporters = wish.Supports
            .OrderBy(support => support.CreatedAt)
            .Select(support => new WishSupportPerson(support.UserId, DisplayName(support.User)))
            .ToList();

        return new WishSummary(
            wish.Id,
            wish.UserId,
            DisplayName(wish.User),
            wish.Kind,
            wish.Provider,
            wish.ProviderMediaId,
            wish.Title,
            wish.Year,
            wish.Overview,
            wish.PosterPath,
            WishPosterCache.BuildPosterUrl(wish.PosterPath),
            wish.AgeRating,
            AgeRatings.MinimumAge(wish.AgeRating),
            wish.Note,
            wish.State,
            wish.ResolvedByUserId,
            wish.ResolvedByUser is not null ? DisplayName(wish.ResolvedByUser) : null,
            wish.ResolutionNote,
            wish.FulfilledMediaItemId,
            wish.CreatedAt,
            wish.ResolvedAt,
            wish.SeenByWisherAt,
            CanSupport: wish.State == WishState.Open && wish.UserId != callerId,
            SupportedByCaller: wish.Supports.Any(support => support.UserId == callerId),
            Supporters: supporters,
            Suggestions: suggestions);
    }

    private static bool IsAdmin(ServerUser user) => user.Role is UserRole.Owner or UserRole.Admin;

    private static bool IsChildAgeLimited(ServerUser user) => user.Role == UserRole.User && user.AgeLimit is not null;

    internal static bool CanViewWish(WishRecord wish, ServerUser caller)
    {
        if (!IsChildAgeLimited(caller)) return true;
        if (wish.UserId == caller.Id) return true;
        return AgeRatings.MinimumAge(wish.AgeRating) is int minAge && minAge <= caller.AgeLimit!.Value;
    }

    private static string DisplayName(ServerUser? user) =>
        user is null ? "Deleted profile" : string.IsNullOrWhiteSpace(user.DisplayName) ? user.Username : user.DisplayName;

    private static string? TrimOrNull(string? value, int maxLength)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return null;
        return trimmed.Length <= maxLength ? trimmed : trimmed[..maxLength];
    }

    private static int? ParseYear(string? releaseDate) =>
        releaseDate is { Length: >= 4 } && int.TryParse(releaseDate.AsSpan(0, 4), NumberStyles.None, CultureInfo.InvariantCulture, out var year)
            ? year
            : null;

    internal static string NormalizeTitle(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return string.Empty;
        var decomposed = value.Trim().ToLowerInvariant().Normalize(NormalizationForm.FormKD);
        var builder = new StringBuilder(decomposed.Length);
        var lastWasSpace = true;
        foreach (var character in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) == UnicodeCategory.NonSpacingMark) continue;
            if (char.IsLetterOrDigit(character))
            {
                builder.Append(character);
                lastWasSpace = false;
            }
            else if (!lastWasSpace)
            {
                builder.Append(' ');
                lastWasSpace = true;
            }
        }
        return builder.ToString().Trim();
    }
}
