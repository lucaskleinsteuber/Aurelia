namespace Aurelia.Contracts;

public enum WatchStateScope { Title, Season, Series }
public enum PlaybackPlanAction { Play, Resume, PlayAgain }

public sealed record PlaybackPlanResponse(
    CatalogItemSummary? Target, Guid? SeriesId, IReadOnlyList<CatalogItemSummary> Queue,
    PlaybackPlanAction Action, bool ContinueWatchingEligible);

public sealed record WatchStateResponse(
    Guid MediaId, WatchStateScope Scope, int? SeasonNumber, CatalogWatchState WatchState,
    int AffectedCount, string StateToken, bool ContinueWatchingHidden);

public sealed record SetWatchStateRequest(
    bool IsWatched, WatchStateScope Scope, int? SeasonNumber, string StateToken, Guid ClientMutationId);

public sealed record SetContinueWatchingRequest(bool IsHidden, string StateToken, Guid ClientMutationId);
