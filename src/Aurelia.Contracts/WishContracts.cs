namespace Aurelia.Contracts;

/// <summary>Lifecycle state of a family wish.</summary>
public enum WishState
{
    Open,
    Fulfilled,
    Declined,
}

/// <summary>Another profile supporting an open wish ("Me Too").</summary>
public sealed record WishSupportPerson(
    Guid UserId,
    string Name);

/// <summary>Suggested library title matching a free-text wish (shown only to administrators).</summary>
public sealed record WishFulfillmentSuggestion(
    Guid MediaId,
    string Title,
    int? Year,
    MediaKind Kind);

/// <summary>A single family wish as returned to a profile.</summary>
public sealed record WishSummary(
    Guid Id,
    Guid UserId,
    string UserName,
    MediaKind Kind,
    string? Provider,
    string? ProviderMediaId,
    string Title,
    int? Year,
    string? Overview,
    string? PosterPath,
    string? PosterUrl,
    string? AgeRating,
    int? MinimumAge,
    string? Note,
    WishState State,
    Guid? ResolvedByUserId,
    string? ResolvedByUserName,
    string? ResolutionNote,
    Guid? FulfilledMediaItemId,
    DateTimeOffset CreatedAt,
    DateTimeOffset? ResolvedAt,
    DateTimeOffset? SeenByWisherAt,
    bool CanSupport,
    bool SupportedByCaller,
    IReadOnlyList<WishSupportPerson> Supporters,
    IReadOnlyList<WishFulfillmentSuggestion> Suggestions);

/// <summary>The visible family wish list and notification badge counts.</summary>
public sealed record WishListResponse(
    IReadOnlyList<WishSummary> Wishes,
    int OpenCount,
    int NewlyFulfilledCount,
    bool ProviderEnabled);

/// <summary>Badge counts used for notifications without loading the full list.</summary>
public sealed record WishSummaryResponse(
    int OpenCount,
    int NewlyFulfilledCount);

/// <summary>Search result when looking up a movie or series to wish.</summary>
public sealed record WishSearchHit(
    string Provider,
    string ProviderMediaId,
    MediaKind Kind,
    string Title,
    int? Year,
    string? Overview,
    string? PosterPath,
    string? PosterUrl,
    bool AlreadyInLibrary,
    Guid? ExistingMediaId,
    bool AlreadyWished,
    Guid? ExistingWishId,
    bool SupportedByCaller);

/// <summary>Search results for a wish query.</summary>
public sealed record WishSearchResponse(
    IReadOnlyList<WishSearchHit> Results,
    bool ProviderEnabled);

/// <summary>Creates a TMDB or free-text wish (or adds "Me Too" support to an open TMDB wish).</summary>
public sealed record CreateWishRequest(
    MediaKind Kind,
    string Title,
    int? Year = null,
    string? Provider = null,
    string? ProviderMediaId = null,
    string? Overview = null,
    string? PosterPath = null,
    string? Note = null);

/// <summary>Result of creating or supporting an existing open wish.</summary>
public sealed record CreateWishResponse(
    WishSummary Wish,
    bool MergedIntoExistingSupport);

/// <summary>Conflict payload when a wished title is already in the library.</summary>
public sealed record WishAlreadyInLibraryProblem(
    string Code,
    string Message,
    Guid MediaId,
    string Title,
    MediaKind Kind);

/// <summary>Updates "Me Too" support on an open wish.</summary>
public sealed record SetWishSupportRequest(bool Supported);

/// <summary>Administrator resolution change for a wish.</summary>
public sealed record UpdateWishStateRequest(
    WishState State,
    string? ResolutionNote = null,
    Guid? FulfilledMediaItemId = null);

/// <summary>Returned when a player reports that a sleep timer ended.</summary>
public sealed record SleepTimerEndedResponse(
    string PowerMode,
    bool AfterSleepTimer,
    int Minutes);
