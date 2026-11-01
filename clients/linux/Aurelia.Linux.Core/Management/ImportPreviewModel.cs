using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Management;

public enum ImportPreviewFilter
{
    All,
    NeedsReview,
    Ignored,
    Errors,
    Manual,
}

/// <summary>What an item in the import preview becomes, as the Mac's ImportContentChoice.</summary>
public enum ImportContentChoice
{
    Movie,
    Series,
    Episode,
    Extra,
    Trailer,
    Ignore,
}

/// <summary>
/// The import preview of one storage location: nothing is imported until it is confirmed. Items
/// load page by page for one revision; assignments change the preview, and confirming imports the
/// recognized items and starts a scan.
/// </summary>
public sealed class ImportPreviewModel(ManagementClient client, LibrarySummary library)
{
    public const int PageSize = 200;

    public LibrarySummary Library { get; } = library;

    public ImportPreviewSummary? Summary { get; private set; }

    public IReadOnlyList<ImportPreviewItem> Items { get; private set; } = [];

    public List<ImportAssignmentUpdate> Assignments { get; } = [];

    public bool HasDraftChanges { get; private set; }

    public bool CanConfirm => Summary is { Counts.Errors: 0 };

    public string ConfirmLabel => Library.ImportPreviewRequired ? "Import Recognized Items" : "Apply and Rescan";

    public async Task AnalyzeAsync()
    {
        var analyzed = await client.AnalyzeImportAsync(Library.Id);
        await LoadItemsAsync(analyzed);
        Assignments.Clear();
        Assignments.AddRange((await client.ImportAssignmentsAsync(Library.Id)).Assignments);
        HasDraftChanges = false;
    }

    private async Task LoadItemsAsync(ImportPreviewSummary summary)
    {
        var loaded = new List<ImportPreviewItem>();
        var offset = 0;
        while (true)
        {
            var page = await client.ImportItemsAsync(Library.Id, summary.PreviewId, offset, PageSize, null);
            if (page.Summary.Revision != summary.Revision)
                throw new AureliaApiException(409, "preview_changed", "The preview changed. Analyze the location again.");
            loaded.AddRange(page.Items);
            offset += page.Items.Count;
            if (offset >= page.TotalCount) break;
            if (page.Items.Count == 0) throw new AureliaApiException(502, "incomplete_preview", "The server returned an incomplete preview.");
        }
        Summary = summary;
        Items = loaded;
    }

    public async Task ApplyAsync(IReadOnlyList<ImportAssignmentUpdate> changes)
    {
        if (Summary is not { } summary) return;
        var updated = await client.UpdateImportAsync(Library.Id, summary.PreviewId, new ImportAssignmentsRequest(summary.Revision, changes));
        await LoadItemsAsync(updated);
        foreach (var change in changes)
        {
            Assignments.RemoveAll(a => a.RelativePath == change.RelativePath && a.IsDirectory == change.IsDirectory);
            if (!change.UseAutomaticDetection) Assignments.Add(change);
        }
        HasDraftChanges = true;
    }

    public async Task<LibraryScanSummary?> ConfirmAsync()
    {
        if (Summary is not { } summary) return null;
        var scan = await client.ConfirmImportAsync(Library.Id, summary.PreviewId, summary.Revision);
        HasDraftChanges = false;
        return scan;
    }

    public IReadOnlyList<ImportPreviewItem> Visible(string search, ImportPreviewFilter filter) =>
    [
        .. Items.Where(item => (search.Length == 0
                || item.Title.Contains(search, StringComparison.CurrentCultureIgnoreCase)
                || item.RelativePath.Contains(search, StringComparison.CurrentCultureIgnoreCase))
            && filter switch
            {
                ImportPreviewFilter.NeedsReview => item.Status == ImportPreviewItemStatus.Pending,
                ImportPreviewFilter.Ignored => item.Status == ImportPreviewItemStatus.Ignored,
                ImportPreviewFilter.Errors => item.Status == ImportPreviewItemStatus.Error,
                ImportPreviewFilter.Manual => Assignments.Any(a => a.RelativePath == item.RelativePath
                    || (a.IsDirectory && (a.RelativePath.Length == 0 || item.RelativePath.StartsWith(a.RelativePath + "/", StringComparison.Ordinal)))),
                _ => true,
            })
            .OrderBy(item => item.RelativePath, StringComparer.CurrentCultureIgnoreCase),
    ];

    public static MediaKind? Kind(ImportContentChoice choice) => choice switch
    {
        ImportContentChoice.Movie => MediaKind.Movie,
        ImportContentChoice.Series => MediaKind.Series,
        ImportContentChoice.Episode => MediaKind.Episode,
        ImportContentChoice.Extra => MediaKind.Extra,
        ImportContentChoice.Trailer => MediaKind.Trailer,
        _ => null,
    };

    public static ImportContentChoice Choice(MediaKind? kind) => kind switch
    {
        MediaKind.Movie => ImportContentChoice.Movie,
        MediaKind.Series => ImportContentChoice.Series,
        MediaKind.Episode => ImportContentChoice.Episode,
        MediaKind.Trailer => ImportContentChoice.Trailer,
        _ => ImportContentChoice.Extra,
    };

    public static string Label(ImportContentChoice choice) => choice switch
    {
        ImportContentChoice.Series => "TV Show · Force Import",
        _ => choice.ToString(),
    };

    public static bool NeedsParent(ImportContentChoice choice) => choice is ImportContentChoice.Episode or ImportContentChoice.Extra or ImportContentChoice.Trailer;

    /// <summary>
    /// The assignment changes for the chosen items, or why they cannot be saved: an episode needs a
    /// series, a season 0–99 and an episode 1–999, and only one file at a time.
    /// </summary>
    public static (IReadOnlyList<ImportAssignmentUpdate>? Changes, string? Problem) Assign(IReadOnlyList<ImportPreviewItem> items,
        IReadOnlyList<ImportPreviewTarget> targets, ImportContentChoice choice, string? parentPath, bool entireSeries,
        string season, string episode, string category, string title)
    {
        var needsParent = NeedsParent(choice);
        var parent = targets.FirstOrDefault(target => target.RelativePath == parentPath);
        if (needsParent && parent is null) return (null, "Choose the movie or series this belongs to.");
        int? seasonNumber = null;
        int? episodeNumber = null;
        if (choice == ImportContentChoice.Episode)
        {
            if (parent?.Kind != MediaKind.Series) return (null, "An episode belongs to a series.");
            if (!int.TryParse(season, out var s) || s is < 0 or > 99) return (null, "Enter a season from 0 to 99.");
            if (!int.TryParse(episode, out var e) || e is < 1 or > 999) return (null, "Enter an episode from 1 to 999.");
            if (items.Count > 1 || items.Any(item => item.IsDirectory)) return (null, "Number episodes one file at a time.");
            (seasonNumber, episodeNumber) = (s, e);
        }
        else if (needsParent && parent?.Kind == MediaKind.Series && !entireSeries)
        {
            if (!int.TryParse(season, out var s) || s is < 0 or > 99) return (null, "Enter a season from 0 to 99.");
            seasonNumber = s;
        }
        return ([
            .. items.Select(item => new ImportAssignmentUpdate(item.RelativePath, item.IsDirectory, Kind(choice),
                needsParent ? parentPath : null, seasonNumber, episodeNumber,
                needsParent && category.Length > 0 ? category : null,
                items.Count == 1 && !item.IsDirectory && title.Length > 0 ? title : null)),
        ], null);
    }
}
