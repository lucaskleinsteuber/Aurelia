using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

public enum LibrarySection { Home, Movies, Shows, Search }

/// <summary>A titled shelf on Home.</summary>
public sealed record HomeRow(string Title, IReadOnlyList<CatalogItemSummary> Items, bool Landscape = false);

/// <summary>What to play: the title, the episodes that follow it, and the series whose track choices apply.</summary>
public sealed record PlaybackRequest(CatalogItemSummary Target, IReadOnlyList<CatalogItemSummary> Queue, Guid? SeriesId);

/// <summary>
/// The library the screens show for one profile: Home shelves, all movies and shows, search and
/// a detail page. Loading never blocks the window, and every failure becomes a readable message.
/// </summary>
public sealed class LibraryModel : INotifyPropertyChanged, IDisposable
{
    public const int PageSize = 120;
    private readonly ILibraryApi api;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private CancellationTokenSource? sectionWork;
    private CancellationTokenSource? searchWork;
    private CancellationTokenSource? detailWork;

    public LibraryModel(ILibraryApi api, Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        this.api = api;
        this.delay = delay ?? Task.Delay;
        MovieBrowse.Changed += () => _ = ReloadAsync(MovieBrowse);
        ShowBrowse.Changed += () => _ = ReloadAsync(ShowBrowse);
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<PlaybackRequest>? PlayRequested;

    public ILibraryApi Api => api;
    /// <summary>Management for the owner and administrators; null for profiles that only watch.</summary>
    public ManagementAccess? Management { get; init; }
    public bool CanManage => Management is not null;
    /// <summary>Raised to edit the open title's details; the window shows the editor.</summary>
    public event Action<Guid>? EditRequested;
    public string RemoveQuestion => Detail is null ? "" : $"Remove {Detail.Item.Title}?";
    public const string RemoveExplanation =
        "Aurelia metadata, images, favorites and playback history for this title and its associated content will be removed for all " +
        "users. Video files are never changed. Future scans will keep this source excluded.";
    public LibrarySection Section { get; private set => Set(ref field, value, nameof(Section), SectionProperties); } = LibrarySection.Home;
    public bool IsLoading { get; private set => Set(ref field, value); }
    public string? Error { get; private set => Set(ref field, value, nameof(Error), [nameof(HasError)]); }
    public bool HasError => Error is not null;
    public CatalogItemSummary? Hero { get; private set => Set(ref field, value, nameof(Hero), [nameof(HasHero), nameof(HeroEyebrow)]); }
    public bool HasHero => Hero is not null;
    public string HeroEyebrow => Hero is null ? "" : Eyebrow(Hero);
    public IReadOnlyList<HomeRow> Rows { get; private set => Set(ref field, value, nameof(Rows), [nameof(IsHomeEmpty)]); } = [];
    public bool IsHomeEmpty => Rows.Count == 0 && Hero is null && !IsLoading;
    public CatalogBrowse MovieBrowse { get; } = new(MediaKind.Movie);
    public CatalogBrowse ShowBrowse { get; } = new(MediaKind.Series);
    public ObservableCollection<CatalogItemSummary> Movies => MovieBrowse.Items;
    public ObservableCollection<CatalogItemSummary> Shows => ShowBrowse.Items;
    public string SearchText { get; set { if (Set(ref field, value)) _ = SearchSoonAsync(); } } = "";
    public IReadOnlyList<CatalogItemSummary> SearchResults { get; private set => Set(ref field, value, nameof(SearchResults), [nameof(ShowsNoResults)]); } = [];
    public bool ShowsNoResults => SearchText.Trim().Length > 0 && SearchResults.Count == 0 && !IsLoading;

    public CatalogDetailPresentation? Detail { get; private set => Set(ref field, value, nameof(Detail), DetailProperties); }
    public PlaybackPlanResponse? DetailPlan { get; private set => Set(ref field, value, nameof(DetailPlan), [nameof(PlayLabel), nameof(PlayHint)]); }
    public SeasonPresentation? SelectedSeason
    {
        get;
        set
        {
            if (Set(ref field, value, nameof(SelectedSeason), [nameof(Episodes)])) _ = LoadSeasonWatchAsync();
        }
    }
    public bool ShowsDetail => Detail is not null;
    public bool ShowsSections => Detail is null;
    public bool IsSeries => Detail?.Item.Kind == MediaKind.Series;
    public IReadOnlyList<SeasonPresentation> Seasons => Detail?.Seasons.Where(season => season.Episodes.Count > 0).ToList() ?? [];
    public IReadOnlyList<EpisodePresentation> Episodes => SelectedSeason?.Episodes ?? [];
    public IReadOnlyList<SupplementPresentation> Extras =>
        (Detail?.Supplements ?? []).Concat(Detail?.Seasons.SelectMany(season => season.Supplements) ?? []).ToList();
    public bool HasExtras => Extras.Count > 0;
    public string DetailMeta => Detail is null ? "" : Meta(Detail);
    public string PlayLabel => DetailPlan?.Action switch
    {
        PlaybackPlanAction.Resume => "Resume",
        PlaybackPlanAction.PlayAgain => "Play Again",
        _ => "Play",
    };
    public string PlayHint => DetailPlan?.Target is { Kind: MediaKind.Episode } episode ? EpisodeLabel(episode) + " · " + episode.Title : "";
    public bool IsFavorite => Detail?.Item.IsFavorite == true;
    public string FavoriteLabel => IsFavorite ? "Remove from Favorites" : "Add to Favorites";
    /// <summary>Whether the open title (for a show: all of it) counts as watched.</summary>
    public WatchStateResponse? DetailWatch { get; private set => Set(ref field, value, nameof(DetailWatch), [nameof(WatchedLabel)]); }
    public string WatchedLabel => DetailWatch?.WatchState == CatalogWatchState.Completed ? "Mark as Unwatched" : "Mark as Watched";
    public WatchStateResponse? SeasonWatch { get; private set => Set(ref field, value, nameof(SeasonWatch), [nameof(SeasonWatchedLabel)]); }
    public string SeasonWatchedLabel => SeasonWatch?.WatchState == CatalogWatchState.Completed ? "Mark Season as Unwatched" : "Mark Season as Watched";

    public bool ShowsHome => Section == LibrarySection.Home;
    public bool ShowsMovies => Section == LibrarySection.Movies;
    public bool ShowsShows => Section == LibrarySection.Shows;
    public bool ShowsSearch => Section == LibrarySection.Search;

    private static readonly string[] SectionProperties = [nameof(ShowsHome), nameof(ShowsMovies), nameof(ShowsShows), nameof(ShowsSearch)];
    private static readonly string[] DetailProperties =
        [nameof(ShowsDetail), nameof(ShowsSections), nameof(IsSeries), nameof(Seasons), nameof(Extras), nameof(HasExtras),
         nameof(DetailMeta), nameof(IsFavorite), nameof(FavoriteLabel), nameof(RemoveQuestion)];

    public Task ShowAsync(LibrarySection section)
    {
        CloseDetail();
        Section = section;
        return section switch
        {
            LibrarySection.Home => LoadHomeAsync(),
            LibrarySection.Movies when MovieBrowse.Total < 0 => LoadMoreAsync(MediaKind.Movie),
            LibrarySection.Shows when ShowBrowse.Total < 0 => LoadMoreAsync(MediaKind.Series),
            _ => Task.CompletedTask,
        };
    }

    public Task LoadHomeAsync() => RunSectionAsync(async token =>
    {
        var home = await api.HomeAsync(token);
        Hero = home.Recommendation ?? FirstOf(home.ContinueWatching) ?? FirstOf(home.RecentlyAdded);
        var rows = new List<HomeRow>();
        if (home.ContinueWatching.Count > 0) rows.Add(new HomeRow("Continue Watching", home.ContinueWatching, Landscape: true));
        if (home.RecentlyAdded.Count > 0) rows.Add(new HomeRow("Recently Added", home.RecentlyAdded));
        if (home.Favorites.Count > 0) rows.Add(new HomeRow("Favorites", home.Favorites));
        rows.AddRange(home.Collections.Where(collection => collection.Items.Count > 0)
            .Select(collection => new HomeRow(collection.Name, collection.Items)));
        Rows = rows;
    });

    /// <summary>Loads the next page of movies or shows; the grid asks for more near its end.</summary>
    public Task LoadMoreAsync(MediaKind kind)
    {
        var browse = kind == MediaKind.Movie ? MovieBrowse : ShowBrowse;
        if (IsLoading || (browse.Total >= 0 && browse.Items.Count >= browse.Total)) return Task.CompletedTask;
        var filter = browse.Filter;
        return RunSectionAsync(async token =>
        {
            var page = await api.BrowseAsync(kind, filter, browse.Items.Count, PageSize, token);
            // A page for sorting or filters that changed meanwhile belongs to nobody.
            if (browse.Filter == filter) browse.Add(page);
        }, cancelPrevious: false);
    }

    /// <summary>New sorting or filters: the grid starts again from its first page.</summary>
    private Task ReloadAsync(CatalogBrowse browse)
    {
        browse.Reset();
        return RunSectionAsync(async token =>
        {
            var filter = browse.Filter;
            var page = await api.BrowseAsync(browse.Kind, filter, 0, PageSize, token);
            if (browse.Filter == filter && browse.Items.Count == 0) browse.Add(page);
        });
    }

    /// <summary>Marks the open movie or the whole show as watched, or not watched again.</summary>
    public Task ToggleWatchedAsync() => Detail is not { } detail
        ? Task.CompletedTask
        : ChangeWatchedAsync(detail.Item.Id, detail.Item.Kind == MediaKind.Series ? WatchStateScope.Series : WatchStateScope.Title, null,
            DetailWatch);

    public Task ToggleSeasonWatchedAsync() => Detail is { } detail && SelectedSeason is { } season
        ? ChangeWatchedAsync(detail.Item.Id, WatchStateScope.Season, season.Number, SeasonWatch)
        : Task.CompletedTask;

    /// <summary>One episode, from its menu: watched when it was not finished, otherwise unwatched again.</summary>
    public Task ToggleEpisodeWatchedAsync(EpisodePresentation episode) =>
        ChangeWatchedAsync(episode.Item.Id, WatchStateScope.Title, null, null);

    private async Task ChangeWatchedAsync(Guid id, WatchStateScope scope, int? season, WatchStateResponse? known)
    {
        Error = null;
        try
        {
            var state = known ?? await api.WatchStateAsync(id, scope, season, CancellationToken.None);
            var watched = state.WatchState != CatalogWatchState.Completed;
            await api.SetWatchedAsync(id, watched, scope, season, state.StateToken, CancellationToken.None);
            await RefreshDetailAsync();
        }
        catch (AureliaApiException error)
        {
            Error = error.Code == "library_state_conflict" ? "This title changed on another device. Try again." : error.Message;
            await RefreshDetailAsync();
        }
    }

    /// <summary>Loads the open page again, keeping the chosen season.</summary>
    private async Task RefreshDetailAsync()
    {
        if (Detail is not { } detail) return;
        var season = SelectedSeason?.Number;
        await OpenDetailAsync(detail.Item.Id);
        if (season is { } number && Seasons.FirstOrDefault(candidate => candidate.Number == number) is { } same) SelectedSeason = same;
    }

    private async Task LoadSeasonWatchAsync()
    {
        SeasonWatch = null;
        if (Detail is not { Item.Kind: MediaKind.Series } detail || SelectedSeason is not { } season) return;
        try
        {
            var state = await api.WatchStateAsync(detail.Item.Id, WatchStateScope.Season, season.Number, CancellationToken.None);
            if (Detail?.Item.Id == detail.Item.Id && SelectedSeason?.Number == season.Number) SeasonWatch = state;
        }
        catch (AureliaApiException) { }
    }

    /// <summary>Opens a title: movies and shows show their page; an episode starts playing.</summary>
    public Task OpenAsync(CatalogItemSummary item) =>
        item.Kind is MediaKind.Episode or MediaKind.Extra or MediaKind.Trailer ? PlayAsync(item.Id) : OpenDetailAsync(item.Id);

    public async Task OpenDetailAsync(Guid id)
    {
        detailWork?.Cancel();
        var source = detailWork = new CancellationTokenSource();
        IsLoading = true;
        Error = null;
        try
        {
            var detail = await api.DetailAsync(id, source.Token);
            var plan = await TryPlanAsync(id, source.Token);
            var watch = await TryWatchAsync(id, detail.Item.Kind == MediaKind.Series ? WatchStateScope.Series : WatchStateScope.Title, source.Token);
            if (source.IsCancellationRequested) return;
            Detail = detail;
            DetailPlan = plan;
            DetailWatch = watch;
            SelectedSeason = plan?.Target is { SeasonNumber: { } number }
                ? Seasons.FirstOrDefault(season => season.Number == number) ?? FirstOf(Seasons)
                : FirstOf(Seasons);
        }
        catch (AureliaApiException error)
        {
            if (!source.IsCancellationRequested) Error = error.Message;
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested)
        {
        }
        finally
        {
            if (detailWork == source) IsLoading = false;
        }
    }

    public void CloseDetail()
    {
        detailWork?.Cancel();
        Detail = null;
        DetailPlan = null;
        DetailWatch = null;
        SelectedSeason = null;
    }

    /// <summary>Plays what the server suggests for this title: the next episode, a resume, or the start.</summary>
    public async Task PlayAsync(Guid id)
    {
        Error = null;
        try
        {
            var plan = await api.PlaybackPlanAsync(id, CancellationToken.None);
            if (plan.Target is not { } target)
            {
                Error = "There is nothing to play here yet.";
                return;
            }
            if (target.Availability != MediaAvailability.Available)
            {
                Error = $"{target.Title} is unavailable. Check that its drive is connected to the server.";
                return;
            }
            PlayRequested?.Invoke(new PlaybackRequest(target, plan.Queue, plan.SeriesId));
        }
        catch (AureliaApiException error)
        {
            Error = error.Message;
        }
    }

    public Task PlayDetailAsync() => Detail is null ? Task.CompletedTask : PlayAsync(Detail.Item.Id);

    public async Task ToggleFavoriteAsync()
    {
        if (Detail is not { } detail) return;
        try
        {
            var favorite = await api.SetFavoriteAsync(detail.Item.Id, !detail.Item.IsFavorite, CancellationToken.None);
            if (Detail?.Item.Id == detail.Item.Id) Detail = detail with { Item = detail.Item with { IsFavorite = favorite } };
        }
        catch (AureliaApiException error)
        {
            Error = error.Message;
        }
    }

    /// <summary>Removes the open title from Aurelia for everyone; its files stay where they are.</summary>
    public async Task RemoveDetailAsync()
    {
        if (Management is not { } management || Detail is not { } detail) return;
        Error = null;
        IsLoading = true;
        try
        {
            await management.SendAsync<LibraryMutationResult>(HttpMethod.Delete, $"/api/v1/media/{detail.Item.Id}", null, CancellationToken.None);
            CloseDetail();
            MovieBrowse.Reset();
            ShowBrowse.Reset();
            IsLoading = false;
            await ShowAsync(Section);
            if (Section == LibrarySection.Search) SearchResults = [.. SearchResults.Where(item => item.Id != detail.Item.Id)];
        }
        catch (OperationCanceledException) { }
        catch (AureliaApiException error) { Error = error.Message; }
        finally { IsLoading = false; }
    }

    public void EditDetail()
    {
        if (Detail is { } detail && CanManage) EditRequested?.Invoke(detail.Item.Id);
    }

    /// <summary>The editor saved new details: the page and the shelves show them.</summary>
    public async Task DetailEditedAsync()
    {
        MovieBrowse.Reset();
        ShowBrowse.Reset();
        await RefreshDetailAsync();
    }

    public void Dispose()
    {
        sectionWork?.Cancel();
        searchWork?.Cancel();
        detailWork?.Cancel();
    }

    public static string EpisodeLabel(CatalogItemSummary item) =>
        item.SeasonNumber is { } season && item.EpisodeNumber is { } episode ? $"S{season} E{episode}" : "";

    /// <summary>"TV SHOW · 2008 · DRAMA": the small line above a title.</summary>
    public static string Eyebrow(CatalogItemSummary item)
    {
        var parts = new List<string>
        {
            item.Kind switch { MediaKind.Series => "TV SHOW", MediaKind.Episode => item.ParentTitle?.ToUpperInvariant() ?? "EPISODE", _ => "MOVIE" },
        };
        if (item.Year is { } year) parts.Add(year.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (item.Genres.Count > 0) parts.Add(item.Genres[0].ToUpperInvariant());
        return string.Join(" · ", parts);
    }

    private static string Meta(CatalogDetailPresentation detail)
    {
        var parts = new List<string>();
        if (detail.Metadata.Year is { } year) parts.Add(year.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (detail.Metadata.RuntimeMinutes is { } minutes && minutes > 0) parts.Add(minutes >= 60 ? $"{minutes / 60} h {minutes % 60} min" : $"{minutes} min");
        if (detail.Metadata.ContentRating is { Length: > 0 } rating) parts.Add(rating);
        if (detail.Item.Kind == MediaKind.Series)
        {
            var seasons = detail.Seasons.Count(season => season.Number > 0);
            if (seasons > 0) parts.Add(seasons == 1 ? "1 season" : $"{seasons} seasons");
        }
        if (detail.Metadata.Genres.Count > 0) parts.Add(string.Join(", ", detail.Metadata.Genres.Take(3)));
        return string.Join(" · ", parts);
    }

    private static T? FirstOf<T>(IReadOnlyList<T> items) where T : class => items.Count > 0 ? items[0] : null;

    private async Task<PlaybackPlanResponse?> TryPlanAsync(Guid id, CancellationToken token)
    {
        try { return await api.PlaybackPlanAsync(id, token); }
        catch (AureliaApiException) { return null; }
    }

    private async Task<WatchStateResponse?> TryWatchAsync(Guid id, WatchStateScope scope, CancellationToken token)
    {
        try { return await api.WatchStateAsync(id, scope, null, token); }
        catch (AureliaApiException) { return null; }
    }

    private async Task SearchSoonAsync()
    {
        searchWork?.Cancel();
        var source = searchWork = new CancellationTokenSource();
        var term = SearchText.Trim();
        if (term.Length == 0)
        {
            SearchResults = [];
            return;
        }
        try
        {
            // Wait for a pause in typing so each keystroke does not send a request.
            await delay(TimeSpan.FromMilliseconds(250), source.Token);
            IsLoading = true;
            var page = await api.SearchAsync(term, 0, 60, source.Token);
            if (!source.IsCancellationRequested) SearchResults = page.Items;
            Error = null;
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested)
        {
        }
        catch (AureliaApiException error)
        {
            if (!source.IsCancellationRequested) Error = error.Message;
        }
        finally
        {
            if (searchWork == source)
            {
                IsLoading = false;
                OnPropertyChanged(nameof(ShowsNoResults));
            }
        }
    }

    private async Task RunSectionAsync(Func<CancellationToken, Task> operation, bool cancelPrevious = true)
    {
        if (cancelPrevious) sectionWork?.Cancel();
        var source = cancelPrevious || sectionWork is null ? sectionWork = new CancellationTokenSource() : sectionWork;
        IsLoading = true;
        Error = null;
        try
        {
            await operation(source.Token);
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested)
        {
        }
        catch (AureliaApiException error)
        {
            if (!source.IsCancellationRequested) Error = error.Message;
        }
        finally
        {
            IsLoading = false;
            OnPropertyChanged(nameof(IsHomeEmpty));
        }
    }

    private void OnPropertyChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private bool Set<T>(ref T field, T value, [CallerMemberName] string name = "", string[]? also = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        if (also is not null) foreach (var other in also) OnPropertyChanged(other);
        return true;
    }
}
