namespace Aurelia.Linux.Core;

/// <summary>
/// Which pages the sidebar shows and in what order. Like the Mac app, History and Statistics live
/// in Settings › Activity and join the sidebar only when someone turns them on.
/// </summary>
public sealed record SidebarLayout(IReadOnlyList<LibraryDestination> Order, IReadOnlySet<LibraryDestination> Hidden)
{
    public static readonly IReadOnlyList<LibraryDestination> DefaultOrder = Enum.GetValues<LibraryDestination>();

    public static readonly IReadOnlySet<LibraryDestination> HiddenByDefault =
        new HashSet<LibraryDestination> { LibraryDestination.History, LibraryDestination.Statistics };

    public static SidebarLayout Default { get; } = new(DefaultOrder, HiddenByDefault);

    /// <summary>
    /// Reads a saved comma-separated order. Unknown or repeated entries are skipped and pages the
    /// saved order does not know yet are appended, so a newer version's pages are never lost.
    /// </summary>
    public static IReadOnlyList<LibraryDestination> ParseOrder(string? saved)
    {
        var order = new List<LibraryDestination>();
        foreach (var identifier in (saved ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            if (LibraryDestinations.FromIdentifier(identifier) is { } destination && !order.Contains(destination)) order.Add(destination);
        }
        order.AddRange(DefaultOrder.Where(destination => !order.Contains(destination)));
        return order;
    }

    public static string FormatOrder(IEnumerable<LibraryDestination> order) => string.Join(',', order.Select(d => d.Identifier()));

    /// <summary>The pages shown, in order. The Watchlist and Wishes need a server that supports them.</summary>
    public IReadOnlyList<LibraryDestination> VisibleItems(bool supportsWatchlist, bool supportsWishes = false) =>
        Order.Where(d => !Hidden.Contains(d)
            && (supportsWatchlist || d != LibraryDestination.Watchlist)
            && (supportsWishes || d != LibraryDestination.Wishes)).ToList();
}
