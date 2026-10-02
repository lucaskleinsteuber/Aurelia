namespace Aurelia.Contracts;

public enum ImportPreviewItemStatus { Recognized, Pending, Ignored, Error }

public sealed record ImportAssignmentUpdate(
    string RelativePath,
    bool IsDirectory,
    MediaKind? Kind,
    string? ParentRelativePath = null,
    int? SeasonNumber = null,
    int? EpisodeNumber = null,
    string? Category = null,
    string? Title = null,
    bool UseAutomaticDetection = false);

public sealed record ImportAssignmentsRequest(string Revision, IReadOnlyList<ImportAssignmentUpdate> Assignments);
public sealed record ImportAssignmentsSummary(string Revision, IReadOnlyList<ImportAssignmentUpdate> Assignments);
public sealed record ConfirmImportPreviewRequest(string Revision);
public sealed record ImportPreviewCounts(int Files, int Movies, int Series, int Episodes, int Extras, int Trailers, int Pending, int Ignored, int Errors);
public sealed record ImportPreviewTarget(string RelativePath, string Title, MediaKind Kind, IReadOnlyList<int> SeasonNumbers);
public sealed record ImportPreviewItem(
    string RelativePath,
    string Title,
    MediaKind? Kind,
    string? ParentRelativePath,
    int? SeasonNumber,
    int? EpisodeNumber,
    string? Category,
    ImportPreviewItemStatus Status,
    string Reason,
    bool IsDirectory = false);
public sealed record ImportPreviewSummary(
    Guid PreviewId,
    Guid LibraryId,
    string Revision,
    string State,
    ImportPreviewCounts Counts,
    IReadOnlyList<LibraryScanIssueSummary> Issues,
    IReadOnlyList<ImportPreviewTarget> Targets);
public sealed record ImportPreviewPage(ImportPreviewSummary Summary, IReadOnlyList<ImportPreviewItem> Items, int TotalCount, int Offset, int Limit);
