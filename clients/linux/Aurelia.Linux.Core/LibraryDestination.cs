namespace Aurelia.Linux.Core;

/// <summary>The library pages in the sidebar, in the same order and wording as the Mac app.</summary>
public enum LibraryDestination
{
    Home,
    Library,
    Collections,
    Watchlist,
    Wishes,
    RecentlyAdded,
    TvShows,
    Movies,
    History,
    Statistics,
    Downloads,
}

public static class LibraryDestinations
{
    public static string Title(this LibraryDestination destination) => destination switch
    {
        LibraryDestination.Home => "Home",
        LibraryDestination.Library => "Library",
        LibraryDestination.Collections => "Collections",
        LibraryDestination.Watchlist => "Watchlist",
        LibraryDestination.Wishes => "Wishes",
        LibraryDestination.RecentlyAdded => "Recently Added",
        LibraryDestination.TvShows => "TV Shows",
        LibraryDestination.Movies => "Movies",
        LibraryDestination.History => "History",
        LibraryDestination.Statistics => "Statistics",
        LibraryDestination.Downloads => "Downloads",
        _ => throw new ArgumentOutOfRangeException(nameof(destination), destination, null),
    };

    /// <summary>The stable identifier used in saved preferences, matching the Mac app's raw values.</summary>
    public static string Identifier(this LibraryDestination destination) => destination switch
    {
        LibraryDestination.Home => "home",
        LibraryDestination.Library => "library",
        LibraryDestination.Collections => "collections",
        LibraryDestination.Watchlist => "watchlist",
        LibraryDestination.Wishes => "wishes",
        LibraryDestination.RecentlyAdded => "recentlyAdded",
        LibraryDestination.TvShows => "tvShows",
        LibraryDestination.Movies => "movies",
        LibraryDestination.History => "history",
        LibraryDestination.Statistics => "statistics",
        LibraryDestination.Downloads => "downloads",
        _ => throw new ArgumentOutOfRangeException(nameof(destination), destination, null),
    };

    public static LibraryDestination? FromIdentifier(string? identifier) =>
        Enum.GetValues<LibraryDestination>().Cast<LibraryDestination?>().FirstOrDefault(d => d!.Value.Identifier() == identifier);
}
