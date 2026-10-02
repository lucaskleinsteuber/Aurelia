using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

// Only names and filesystem metadata enter this service. No video is opened.
public sealed class ImportPlanningService(
    AureliaDbContext database,
    IMediaLibraryScanner scanner,
    LibraryScanScheduler queue,
    CatalogMutationGate mutations)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly TimeSpan Lifetime = TimeSpan.FromDays(1);

    public async Task<ImportAssignmentsSummary> AssignmentsAsync(Guid libraryId, CancellationToken token)
    {
        var root = await RootAsync(libraryId, token);
        return new(root.ImportAssignmentRevision.ToString(CultureInfo.InvariantCulture), await ReadAssignmentsAsync(root, token));
    }

    public async Task<ImportPreviewSummary> AnalyzeAsync(Guid libraryId, CancellationToken token)
    {
        var root = await RootAsync(libraryId, token);
        Reserve(root.Id);
        try
        {
            await RequireIdleAsync(root.Id, token);
            var rules = await ReadAssignmentsAsync(root, token);
            var discovery = await DiscoverAsync(root, rules, token);
            var preview = new LibraryImportPreview
            {
                Id = Guid.NewGuid(),
                LibraryRootId = root.Id,
                CreatedAt = DateTimeOffset.UtcNow,
                BaseAssignmentRevision = root.ImportAssignmentRevision,
                WasInitialImport = root.ImportPreviewRequired,
            };
            Refresh(preview, root, discovery, rules);
            using var lease = await mutations.EnterAsync(token);
            database.ChangeTracker.Clear();
            var current = await RootAsync(root.Id, token);
            if (current.ImportAssignmentRevision != preview.BaseAssignmentRevision) throw Conflict();
            await RequireIdleAsync(root.Id, token);
            var expiresBefore = DateTimeOffset.UtcNow.Subtract(Lifetime);
            // At most five drafts are retained per root. SQLite cannot order its
            // native DateTimeOffset representation; prune this bounded set locally.
            var drafts = await database.LibraryImportPreviews.Where(value => value.LibraryRootId == root.Id).ToArrayAsync(token);
            var old = drafts.Where(value => value.CreatedAt < expiresBefore)
                .Concat(drafts.OrderByDescending(value => value.CreatedAt).Skip(4)).Distinct().ToArray();
            database.LibraryImportPreviews.RemoveRange(old);
            database.LibraryImportPreviews.Add(preview);
            await database.SaveChangesAsync(token);
            return Summary(preview);
        }
        finally { queue.Release(root.Id); }
    }

    public async Task<ImportPreviewPage> PageAsync(Guid libraryId, Guid previewId, int offset, int limit, string? filter, CancellationToken token)
    {
        if (offset < 0 || limit is < 1 or > 1000) throw Invalid("Use an offset of zero or greater and a page size between 1 and 1000.");
        var preview = await PreviewAsync(libraryId, previewId, null, token);
        IEnumerable<ImportPreviewItem> items = Deserialize<ImportPreviewItem[]>(preview.ItemsJson);
        if (!string.IsNullOrWhiteSpace(filter) && !string.Equals(filter, "all", StringComparison.OrdinalIgnoreCase))
        {
            if (!Enum.TryParse<ImportPreviewItemStatus>(filter, true, out var status) || !Enum.IsDefined(status)) throw Invalid("Unknown import filter.");
            items = items.Where(item => item.Status == status);
        }
        var filtered = items.ToArray();
        return new(Summary(preview), filtered.Skip(offset).Take(limit).ToArray(), filtered.Length, offset, limit);
    }

    public async Task<ImportPreviewSummary> UpdateAsync(Guid libraryId, Guid previewId, ImportAssignmentsRequest request, CancellationToken token)
    {
        var root = await RootAsync(libraryId, token);
        var preview = await PreviewAsync(libraryId, previewId, request.Revision, token);
        Reserve(root.Id);
        try
        {
            await RequireIdleAsync(root.Id, token);
            var rules = Deserialize<ImportAssignmentUpdate[]>(preview.AssignmentsJson).ToList();
            var items = Deserialize<ImportPreviewItem[]>(preview.ItemsJson);
            ValidateUpdates(root, items, Summary(preview).Targets, request.Assignments);
            foreach (var update in request.Assignments)
            {
                var normalized = Normalize(update.RelativePath);
                rules.RemoveAll(rule => rule.IsDirectory == update.IsDirectory && Normalize(rule.RelativePath) == normalized);
                if (!update.UseAutomaticDetection) rules.Add(update with { RelativePath = Canonical(update.RelativePath), ParentRelativePath = update.ParentRelativePath is null ? null : Canonical(update.ParentRelativePath) });
            }
            var discovery = await DiscoverAsync(root, rules, token);
            if (Manifest(discovery, root) != preview.Manifest) throw ChangedSource();
            using var lease = await mutations.EnterAsync(token);
            database.ChangeTracker.Clear();
            var current = await PreviewAsync(libraryId, previewId, request.Revision, token);
            var currentRoot = await RootAsync(libraryId, token);
            if (currentRoot.ImportAssignmentRevision != current.BaseAssignmentRevision) throw Conflict();
            Refresh(current, currentRoot, discovery, rules);
            await database.SaveChangesAsync(token);
            return Summary(current);
        }
        finally { queue.Release(root.Id); }
    }

    public async Task<LibraryScanSummary> ConfirmAsync(Guid libraryId, Guid previewId, ConfirmImportPreviewRequest request, CancellationToken token)
    {
        var root = await RootAsync(libraryId, token);
        var preview = await PreviewAsync(libraryId, previewId, request.Revision, token);
        Reserve(root.Id);
        var queued = false;
        try
        {
            await RequireIdleAsync(root.Id, token);
            var rules = Deserialize<ImportAssignmentUpdate[]>(preview.AssignmentsJson);
            var discovery = await DiscoverAsync(root, rules, token);
            if (Manifest(discovery, root) != preview.Manifest) throw ChangedSource();
            if (discovery.Issues.Any(issue => issue.Code is "unreadable_directory" or "unreadable_entry" or "unreadable_file"))
                throw new AccountException("incomplete_import_preview", "Some source entries could not be read. Resolve the access error and analyze again before importing.", 409);
            using var lease = await mutations.EnterAsync(token);
            database.ChangeTracker.Clear();
            root = await RootAsync(libraryId, token);
            preview = await PreviewAsync(libraryId, previewId, request.Revision, token);
            if (root.ImportAssignmentRevision != preview.BaseAssignmentRevision) throw Conflict();
            await RequireIdleAsync(root.Id, token);
            await using var transaction = await database.Database.BeginTransactionAsync(token);
            await database.LibraryImportAssignments.Where(value => value.LibraryRootId == root.Id).ExecuteDeleteAsync(token);
            database.LibraryImportAssignments.AddRange(rules.Select(rule => Entity(root.Id, rule)));
            // Resolved legacy choices are now represented in the general rules.
            // Removing them also makes Use Automatic Detection genuinely reversible.
            await database.LibraryImportReviews.Where(value => value.LibraryRootId == root.Id && value.State != LibraryImportReviewState.Pending).ExecuteDeleteAsync(token);
            await database.LibraryDiscoveries.Where(value => value.LibraryRootId == root.Id && value.Decision != null)
                .ExecuteUpdateAsync(setters => setters.SetProperty(value => value.Decision, (ClassificationDecision?)null), token);
            root.ImportAssignmentRevision++;
            root.ImportPreviewRequired = false;
            preview.Confirmed = true;
            var scan = new LibraryScan
            {
                Id = Guid.NewGuid(),
                LibraryRootId = root.Id,
                State = LibraryScanState.Queued,
                Trigger = LibraryScanTrigger.ClassificationChanged,
                CreatedAt = DateTimeOffset.UtcNow,
                ConfirmedPreviewId = preview.Id,
            };
            database.LibraryScans.Add(scan);
            await database.SaveChangesAsync(token);
            await transaction.CommitAsync(token);
            queued = true;
            queue.Pulse();
            return new(scan.Id, root.Id, scan.State, scan.CreatedAt, null, null, 0, 0, 0, 0, 0, 0, null, [], scan.Trigger);
        }
        finally { if (!queued) queue.Release(root.Id); }
    }

    private async Task<MediaScanDiscovery> DiscoverAsync(LibraryRoot root, IReadOnlyList<ImportAssignmentUpdate> rules, CancellationToken token)
    {
        if (!Directory.Exists(root.Path)) throw new AccountException("library_unavailable", "The storage location is unavailable. Reconnect it and analyze again.", 409);
        var existing = await database.MediaItems.AsNoTracking().Where(item => item.LibraryRootId == root.Id).ToArrayAsync(token);
        var parents = existing.ToDictionary(item => item.Id);
        var episodes = existing.Where(item => item.Kind == MediaKind.Episode && item.ParentId.HasValue && item.SeasonNumber.HasValue && item.EpisodeNumber.HasValue && parents.ContainsKey(item.ParentId.Value))
            .Select(item => new ExistingEpisodeBinding(parents[item.ParentId!.Value].SourcePath, item.SeasonNumber!.Value, item.EpisodeNumber!.Value, item.SourcePath)).ToArray();
        var movies = existing.Where(item => item.Kind == MediaKind.Movie).Select(item => new ExistingMovieBinding(item.Id, item.SourcePath, item.Year)).ToArray();
        var excluded = await database.MediaExclusions.AsNoTracking().Where(value => value.LibraryRootId == root.Id).ToArrayAsync(token);
        var allRules = ComposeScannerAssignments(root, rules.Select(ToScanner).ToArray(), existing, excluded);
        var discovered = await Task.Run(() => scanner.Scan(root.Path, root.Kind, episodes, null, token, existingMovies: movies, assignments: allRules), token);
        var bindings = existing.Where(item => item.ManualSourceBinding).ToDictionary(item => item.NormalizedSourcePath, StringComparer.Ordinal);
        bool Excluded(string path, string? identity = null) => excluded.Any(value =>
            value.NormalizedSourcePath == MediaPath.Normalize(path)
            || value.IsDirectory && MediaPath.Normalize(path).StartsWith(value.NormalizedSourcePath.TrimEnd('/') + "/", StringComparison.Ordinal)
            || identity is not null && value.FileSystemIdentity == identity);
        return discovered with
        {
            Items = discovered.Items.Where(item => !Excluded(item.SourcePath, item.FileSystemIdentity)).Select(item => bindings.TryGetValue(MediaPath.Normalize(item.SourcePath), out var bound)
                ? item with
                {
                    Kind = bound.Kind,
                    ParentSourcePath = bound.ParentId is { } id && parents.TryGetValue(id, out var parent) ? parent.SourcePath : item.ParentSourcePath,
                    DetectedTitle = bound.DetectedTitle,
                    Year = bound.Year,
                    SeasonNumber = bound.SeasonNumber,
                    EpisodeNumber = bound.EpisodeNumber,
                    Category = bound.Category
                }
                : item).ToArray(),
            ImportReviews = discovered.ImportReviews?.Where(value => !Excluded(value.SourcePath)).ToArray(),
            Classifications = (discovered.Classifications ?? []).Concat((discovered.Files ?? []).Where(value => Excluded(value.SourcePath, value.FileSystemIdentity))
                .Select(value => new DiscoveredClassification(Relative(root, value.SourcePath), "Excluded source", null, "manual_ignore", false))).ToArray(),
        };
    }

    private static void Refresh(LibraryImportPreview preview, LibraryRoot root, MediaScanDiscovery discovery, IReadOnlyList<ImportAssignmentUpdate> rules)
    {
        var items = new List<ImportPreviewItem>();
        var paths = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in discovery.Items)
        {
            var path = Relative(root, item.SourcePath);
            paths.Add(Normalize(path));
            items.Add(new(path, item.DetectedTitle, item.Kind, item.ParentSourcePath is null ? null : Relative(root, item.ParentSourcePath), item.SeasonNumber, item.EpisodeNumber, item.Category,
                ImportPreviewItemStatus.Recognized, "Recognized from its title, season and source context.", item.Kind == MediaKind.Series));
        }
        foreach (var review in discovery.ImportReviews ?? [])
        {
            var path = Relative(root, review.SourcePath);
            if (paths.Add(Normalize(path))) items.Add(new(path, review.DetectedTitle, null, null, null, null, null, ImportPreviewItemStatus.Pending, review.Reason));
        }
        foreach (var file in discovery.Files ?? [])
        {
            var path = Relative(root, file.SourcePath);
            if (!paths.Add(Normalize(path))) continue;
            var applied = rules.OrderByDescending(rule => !rule.IsDirectory).ThenByDescending(rule => rule.RelativePath.Length)
                .FirstOrDefault(rule => Matches(rule, path));
            var ignored = applied is { Kind: null } || discovery.Classifications?.Any(value =>
                value.Reason == "manual_ignore" && Descendant(path, value.RelativePath)) == true;
            var classification = discovery.Classifications?.Where(value => value.NeedsReview && Descendant(path, value.RelativePath)).OrderByDescending(value => value.RelativePath.Length).FirstOrDefault();
            items.Add(new(path, Path.GetFileNameWithoutExtension(path), null, null, null, null, null,
                ignored ? ImportPreviewItemStatus.Ignored : ImportPreviewItemStatus.Pending,
                ignored ? "Excluded by a saved import decision." : classification?.Reason ?? "This video needs an explicit title and content-type assignment."));
        }
        foreach (var issue in discovery.Issues.Where(issue => issue.Code is "unreadable_directory" or "unreadable_entry" or "unreadable_file"))
            items.Add(new(issue.Path is null ? string.Empty : Relative(root, issue.Path), "Unreadable source", null, null, null, null, null, ImportPreviewItemStatus.Error, issue.Message, true));
        items = items.OrderBy(item => item.RelativePath, StringComparer.Ordinal).ToList();
        var seasonsByParent = items.Where(item => item.Kind == MediaKind.Episode && item.ParentRelativePath is not null && item.SeasonNumber is not null)
            .GroupBy(item => item.ParentRelativePath!, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Select(item => item.SeasonNumber!.Value).Distinct().Order().ToArray(), StringComparer.Ordinal);
        var targets = items.Where(item => item.Kind is MediaKind.Movie or MediaKind.Series).Select(item => new ImportPreviewTarget(item.RelativePath, item.Title, item.Kind!.Value,
            seasonsByParent.GetValueOrDefault(item.RelativePath) ?? [])).ToArray();
        int Count(MediaKind kind) => items.Count(item => item.Kind == kind && item.Status == ImportPreviewItemStatus.Recognized);
        var counts = new ImportPreviewCounts(discovery.FilesDiscovered, Count(MediaKind.Movie), Count(MediaKind.Series), Count(MediaKind.Episode), Count(MediaKind.Extra), Count(MediaKind.Trailer),
            items.Count(item => item.Status == ImportPreviewItemStatus.Pending), items.Count(item => item.Status == ImportPreviewItemStatus.Ignored), items.Count(item => item.Status == ImportPreviewItemStatus.Error));
        preview.Revision = Guid.NewGuid().ToString("N");
        preview.Manifest = Manifest(discovery, root);
        preview.ItemsJson = JsonSerializer.Serialize(items, Json);
        preview.AssignmentsJson = JsonSerializer.Serialize(rules, Json);
        preview.SummaryJson = JsonSerializer.Serialize(new ImportPreviewSummary(preview.Id, root.Id, preview.Revision, "Ready", counts,
            discovery.Issues.Take(500).Select(issue => new LibraryScanIssueSummary(issue.Code, issue.Message, issue.Path is null ? null : Relative(root, issue.Path))).ToArray(), targets), Json);
    }

    // The hash is of a bounded manifest of paths/stat data, never video bytes.
    internal static string Manifest(MediaScanDiscovery discovery, LibraryRoot root)
    {
        var entries = (discovery.Files ?? []).OrderBy(value => value.SourcePath, StringComparer.Ordinal)
            .Select(value => new { Path = Relative(root, value.SourcePath), value.Extension, value.FileSize, value.FileModifiedAt, value.FileSystemIdentity }).ToArray();
        return Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new { root.Kind, root.Path, Entries = entries }, Json)));
    }

    private async Task<ImportAssignmentUpdate[]> ReadAssignmentsAsync(LibraryRoot root, CancellationToken token)
    {
        var rows = await database.LibraryImportAssignments.AsNoTracking().Where(value => value.LibraryRootId == root.Id).OrderBy(value => value.RelativePath).ToArrayAsync(token);
        var rules = rows.Select(value => new ImportAssignmentUpdate(value.RelativePath, value.IsDirectory, value.Kind, value.ParentRelativePath, value.SeasonNumber, value.EpisodeNumber, value.Category, value.Title)).ToList();
        var legacyFolders = await database.LibraryDiscoveries.AsNoTracking().Where(value => value.LibraryRootId == root.Id && value.Decision != null).ToArrayAsync(token);
        foreach (var folder in legacyFolders.Where(value => !rules.Any(rule => rule.IsDirectory && Normalize(rule.RelativePath) == value.NormalizedRelativePath)))
            rules.Add(new(folder.RelativePath, true, folder.Decision switch { ClassificationDecision.Movie => MediaKind.Movie, ClassificationDecision.TvShows => MediaKind.Series, _ => null }));
        // Legacy trailer choices remain authoritative unless a generic rule exists.
        var reviews = await database.LibraryImportReviews.AsNoTracking().Include(value => value.AssignedMovie)
            .Where(value => value.LibraryRootId == root.Id && value.State != LibraryImportReviewState.Pending).ToArrayAsync(token);
        foreach (var review in reviews.Where(value => !rules.Any(rule => Normalize(rule.RelativePath) == value.NormalizedRelativePath)))
        {
            if (review.State == LibraryImportReviewState.Ignored) rules.Add(new(review.RelativePath, false, null));
            else if (review.AssignedMovie is { } movie && movie.LibraryRootId == root.Id)
                rules.Add(new(review.RelativePath, false, MediaKind.Trailer, Relative(root, movie.SourcePath)));
        }
        return rules.ToArray();
    }

    private static void ValidateUpdates(LibraryRoot root, IReadOnlyList<ImportPreviewItem> items, IReadOnlyList<ImportPreviewTarget> targets, IReadOnlyList<ImportAssignmentUpdate> updates)
    {
        if (updates is null || updates.Count is < 1 or > 1000) throw Invalid("Choose between one and 1000 import assignments.");
        var newTargets = updates.Where(value => value.Kind is MediaKind.Movie or MediaKind.Series && !value.UseAutomaticDetection).Select(value => new ImportPreviewTarget(Canonical(value.RelativePath), value.Title ?? "", value.Kind!.Value, [])).Concat(targets).ToArray();
        foreach (var rule in updates)
        {
            ValidatePath(root, rule.RelativePath);
            if (rule.Kind is { } kind && !Enum.IsDefined(kind)) throw Invalid("Unknown content type.");
            if (rule.Title?.Length > 500 || rule.Category?.Length > 1024 || rule.SeasonNumber is < 0 or > 999 || rule.EpisodeNumber is < 1 or > 9999) throw Invalid("An import field exceeds its allowed range.");
            if (!items.Any(item => rule.IsDirectory ? Descendant(item.RelativePath, rule.RelativePath) : Normalize(item.RelativePath) == Normalize(rule.RelativePath)))
                throw Invalid("The selected source does not exist in this preview.");
            if (rule.UseAutomaticDetection || rule.Kind is null) continue;
            if (rule.Kind == MediaKind.Series && !rule.IsDirectory) throw Invalid("Assign a series to its directory.");
            if (rule.Kind is MediaKind.Episode or MediaKind.Extra or MediaKind.Trailer)
            {
                if (rule.ParentRelativePath is null) throw Invalid("Choose the film or series that owns this video.");
                ValidatePath(root, rule.ParentRelativePath);
                var parent = newTargets.FirstOrDefault(value => Normalize(value.RelativePath) == Normalize(rule.ParentRelativePath));
                if (parent is null || rule.Kind == MediaKind.Episode && parent.Kind != MediaKind.Series) throw Invalid("Choose a proposed film or series in this storage location.");
                if (parent.Kind == MediaKind.Movie && rule.SeasonNumber.HasValue) throw Invalid("Movies cannot own season-specific extras.");
                if (rule.Kind is MediaKind.Extra or MediaKind.Trailer && parent.Kind == MediaKind.Series && rule.SeasonNumber is { } season && !parent.SeasonNumbers.Contains(season))
                    throw Invalid("Choose Entire Series or an existing season of the selected series.");
                if (rule.Kind == MediaKind.Episode && (rule.SeasonNumber is null || rule.EpisodeNumber is null)) throw Invalid("Episodes need a season and an explicit starting episode number.");
            }
        }
    }

    private static void ValidatePath(LibraryRoot root, string path)
    {
        if (path is null || path.Length > 4096 || path.Contains('\0') || Path.IsPathRooted(path)
            || path.Split('/', '\\').Any(segment => segment == "..")) throw Invalid("Use a relative path inside this storage location.");
        var full = Path.GetFullPath(Path.Combine(root.Path, Canonical(path)));
        if (!MediaPath.IsSameOrDescendant(MediaPath.Normalize(full), root.NormalizedPath)) throw Invalid("The source is outside this storage location.");
    }

    private async Task<LibraryRoot> RootAsync(Guid id, CancellationToken token) => await database.LibraryRoots.SingleOrDefaultAsync(value => value.Id == id, token)
        ?? throw new AccountException("library_not_found", "The storage location was not found or is not shared with your account.", 404);
    private async Task<LibraryImportPreview> PreviewAsync(Guid root, Guid id, string? revision, CancellationToken token)
    {
        var preview = await database.LibraryImportPreviews.SingleOrDefaultAsync(value => value.LibraryRootId == root && value.Id == id, token)
            ?? throw new AccountException("import_preview_not_found", "The import preview is unavailable. Analyze the storage location again.", 404);
        if (preview.Confirmed || preview.CreatedAt < DateTimeOffset.UtcNow.Subtract(Lifetime) || revision is not null && preview.Revision != revision) throw Conflict();
        return preview;
    }
    private async Task RequireIdleAsync(Guid root, CancellationToken token)
    {
        if (await database.LibraryScans.AnyAsync(value => value.LibraryRootId == root && (value.State == LibraryScanState.Queued || value.State == LibraryScanState.Running || value.State == LibraryScanState.WaitingForStorage), token))
            throw new AccountException("library_scan_active", "Wait for the active scan to finish or cancel it before editing import decisions.", 409);
    }
    private void Reserve(Guid root)
    {
        if (!queue.TryReserve(root)) throw new AccountException("library_scan_active", "A scan or import analysis is already active for this storage location.", 409);
    }
    private static ImportPreviewSummary Summary(LibraryImportPreview value) => Deserialize<ImportPreviewSummary>(value.SummaryJson);
    private static T Deserialize<T>(string json) => JsonSerializer.Deserialize<T>(json, Json) ?? throw new InvalidOperationException("The stored import draft is invalid.");
    private static string Relative(LibraryRoot root, string path) => Path.GetRelativePath(root.Path, path) is "." ? "" : Path.GetRelativePath(root.Path, path).Replace('\\', '/');
    private static string Canonical(string path) => path.Replace('\\', '/').Trim('/');
    private static string Normalize(string path) => Canonical(path).Normalize(System.Text.NormalizationForm.FormKC).ToUpperInvariant();
    private static bool Descendant(string path, string parent) => Normalize(parent).Length == 0 || Normalize(path) == Normalize(parent) || Normalize(path).StartsWith(Normalize(parent) + "/", StringComparison.Ordinal);
    private static bool Matches(ImportAssignmentUpdate rule, string path) => rule.IsDirectory ? Descendant(path, rule.RelativePath) : Normalize(rule.RelativePath) == Normalize(path);
    internal static ExistingImportAssignment ToScanner(ImportAssignmentUpdate rule) => new(rule.RelativePath, rule.IsDirectory, rule.Kind, rule.ParentRelativePath, rule.SeasonNumber, rule.EpisodeNumber, rule.Category, rule.Title);
    internal static ExistingImportAssignment[] ComposeScannerAssignments(
        LibraryRoot root, IReadOnlyList<ExistingImportAssignment> rules,
        IReadOnlyList<MediaItem> existing, IReadOnlyList<MediaExclusion> exclusions)
    {
        var parents = existing.ToDictionary(item => item.Id);
        // Protect an editor-selected file before automatic classification, not only
        // after discovery: an ambiguous or renamed source may otherwise disappear.
        // Identity matching is limited to explicit bindings with matching stat data.
        var bindings = existing.Where(item => item.ManualSourceBinding
            && MediaPath.IsSameOrDescendant(item.NormalizedSourcePath, MediaPath.Normalize(root.Path))
            && !exclusions.Any(value => value.NormalizedSourcePath == item.NormalizedSourcePath
                || value.IsDirectory && MediaPath.IsSameOrDescendant(item.NormalizedSourcePath, value.NormalizedSourcePath)
                || item.FileSystemIdentity is not null && value.FileSystemIdentity == item.FileSystemIdentity))
            .Select(item => new ExistingImportAssignment(Relative(root, item.SourcePath), item.Kind == MediaKind.Series,
                item.Kind, item.ParentId is { } id && parents.TryGetValue(id, out var parent) ? Relative(root, parent.SourcePath) : null,
                item.SeasonNumber, item.EpisodeNumber, item.Category, item.DetectedTitle,
                item.Kind == MediaKind.Series ? null : item.FileSystemIdentity, item.FileSize, item.FileModifiedAt));
        // The scanner keeps the last exact-path rule. Exclusions are authoritative
        // even over a manual file binding and are never persisted as editor rules.
        return rules.Concat(bindings).Concat(exclusions.Select(value => new ExistingImportAssignment(
            value.RelativePath, value.IsDirectory, null, null, null, null, null, null))).ToArray();
    }
    private static LibraryImportAssignment Entity(Guid root, ImportAssignmentUpdate rule) => new()
    {
        Id = Guid.NewGuid(),
        LibraryRootId = root,
        RelativePath = rule.RelativePath,
        NormalizedRelativePath = Normalize(rule.RelativePath),
        IsDirectory = rule.IsDirectory,
        Kind = rule.Kind,
        ParentRelativePath = rule.ParentRelativePath,
        SeasonNumber = rule.SeasonNumber,
        EpisodeNumber = rule.EpisodeNumber,
        Category = rule.Category,
        Title = rule.Title,
    };
    private static AccountException Invalid(string message) => new("invalid_import_assignment", message, 400);
    private static AccountException Conflict() => new("import_preview_conflict", "This preview expired, was already imported, or changed on another device. Analyze again; no catalog changes were applied.", 409);
    private static AccountException ChangedSource() => new("import_source_changed", "Source files changed after the preview. Analyze again before importing.", 409);
}
