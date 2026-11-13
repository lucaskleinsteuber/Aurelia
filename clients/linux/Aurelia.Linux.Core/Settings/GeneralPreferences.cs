using System.Text.Json;
using Aurelia.Linux.Core.Library;

namespace Aurelia.Linux.Core.Settings;

public enum PosterSize
{
    Compact,
    Standard,
    Large,
}

/// <summary>The app's general preferences with the Mac app's defaults (Settings › General).</summary>
public sealed class GeneralPreferences(ISettingsStore store)
{
    public const string StartScreenKey = "defaultStartScreen";
    public const string PosterSizeKey = "posterSize";
    public const string ShowWatchedInRowsKey = "showWatchedInRows";
    public const string ReduceMotionKey = "reduceMotion";
    public const string HideOfflineTitlesKey = "hideOfflineTitles";
    public const string SidebarOrderKey = "sidebarItemOrder";
    public const string RestsWhenUnusedKey = "restsWhenUnused";
    public const string RestMinutesKey = "restMinutes";
    public const string ActivityPageKey = "settingsActivityPage";
    public const string WishNotificationsEnabledKey = "wishNotificationsEnabled";
    public static readonly int[] RestMinuteChoices = [5, 10, 15, 30, 60];

    public ISettingsStore Store { get; } = store;

    /// <summary>"lastScreen", "home", "library", "movies", "series", "collections", "watchlist" or "recentlyAdded".</summary>
    public string StartScreen
    {
        get => Store.Read<string>(StartScreenKey) ?? "lastScreen";
        set => Store.Write(StartScreenKey, value);
    }

    public PosterSize PosterSize
    {
        get => Store.Read<string>(PosterSizeKey) switch { "compact" => PosterSize.Compact, "large" => PosterSize.Large, _ => PosterSize.Standard };
        set => Store.Write(PosterSizeKey, value.ToString().ToLowerInvariant());
    }

    /// <summary>Poster width in pixels for the chosen size: 140, 180 or 220.</summary>
    public double PosterWidth => PosterSize switch { PosterSize.Compact => 140, PosterSize.Large => 220, _ => 180 };

    public bool ShowWatchedInRows
    {
        get => Store.Read<bool?>(ShowWatchedInRowsKey) ?? true;
        set => Store.Write(ShowWatchedInRowsKey, value);
    }

    public bool ReduceMotion
    {
        get => Store.Read<bool?>(ReduceMotionKey) ?? false;
        set => Store.Write(ReduceMotionKey, value);
    }

    public bool HideOfflineTitles
    {
        get => Store.Read<bool?>(HideOfflineTitlesKey) ?? false;
        set => Store.Write(HideOfflineTitlesKey, value);
    }

    /// <summary>"Let the Server Rest When Unused" (Settings › General), on by default as on the Mac.</summary>
    public bool RestsWhenUnused
    {
        get => Store.Read<bool?>(RestsWhenUnusedKey) ?? true;
        set => Store.Write(RestsWhenUnusedKey, value);
    }

    public int RestMinutes
    {
        get => Store.Read<int?>(RestMinutesKey) is { } minutes && RestMinuteChoices.Contains(minutes) ? minutes : 15;
        set => Store.Write(RestMinutesKey, RestMinuteChoices.Contains(value) ? value : 15);
    }

    /// <summary>"statistics" or "history" in Settings › Activity.</summary>
    public string ActivityPage
    {
        get => Store.Read<string>(ActivityPageKey) == "history" ? "history" : "statistics";
        set => Store.Write(ActivityPageKey, value == "history" ? "history" : "statistics");
    }

    public bool WishNotificationsEnabled
    {
        get => Store.Read<bool?>(WishNotificationsEnabledKey) ?? true;
        set => Store.Write(WishNotificationsEnabledKey, value);
    }

    /// <summary>
    /// Whether Aurelia lets go of its server now (Mac: AureliaRest): only for a server on another
    /// computer, while nothing plays and nobody used Aurelia for the chosen minutes.
    /// </summary>
    public static bool ShouldRest(bool enabled, int minutes, TimeSpan withoutUse, bool playing, bool connectedElsewhere) =>
        enabled && connectedElsewhere && !playing && withoutUse >= TimeSpan.FromMinutes(minutes);

    /// <summary>The last page shown, per server and profile.</summary>
    public LibraryDestination? LastDestination(Guid serverId, Guid userId) =>
        LibraryDestinations.FromIdentifier(Store.Read<string>($"libraryDestination.{serverId}.{userId}"));

    public void SaveLastDestination(Guid serverId, Guid userId, LibraryDestination destination) =>
        Store.Write($"libraryDestination.{serverId}.{userId}", destination.Identifier());

    /// <summary>A page's filters and sort, per server, profile and page; never the search text.</summary>
    public BrowseQuery BrowseQuery(Guid serverId, Guid userId, BrowseSection section)
    {
        try
        {
            return (Store.Read<BrowseQuery>($"libraryBrowse.{serverId}.{userId}.{section}") ?? Library.BrowseQuery.DefaultFor(section)).ConstrainedTo(section);
        }
        catch (JsonException)
        {
            return Library.BrowseQuery.DefaultFor(section);
        }
    }

    public void SaveBrowseQuery(Guid serverId, Guid userId, BrowseSection section, BrowseQuery query) =>
        Store.Write($"libraryBrowse.{serverId}.{userId}.{section}", query.ConstrainedTo(section));

    public SidebarLayout Sidebar()
    {
        var order = SidebarLayout.ParseOrder(Store.Read<string>(SidebarOrderKey));
        var hidden = SidebarLayout.DefaultOrder
            .Where(d => !(Store.Read<bool?>("sidebarShow." + d.Identifier()) ?? !SidebarLayout.HiddenByDefault.Contains(d)))
            .ToHashSet();
        return new SidebarLayout(order, hidden);
    }

    public void SaveSidebar(SidebarLayout layout)
    {
        Store.Write(SidebarOrderKey, SidebarLayout.FormatOrder(layout.Order));
        foreach (var destination in SidebarLayout.DefaultOrder) Store.Write("sidebarShow." + destination.Identifier(), !layout.Hidden.Contains(destination));
    }

    public void ResetSidebar()
    {
        Store.Remove(SidebarOrderKey);
        foreach (var destination in SidebarLayout.DefaultOrder) Store.Remove("sidebarShow." + destination.Identifier());
    }
}
