using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Library;

/// <summary>An ordered member entry in a Box Set draft (movie, series, season, or episode).</summary>
public sealed record CollectionMemberEntry(Guid MediaId, int? SeasonNumber, string Title, MediaKind Kind)
{
    public string TypeLabel => SeasonNumber is { } s
        ? (s == 0 ? "Specials (Season 0)" : $"Season {s}")
        : Kind switch
        {
            MediaKind.Movie => "Movie",
            MediaKind.Series => "TV Show",
            MediaKind.Episode => "Episode",
            _ => Kind.ToString(),
        };
}

/// <summary>
/// Creating or editing a collection/box set: custom metadata, artwork, sort order, members (movies,
/// series, seasons, or episodes), or a rule-based smart list.
/// </summary>
public sealed class CollectionEditorModel : ObservableObject
{
    private static readonly JsonSerializerOptions RulesJson = new(JsonSerializerDefaults.Web) { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    private readonly IReadOnlyList<CatalogItemSummary> catalog;
    private string name;
    private string overview;
    private string sortMode;
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
    private CollectionArtworkDraft? posterDraft;
    private CollectionArtworkDraft? backdropDraft;
    private bool removePoster;
    private bool removeBackdrop;

    public CollectionEditorModel(IReadOnlyList<CatalogItemSummary> catalog, CollectionSummary? existing, CatalogItemSummary? preselected, bool canShare, int? preselectedSeasonNumber = null)
    {
        this.catalog = [.. catalog.Where(item => item.Kind is MediaKind.Movie or MediaKind.Series).OrderBy(item => item.Title, StringComparer.CurrentCultureIgnoreCase)];
        Existing = existing;
        CanShare = canShare;
        name = existing?.Name ?? "";
        overview = existing?.Overview ?? "";
        isSmart = existing?.IsSmart ?? false;
        sortMode = existing?.SortMode ?? (isSmart ? "release" : "custom");
        isShared = existing?.IsShared ?? false;
        if (existing is not null)
        {
            foreach (var item in existing.Items)
            {
                AddEntry(item.Id, null, item.Title, item.Kind, item);
            }
        }
        else if (preselected is not null)
        {
            var title = preselectedSeasonNumber is { } s
                ? $"{preselected.Title} · {(s == 0 ? "Specials" : $"Season {s}")}"
                : preselected.Title;
            AddEntry(preselected.Id, preselectedSeasonNumber, title, preselected.Kind, preselected);
        }
        if (existing?.RulesJson is { Length: > 0 } json) LoadRules(json);
    }

    public CollectionSummary? Existing { get; }

    public bool CanShare { get; }

    public ObservableCollection<CatalogItemSummary> Selected { get; } = [];

    public ObservableCollection<CollectionMemberEntry> SelectedMembers { get; } = [];

    public IReadOnlyList<CatalogItemSummary> Candidates => catalog;

    public string Name { get => name; set { if (SetProperty(ref name, value)) Changed(); } }

    public string Overview { get => overview; set => SetProperty(ref overview, value); }

    public string SortMode { get => sortMode; set => SetProperty(ref sortMode, value); }

    public bool IsSmart
    {
        get => isSmart;
        set
        {
            if (SetProperty(ref isSmart, value))
            {
                if (value && sortMode == "custom") SortMode = "release";
                Changed();
            }
        }
    }

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

    public CollectionArtworkDraft? PosterDraft { get => posterDraft; set { if (SetProperty(ref posterDraft, value) && value is not null) removePoster = false; } }

    public CollectionArtworkDraft? BackdropDraft { get => backdropDraft; set { if (SetProperty(ref backdropDraft, value) && value is not null) removeBackdrop = false; } }

    public bool RemovePoster { get => removePoster; set { if (SetProperty(ref removePoster, value) && value) posterDraft = null; } }

    public bool RemoveBackdrop { get => removeBackdrop; set { if (SetProperty(ref removeBackdrop, value) && value) backdropDraft = null; } }

    public void LoadDetail(CollectionDetail detail)
    {
        if (string.IsNullOrWhiteSpace(overview) && detail.Overview is { Length: > 0 } loadedOverview)
        {
            Overview = loadedOverview;
        }
        SortMode = detail.SortMode;
        SelectedMembers.Clear();
        Selected.Clear();
        foreach (var member in detail.Members)
        {
            AddEntry(member.MediaId, member.SeasonNumber, member.Title, member.Kind, member.Item);
        }
        Changed();
    }

    public bool Contains(CatalogItemSummary item) => ContainsMember(item.Id, null);

    public bool ContainsMember(Guid mediaId, int? seasonNumber) =>
        SelectedMembers.Any(m => m.MediaId == mediaId && m.SeasonNumber == seasonNumber);

    public void Toggle(CatalogItemSummary item) => ToggleMember(item.Id, null, item.Title, item.Kind, item);

    public void ToggleMember(Guid mediaId, int? seasonNumber, string title, MediaKind mediaKind, CatalogItemSummary? summary = null)
    {
        var index = FindMemberIndex(mediaId, seasonNumber);
        if (index >= 0)
        {
            SelectedMembers.RemoveAt(index);
            if (seasonNumber is null)
            {
                var selectedItem = Selected.FirstOrDefault(s => s.Id == mediaId);
                if (selectedItem is not null) Selected.Remove(selectedItem);
            }
        }
        else
        {
            AddEntry(mediaId, seasonNumber, title, mediaKind, summary);
        }
        Changed();
    }

    public void Move(CatalogItemSummary item, int by)
    {
        var index = FindMemberIndex(item.Id, null);
        if (index >= 0) MoveMember(index, by);
    }

    public void MoveMember(int index, int by)
    {
        var target = index + by;
        if (index < 0 || target < 0 || target >= SelectedMembers.Count) return;
        SelectedMembers.Move(index, target);
        SortMode = "custom";
        SyncLegacySelected();
        Changed();
    }

    public void RemoveMemberAt(int index)
    {
        if (index < 0 || index >= SelectedMembers.Count) return;
        SelectedMembers.RemoveAt(index);
        SyncLegacySelected();
        Changed();
    }

    private void AddEntry(Guid mediaId, int? seasonNumber, string title, MediaKind mediaKind, CatalogItemSummary? summary)
    {
        if (ContainsMember(mediaId, seasonNumber)) return;
        SelectedMembers.Add(new CollectionMemberEntry(mediaId, seasonNumber, title, mediaKind));
        if (seasonNumber is null && summary is not null && !Selected.Any(s => s.Id == mediaId)) Selected.Add(summary);
    }

    private int FindMemberIndex(Guid mediaId, int? seasonNumber)
    {
        for (var i = 0; i < SelectedMembers.Count; i++)
        {
            if (SelectedMembers[i].MediaId == mediaId && SelectedMembers[i].SeasonNumber == seasonNumber) return i;
        }
        return -1;
    }

    private void SyncLegacySelected()
    {
        var existingById = Selected.ToDictionary(s => s.Id);
        Selected.Clear();
        foreach (var member in SelectedMembers.Where(m => m.SeasonNumber is null))
        {
            if (existingById.TryGetValue(member.MediaId, out var s)) Selected.Add(s);
            else if (catalog.FirstOrDefault(c => c.Id == member.MediaId) is { } found) Selected.Add(found);
        }
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

    public string? Problem => Name.Trim().Length == 0 ? "Give the collection a name." : null;

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

    public SaveCollectionRequest Request()
    {
        var trimmedOverview = Overview.Trim();
        var effectiveSort = IsSmart && SortMode == "custom" ? "release" : SortMode;
        return new SaveCollectionRequest(
            Name.Trim(),
            IsSmart ? [] : [.. SelectedMembers.Select(m => m.MediaId)],
            IsSmart,
            CanShare && IsShared,
            IsSmart ? JsonSerializer.Serialize(Rules(), RulesJson) : null,
            Overview: trimmedOverview.Length == 0 ? "" : trimmedOverview,
            SortMode: effectiveSort,
            Members: IsSmart ? null : [.. SelectedMembers.Select(m => new CollectionMemberInput(m.MediaId, m.SeasonNumber))]);
    }

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
