namespace Aurelia.Contracts;

/// <summary>Why a title is suggested; the strongest reason is the one named.</summary>
public enum MediaSuggestionKind
{
    /// <summary>The next film of the same series of films.</summary>
    NextPart,

    /// <summary>The same film series or shared universe.</summary>
    Franchise,

    /// <summary>TMDB keywords the two titles share, such as "time travel".</summary>
    Keywords,

    /// <summary>The same director, creator or leading actors.</summary>
    People,

    /// <summary>The same kind of story.</summary>
    Genres,

    /// <summary>The same studio.</summary>
    Studio,

    /// <summary>A similar title.</summary>
    Title,
}

/// <summary>One suggestion with its reason in words, such as "Next in the Toy Story Collection".</summary>
public sealed record MediaSuggestion(CatalogItemSummary Item, MediaSuggestionKind Kind, string Reason);

/// <summary>
/// What to watch after <paramref name="MediaId"/> ("suggestions-v1"), best first: titles the
/// profile may open and has not finished. For an episode, the suggestions are for its series.
/// </summary>
public sealed record MediaSuggestionsResponse(Guid MediaId, IReadOnlyList<MediaSuggestion> Suggestions);

/// <summary>Home's "Because You Watched …" rail for one recently watched title.</summary>
public sealed record HomeSuggestionRail(Guid SourceId, string SourceTitle, IReadOnlyList<MediaSuggestion> Suggestions);
