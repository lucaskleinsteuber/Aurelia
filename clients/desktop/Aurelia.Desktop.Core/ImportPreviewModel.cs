using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>One file or folder in the import preview, with a check box for the assignment tools.</summary>
public sealed class ImportRow(ImportPreviewItem item) : INotifyPropertyChanged
{
    public ImportPreviewItem Item => item;
    public string Title => item.Title;
    public string Path => item.RelativePath + (item.IsDirectory ? "/" : "");
    public string KindText => item.Kind switch
    {
        MediaKind.Movie => "Movie",
        MediaKind.Series => "TV Show",
        MediaKind.Episode => item.SeasonNumber is { } season && item.EpisodeNumber is { } episode
            ? string.Create(CultureInfo.InvariantCulture, $"Episode S{season} E{episode}") : "Episode",
        MediaKind.Extra => "Extra",
        MediaKind.Trailer => "Trailer",
        _ => "",
    };
    public string StatusText => item.Status switch
    {
        ImportPreviewItemStatus.Pending => "Needs review",
        ImportPreviewItemStatus.Ignored => "Ignored",
        ImportPreviewItemStatus.Error => "Problem",
        _ => "Recognized",
    };
    public bool NeedsReview => item.Status is ImportPreviewItemStatus.Pending or ImportPreviewItemStatus.Error;
    public string Reason => item.Reason;
    public bool IsSelected { get; set { if (field == value) return; field = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected))); } }
    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>
/// Import Preview for one storage location, as on the Mac: Aurelia analyzes the folders first, the
/// owner corrects what it should be (movie, show, episode, extra, trailer or ignored) and then adds it.
/// Nothing reaches the library until the preview is confirmed; files are only read.
/// </summary>
public sealed class ImportPreviewModel(Func<IAdministrationClient> client, LibrarySummary library) : INotifyPropertyChanged
{
    public static readonly IReadOnlyList<string> Filters = ["All", "Needs Review", "Ignored", "Problems"];
    public static readonly IReadOnlyList<string> Choices = ["Movie", "TV Show · Force Import", "Episode", "Extra", "Trailer", "Ignore"];
    private static readonly MediaKind?[] ChoiceKinds = [MediaKind.Movie, MediaKind.Series, MediaKind.Episode, MediaKind.Extra, MediaKind.Trailer, null];
    private readonly List<ImportRow> all = [];
    private ImportPreviewSummary? summary;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>The preview was confirmed and its scan started.</summary>
    public event Action? Confirmed;

    public string LibraryName => library.Name;
    public string LibraryPath => library.Path;
    public bool IsBusy { get; private set => Set(ref field, value); }
    public string? Error { get; private set => Set(ref field, value, nameof(Error), nameof(HasError)); }
    public bool HasError => Error is not null;
    public bool IsAnalyzed => summary is not null;
    public string CountsText => summary?.Counts is not { } counts ? "" : string.Create(CultureInfo.InvariantCulture,
        $"{counts.Files} files · {counts.Movies} movies · {counts.Series} shows · {counts.Episodes} episodes · {counts.Extras} extras · {counts.Trailers} trailers");
    public string ReviewText => summary?.Counts is not { } counts ? "" : counts.Pending == 0 ? "Nothing needs review."
        : counts.Pending == 1 ? "1 item needs review." : $"{counts.Pending} items need review.";
    public bool HasPending => summary?.Counts.Pending > 0;
    public ObservableCollection<ImportRow> Items { get; } = [];
    public int FilterIndex { get; set { if (Set(ref field, Math.Clamp(value, 0, 3))) Refilter(); } }
    public string Search { get; set { if (Set(ref field, value)) Refilter(); } } = "";

    // The assignment for the selected items.
    public int ChoiceIndex { get; set { if (Set(ref field, Math.Clamp(value, 0, Choices.Count - 1), nameof(ChoiceIndex), nameof(NeedsParent), nameof(NeedsEpisode), nameof(NeedsCategory), nameof(Parents))) ParentIndex = -1; } }
    public bool NeedsParent => ChoiceIndex is 2 or 3 or 4;
    public bool NeedsEpisode => ChoiceIndex == 2;
    public bool NeedsCategory => ChoiceIndex is 3 or 4;
    /// <summary>Movies and shows the selection can belong to, for episodes, extras and trailers.</summary>
    public IReadOnlyList<string> Parents => [.. Targets.Select(target => target.Title)];
    public int ParentIndex { get; set => Set(ref field, value); } = -1;
    public string Season { get; set => Set(ref field, value); } = "1";
    public string Episode { get; set => Set(ref field, value); } = "";
    public string Category { get; set => Set(ref field, value); } = "";
    public string DisplayTitle { get; set => Set(ref field, value); } = "";
    public int SelectedCount => all.Count(row => row.IsSelected);
    public bool HasSelection => SelectedCount > 0;
    private IReadOnlyList<ImportPreviewTarget> Targets => [.. (summary?.Targets ?? []).Where(target => ChoiceIndex == 2 ? target.Kind == MediaKind.Series : true)];

    private string Base => $"/api/v1/libraries/{library.Id}/import-preview";

    /// <summary>Reads the folders again and shows the result; the library is not changed.</summary>
    public Task AnalyzeAsync() => RunAsync(async token =>
    {
        summary = await client().SendAsync<ImportPreviewSummary>(HttpMethod.Post, Base, null, token);
        await LoadItemsAsync(token);
    });

    public Task AssignAsync()
    {
        var selected = all.Where(row => row.IsSelected).ToList();
        if (selected.Count == 0 || summary is null) return Task.CompletedTask;
        var kind = ChoiceKinds[ChoiceIndex];
        string? parent = null;
        if (NeedsParent)
        {
            if (ParentIndex < 0 || ParentIndex >= Targets.Count) return Fail("Choose the movie or show these belong to.");
            parent = Targets[ParentIndex].RelativePath;
        }
        int? season = null, episode = null;
        if (NeedsEpisode)
        {
            if (!int.TryParse(Season, NumberStyles.None, CultureInfo.InvariantCulture, out var seasonNumber)) return Fail("Enter the season number.");
            if (!int.TryParse(Episode, NumberStyles.None, CultureInfo.InvariantCulture, out var episodeNumber) || episodeNumber < 1)
                return Fail("Enter the episode number.");
            season = seasonNumber;
            episode = episodeNumber;
        }
        var title = selected.Count == 1 && !selected[0].Item.IsDirectory && DisplayTitle.Trim().Length > 0 ? DisplayTitle.Trim() : null;
        return SendAsync([.. selected.Select(row => new ImportAssignmentUpdate(row.Item.RelativePath, row.Item.IsDirectory, kind, parent,
            season, episode, NeedsCategory && Category.Trim().Length > 0 ? Category.Trim() : null, title))]);
    }

    public Task UseAutomaticAsync() =>
        SendAsync([.. all.Where(row => row.IsSelected).Select(row => new ImportAssignmentUpdate(row.Item.RelativePath, row.Item.IsDirectory, null,
            UseAutomaticDetection: true))]);

    /// <summary>Adds what the preview shows to the library and starts its scan.</summary>
    public Task ConfirmAsync() => RunAsync(async token =>
    {
        if (summary is null) return;
        await client().SendAsync<LibraryScanSummary>(HttpMethod.Post, $"{Base}/{summary.PreviewId}/confirm",
            new ConfirmImportPreviewRequest(summary.Revision), token);
        Confirmed?.Invoke();
    }, "The folders changed since the analysis. Analyze them again before adding.");

    public void SelectionChanged() => Changed(nameof(SelectedCount), nameof(HasSelection));

    private Task SendAsync(IReadOnlyList<ImportAssignmentUpdate> changes) => changes.Count == 0 || summary is null ? Task.CompletedTask : RunAsync(async token =>
    {
        summary = await client().SendAsync<ImportPreviewSummary>(HttpMethod.Put, $"{Base}/{summary.PreviewId}/assignments",
            new ImportAssignmentsRequest(summary.Revision, changes), token);
        await LoadItemsAsync(token);
        DisplayTitle = "";
    }, "The preview changed meanwhile. Analyze again to continue.");

    private async Task LoadItemsAsync(CancellationToken token)
    {
        var rows = new List<ImportRow>();
        for (var offset = 0; summary is not null && offset < 50_000;)
        {
            var page = await client().SendAsync<ImportPreviewPage>(HttpMethod.Get,
                $"{Base}/{summary.PreviewId}/items?offset={offset.ToString(CultureInfo.InvariantCulture)}&limit=200", null, token);
            summary = page.Summary;
            rows.AddRange(page.Items.Select(item => new ImportRow(item)));
            offset += page.Items.Count;
            if (page.Items.Count == 0 || offset >= page.TotalCount) break;
        }
        all.Clear();
        all.AddRange(rows);
        foreach (var row in all) row.PropertyChanged += (_, _) => SelectionChanged();
        Refilter();
        ParentIndex = -1;
        Changed(nameof(IsAnalyzed), nameof(CountsText), nameof(ReviewText), nameof(HasPending), nameof(Parents), nameof(SelectedCount), nameof(HasSelection));
    }

    private void Refilter()
    {
        var search = Search.Trim();
        Items.Clear();
        foreach (var row in all.Where(row => FilterIndex switch
        {
            1 => row.NeedsReview,
            2 => row.Item.Status == ImportPreviewItemStatus.Ignored,
            3 => row.Item.Status == ImportPreviewItemStatus.Error,
            _ => true,
        } && (search.Length == 0 || row.Title.Contains(search, StringComparison.CurrentCultureIgnoreCase)
                     || row.Path.Contains(search, StringComparison.CurrentCultureIgnoreCase))))
            Items.Add(row);
    }

    private Task Fail(string message)
    {
        Error = message;
        return Task.CompletedTask;
    }

    private async Task RunAsync(Func<CancellationToken, Task> operation, string? conflict = null)
    {
        if (IsBusy) return;
        IsBusy = true;
        Error = null;
        try { await operation(CancellationToken.None); }
        catch (AureliaApiException error) when (error.Status == 409 && conflict is not null && error.Code != "library_scan_active") { Error = conflict; }
        catch (AureliaApiException error) { Error = error.Message; }
        finally { IsBusy = false; }
    }

    private void Changed(params string[] names)
    {
        foreach (var name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string name = "", params string[] also)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Changed(name);
        Changed(also);
        return true;
    }
}
