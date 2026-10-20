using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>Which titles a grid shows by how far they were watched, as the Mac library's filter.</summary>
public enum WatchFilter { All, Unwatched, InProgress, Watched }

/// <summary>Sorting and filters for the Movies or TV Shows grid, sent to the server as catalog query parameters.</summary>
public sealed record CatalogFilter(CatalogSort Sort = CatalogSort.Title, bool Descending = false, WatchFilter Watch = WatchFilter.All,
    string? Genre = null, int? Year = null, bool FavoritesOnly = false)
{
    public bool HasFilters => Watch != WatchFilter.All || Genre is not null || Year is not null || FavoritesOnly;

    /// <summary>The query after kind, offset and limit, e.g. "&amp;sort=dateAdded&amp;direction=descending&amp;watchState=unplayed".</summary>
    public string Query()
    {
        var parts = new List<string>
        {
            "sort=" + Camel(Sort.ToString()),
            "direction=" + (Descending ? "descending" : "ascending"),
        };
        var watch = Watch switch
        {
            WatchFilter.Unwatched => "unplayed",
            WatchFilter.InProgress => "inProgress",
            WatchFilter.Watched => "completed",
            _ => null,
        };
        if (watch is not null) parts.Add("watchState=" + watch);
        if (Genre is { Length: > 0 } genre) parts.Add("genre=" + Uri.EscapeDataString(genre));
        if (Year is { } year)
        {
            parts.Add("yearFrom=" + year.ToString(CultureInfo.InvariantCulture));
            parts.Add("yearTo=" + year.ToString(CultureInfo.InvariantCulture));
        }
        if (FavoritesOnly) parts.Add("favorite=true");
        return string.Join("&", parts);
    }

    private static string Camel(string value) => char.ToLower(value[0], CultureInfo.InvariantCulture) + value[1..];
}

/// <summary>
/// One grid, Movies or TV Shows: the titles loaded so far, its sorting and filters, and the genres
/// and years seen in it to choose from. Changing a choice asks for a fresh first page.
/// </summary>
public sealed class CatalogBrowse(MediaKind kind) : INotifyPropertyChanged
{
    public const string AllGenres = "All Genres";
    public const string AnyYear = "Any Year";
    public static readonly IReadOnlyList<string> SortNames = ["Title", "Recently Added", "Release Year", "Last Watched"];
    public static readonly IReadOnlyList<string> WatchNames = ["All", "Unwatched", "In Progress", "Watched"];
    private readonly SortedSet<string> genres = new(StringComparer.CurrentCultureIgnoreCase);
    private readonly SortedSet<int> years = new(Comparer<int>.Create((left, right) => right.CompareTo(left)));

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>The person changed the sorting or a filter; the grid starts again from the first page.</summary>
    public event Action? Changed;

    public MediaKind Kind => kind;
    public ObservableCollection<CatalogItemSummary> Items { get; } = [];
    /// <summary>All titles that match, or -1 before the first page.</summary>
    public int Total { get; internal set => Set(ref field, value, nameof(Total), nameof(IsEmpty), nameof(CountText)); } = -1;
    public ObservableCollection<string> Genres { get; } = [AllGenres];
    public ObservableCollection<string> Years { get; } = [AnyYear];

    public int SortIndex { get; set { if (Set(ref field, Math.Clamp(value, 0, 3))) Notify(); } }
    public bool Descending { get; set { if (Set(ref field, value, nameof(Descending), nameof(DirectionText))) Notify(); } }
    public int WatchIndex { get; set { if (Set(ref field, Math.Clamp(value, 0, 3), nameof(WatchIndex), nameof(HasFilters))) Notify(); } }
    public string Genre { get; set { if (Set(ref field, value ?? AllGenres, nameof(Genre), nameof(HasFilters))) Notify(); } } = AllGenres;
    public string Year { get; set { if (Set(ref field, value ?? AnyYear, nameof(Year), nameof(HasFilters))) Notify(); } } = AnyYear;

    public string DirectionText => Descending ? "↓" : "↑";
    public bool HasFilters => Filter.HasFilters;
    public bool IsEmpty => Total == 0;
    public string CountText => Total < 0 ? "" : kind == MediaKind.Movie
        ? Total == 1 ? "1 movie" : $"{Total} movies"
        : Total == 1 ? "1 show" : $"{Total} shows";
    public string EmptyText => HasFilters
        ? kind == MediaKind.Movie ? "No movies match these filters." : "No shows match these filters."
        : kind == MediaKind.Movie ? "No movies yet." : "No TV shows yet.";

    public CatalogFilter Filter => new(
        (CatalogSort)SortIndex,
        Descending,
        (WatchFilter)WatchIndex,
        Genre == AllGenres ? null : Genre,
        int.TryParse(Year, NumberStyles.None, CultureInfo.InvariantCulture, out var year) ? year : null);

    public void ClearFilters()
    {
        if (!HasFilters) return;
        quiet = true;
        try
        {
            WatchIndex = 0;
            Genre = AllGenres;
            Year = AnyYear;
        }
        finally { quiet = false; }
        Changed?.Invoke();
    }

    /// <summary>Starts over before the first page of a new choice.</summary>
    internal void Reset()
    {
        Items.Clear();
        Total = -1;
        OnPropertyChanged(nameof(EmptyText));
    }

    /// <summary>Adds a page, and remembers its genres and years for the choices.</summary>
    internal void Add(PagedResponse<CatalogItemSummary> page)
    {
        foreach (var item in page.Items.Where(item => Items.All(existing => existing.Id != item.Id))) Items.Add(item);
        Total = page.Total;
        OnPropertyChanged(nameof(EmptyText));
        foreach (var genre in page.Items.SelectMany(item => item.Genres).Where(genre => genre.Length > 0 && genres.Add(genre)))
            Genres.Insert(1 + genres.ToList().IndexOf(genre), genre);
        foreach (var year in page.Items.Select(item => item.Year).OfType<int>().Where(years.Add))
            Years.Insert(1 + years.ToList().IndexOf(year), year.ToString(CultureInfo.InvariantCulture));
    }

    private bool quiet;

    private void Notify()
    {
        if (!quiet) Changed?.Invoke();
    }

    private void OnPropertyChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private bool Set<T>(ref T field, T value, [CallerMemberName] string name = "", params string[] also)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        foreach (var other in also) OnPropertyChanged(other);
        return true;
    }
}
