using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Library;

/// <summary>
/// Creating or editing a collection, as in the Mac app's editor: a standard collection of chosen
/// titles in order (at least two), or a smart list with rules and a live count of matching titles.
/// Rules are sent in the server's canonical spelling.
/// </summary>
public sealed class CollectionEditorModel : ObservableObject
{
    private static readonly JsonSerializerOptions RulesJson = new(JsonSerializerDefaults.Web) { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    private readonly IReadOnlyList<CatalogItemSummary> catalog;
    private string name;
    private bool isSmart;
    private bool isShared;
    private bool matchAny;
    private string kind = "all";
    private string genres = "";
    private string yearMin = "";
    private string yearMax = "";
    private string ratingMin = "";
    private string watched = "any";
    private int addedWithinDays;
    private bool favoritesOnly;
    private string titleContains = "";

    public CollectionEditorModel(IReadOnlyList<CatalogItemSummary> catalog, CollectionSummary? existing, CatalogItemSummary? preselected, bool canShare)
    {
        this.catalog = [.. catalog.Where(item => item.Kind is MediaKind.Movie or MediaKind.Series).OrderBy(item => item.Title, StringComparer.CurrentCultureIgnoreCase)];
        Existing = existing;
        CanShare = canShare;
        name = existing?.Name ?? "";
        isSmart = existing?.IsSmart ?? false;
        isShared = existing?.IsShared ?? false;
        if (existing is not null) foreach (var item in existing.Items) Selected.Add(item);
        else if (preselected is not null) Selected.Add(preselected);
        if (existing?.RulesJson is { Length: > 0 } json) LoadRules(json);
    }

    public CollectionSummary? Existing { get; }

    public bool CanShare { get; }

    public ObservableCollection<CatalogItemSummary> Selected { get; } = [];

    public IReadOnlyList<CatalogItemSummary> Candidates => catalog;

    public string Name { get => name; set { if (SetProperty(ref name, value)) Changed(); } }

    public bool IsSmart { get => isSmart; set { if (SetProperty(ref isSmart, value)) Changed(); } }

    public bool IsShared { get => isShared; set => SetProperty(ref isShared, value); }

    public bool MatchAny { get => matchAny; set { if (SetProperty(ref matchAny, value)) Changed(); } }

    /// <summary>"all", "movie" or "series".</summary>
    public string Kind { get => kind; set { if (SetProperty(ref kind, value)) Changed(); } }

    /// <summary>Comma-separated genres.</summary>
    public string Genres { get => genres; set { if (SetProperty(ref genres, value)) Changed(); } }

    public string YearMin { get => yearMin; set { if (SetProperty(ref yearMin, value)) Changed(); } }

    public string YearMax { get => yearMax; set { if (SetProperty(ref yearMax, value)) Changed(); } }

    public string RatingMin { get => ratingMin; set { if (SetProperty(ref ratingMin, value)) Changed(); } }

    /// <summary>"any", "unwatched" or "watched".</summary>
    public string Watched { get => watched; set { if (SetProperty(ref watched, value)) Changed(); } }

    /// <summary>0 (any), 30, 90 or 365.</summary>
    public int AddedWithinDays { get => addedWithinDays; set { if (SetProperty(ref addedWithinDays, value)) Changed(); } }

    public bool FavoritesOnly { get => favoritesOnly; set { if (SetProperty(ref favoritesOnly, value)) Changed(); } }

    public string TitleContains { get => titleContains; set { if (SetProperty(ref titleContains, value)) Changed(); } }

    public bool Contains(CatalogItemSummary item) => Selected.Any(selected => selected.Id == item.Id);

    public void Toggle(CatalogItemSummary item)
    {
        var existing = Selected.FirstOrDefault(selected => selected.Id == item.Id);
        if (existing is not null) Selected.Remove(existing);
        else Selected.Add(item);
        Changed();
    }

    public void Move(CatalogItemSummary item, int by)
    {
        var index = Selected.IndexOf(item);
        var target = index + by;
        if (index < 0 || target < 0 || target >= Selected.Count) return;
        Selected.Move(index, target);
        Changed();
    }

    /// <summary>The live "Matching N titles" preview; like the Mac it leaves rating and "added within" to the server.</summary>
    public int MatchingCount
    {
        get
        {
            var rules = Rules();
            var tests = new List<Func<CatalogItemSummary, bool>>();
            if (rules.Kind is { } k) tests.Add(item => k == "movie" ? item.Kind == MediaKind.Movie : item.Kind == MediaKind.Series);
            if (rules.Genres is { Count: > 0 } wanted) tests.Add(item => item.Genres.Any(g => wanted.Contains(g, StringComparer.OrdinalIgnoreCase)));
            if (rules.YearMin is { } min) tests.Add(item => item.Year >= min);
            if (rules.YearMax is { } max) tests.Add(item => item.Year <= max);
            if (rules.WatchedState is { } state) tests.Add(item => state == "watched" ? item.WatchState == CatalogWatchState.Completed : item.WatchState != CatalogWatchState.Completed);
            if (rules.FavoritesOnly == true) tests.Add(item => item.IsFavorite);
            if (rules.TextContains is { } text) tests.Add(item => item.Title.Contains(text, StringComparison.CurrentCultureIgnoreCase));
            if (tests.Count == 0) return catalog.Count;
            return catalog.Count(item => MatchAny ? tests.Any(test => test(item)) : tests.All(test => test(item)));
        }
    }

    public string? Problem => Name.Trim().Length == 0 ? "Give the collection a name."
        : !IsSmart && Selected.Count < 2 ? "Choose at least two titles."
        : null;

    public bool CanSave => Problem is null;

    public SmartCollectionRules Rules() => new(
        Kind: Kind is "movie" or "series" ? Kind : null,
        Genres: Genres.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries) is { Length: > 0 } list ? list : null,
        YearMin: Whole(YearMin),
        YearMax: Whole(YearMax),
        RatingMin: double.TryParse(RatingMin, NumberStyles.Float, CultureInfo.InvariantCulture, out var rating) && rating is >= 0 and <= 10 ? rating : null,
        WatchedState: Watched is "unwatched" or "watched" ? Watched : null,
        AddedWithinDays: AddedWithinDays > 0 ? AddedWithinDays : null,
        FavoritesOnly: FavoritesOnly ? true : null,
        TextContains: TitleContains.Trim() is { Length: > 0 } text ? text : null,
        Combination: MatchAny ? "or" : "and");

    public SaveCollectionRequest Request() => new(
        Name.Trim(),
        IsSmart ? [] : [.. Selected.Select(item => item.Id)],
        IsSmart,
        CanShare && IsShared,
        IsSmart ? JsonSerializer.Serialize(Rules(), RulesJson) : null);

    private void LoadRules(string json)
    {
        try
        {
            var rules = JsonSerializer.Deserialize<SmartCollectionRules>(json, RulesJson);
            if (rules is null) return;
            kind = rules.Kind is "movie" or "series" ? rules.Kind : "all";
            genres = string.Join(", ", rules.Genres ?? []);
            yearMin = rules.YearMin?.ToString(CultureInfo.InvariantCulture) ?? "";
            yearMax = rules.YearMax?.ToString(CultureInfo.InvariantCulture) ?? "";
            ratingMin = rules.RatingMin?.ToString(CultureInfo.InvariantCulture) ?? "";
            watched = rules.WatchedState is "unwatched" or "watched" ? rules.WatchedState : "any";
            addedWithinDays = rules.AddedWithinDays ?? 0;
            favoritesOnly = rules.FavoritesOnly == true;
            titleContains = rules.TextContains ?? "";
            matchAny = rules.Combination == "or";
        }
        catch (JsonException)
        {
        }
    }

    private static int? Whole(string text) => int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) && value is >= 1800 and <= 3000 ? value : null;

    private void Changed()
    {
        OnPropertyChanged(nameof(MatchingCount));
        OnPropertyChanged(nameof(Problem));
        OnPropertyChanged(nameof(CanSave));
    }
}
