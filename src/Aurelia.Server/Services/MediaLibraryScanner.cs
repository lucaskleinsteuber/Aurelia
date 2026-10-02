using System.Text;
using System.Text.RegularExpressions;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public sealed record ExistingEpisodeBinding(
    string SeriesPath,
    int SeasonNumber,
    int EpisodeNumber,
    string FilePath);

public sealed record ExistingMovieBinding(Guid Id, string SourcePath, int? Year);

public sealed record ExistingImportReviewDecision(
    string SourcePath,
    LibraryImportReviewState State,
    string? ParentSourcePath);

public sealed record ExistingImportAssignment(
    string RelativePath,
    bool IsDirectory,
    MediaKind? Kind,
    string? ParentRelativePath,
    int? SeasonNumber,
    int? EpisodeNumber,
    string? Category,
    string? Title,
    string? FileSystemIdentity = null,
    long? FileSize = null,
    DateTimeOffset? FileModifiedAt = null);

public sealed record DiscoveredScanFile(
    string SourcePath,
    string Extension,
    long FileSize,
    DateTimeOffset FileModifiedAt,
    string? FileSystemIdentity);

public sealed record DiscoveredImportReview(
    string SourcePath,
    string DetectedTitle,
    string Reason);

public sealed record DiscoveredMediaItem(
    MediaKind Kind,
    string SourcePath,
    string? ParentSourcePath,
    string DetectedTitle,
    int? Year,
    int? SeasonNumber,
    int? EpisodeNumber,
    string Category,
    string? Extension,
    long? FileSize,
    DateTimeOffset? FileModifiedAt,
    string? FileSystemIdentity = null)
{
    public bool IsFile => Kind != MediaKind.Series;
}

public sealed record ScanDiscoveryIssue(string Code, string Message, string? Path);

public sealed record ExistingClassificationDecision(
    string RelativePath,
    ClassificationDecision Decision);

public sealed record DiscoveredClassification(
    string RelativePath,
    string DetectedTitle,
    LibraryKind? SuggestedKind,
    string Reason,
    bool NeedsReview);

public sealed record MediaScanDiscovery(
    IReadOnlyList<DiscoveredMediaItem> Items,
    IReadOnlyList<ScanDiscoveryIssue> Issues,
    int FilesDiscovered,
    int SkippedFiles,
    IReadOnlyList<DiscoveredClassification>? Classifications = null,
    IReadOnlyList<DiscoveredImportReview>? ImportReviews = null,
    IReadOnlyList<DiscoveredScanFile>? Files = null);

public interface IMediaLibraryScanner
{
    MediaScanDiscovery Scan(
        string rootPath,
        LibraryKind kind,
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes,
        Action<int>? progress,
        CancellationToken cancellationToken,
        IReadOnlyList<ExistingClassificationDecision>? classificationDecisions = null,
        IReadOnlyList<ExistingMovieBinding>? existingMovies = null,
        IReadOnlyList<ExistingImportReviewDecision>? importReviewDecisions = null,
        IReadOnlyList<ExistingImportAssignment>? assignments = null,
        Action<string>? onPhase = null);
}

public sealed class MediaLibraryScanner : IMediaLibraryScanner
{
    private static readonly IComparer<string> NaturalPathComparer =
        Comparer<string>.Create(FilenameMetadataParser.CompareNaturally);

    private static readonly HashSet<string> SupportedExtensions = new(
        [".mkv", ".mp4", ".mov", ".m4v", ".avi", ".webm"],
        StringComparer.OrdinalIgnoreCase);

    public static bool IsSupportedMediaPath(string path) =>
        SupportedExtensions.Contains(Path.GetExtension(path));

    private static readonly HashSet<string> ExtrasFolderNames =
    [
        "extra",
        "extras",
        "bonus",
        "bonusmaterial",
        "bonusfeature",
        "bonusfeatures",
        "featurette",
        "featurettes",
        "specialfeature",
        "specialfeatures",
        "behindthescenes",
        "makingof",
        "deletedscene",
        "deletedscenes",
        "interview",
        "interviews",
        "blooper",
        "bloopers",
        "outtakes",
        "zusatzmaterial",
        "zusatzinhalte",
    ];

    private static readonly HashSet<string> TrailerFolderNames =
    [
        "trailer",
        "trailers",
        "teaser",
        "teasers",
        "officialtrailer",
        "officialtrailers",
        "officialteaser",
        "officialteasers",
    ];

    private static readonly HashSet<string> PackageExtensions = new(
        [".app", ".bundle", ".framework", ".plugin", ".pkg", ".xcodeproj"],
        StringComparer.OrdinalIgnoreCase);

    public MediaScanDiscovery Scan(
        string rootPath,
        LibraryKind kind,
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes,
        Action<int>? progress,
        CancellationToken cancellationToken,
        IReadOnlyList<ExistingClassificationDecision>? classificationDecisions = null,
        IReadOnlyList<ExistingMovieBinding>? existingMovies = null,
        IReadOnlyList<ExistingImportReviewDecision>? importReviewDecisions = null,
        IReadOnlyList<ExistingImportAssignment>? assignments = null,
        Action<string>? onPhase = null)
    {
        onPhase?.Invoke("Discovering");
        var files = EnumerateVideoFiles(rootPath, progress, cancellationToken);
        onPhase?.Invoke("Resolving");
        var normalizedRoot = Path.GetFullPath(rootPath);
        var validAssignments = ValidateAssignments(normalizedRoot, assignments ?? []);
        var ambiguousFileIdentities = files.Files.Where(file => file.FileSystemIdentity is not null)
            .GroupBy(file => file.FileSystemIdentity!, StringComparer.Ordinal).Where(group => group.Count() > 1)
            .Select(group => group.Key).ToHashSet(StringComparer.Ordinal);
        // A hard-link alias is not evidence of a unique renamed source. In that
        // case preserve exact path rules, but never bind multiple paths to one
        // protected catalog item through an ambiguous filesystem identity.
        validAssignments = validAssignments.Select(assignment => assignment.FileSystemIdentity is { } identity
                && ambiguousFileIdentities.Contains(identity)
                    ? assignment with { FileSystemIdentity = null, FileSize = null, FileModifiedAt = null }
                    : assignment).ToList();
        // Partition supplemental/ignored overrides before automatic type detection:
        // an explicitly assigned interview must not supply false episode evidence.
        var automaticFiles = files.Files.Where(file =>
        {
            var assignment = FindAssignment(normalizedRoot, file, validAssignments);
            return assignment is null || assignment.Kind is MediaKind.Movie or MediaKind.Series;
        }).ToList();
        var effectiveDecisions = (classificationDecisions ?? []).ToList();
        var explicitMoviePaths = automaticFiles.Where(file =>
                FindAssignment(normalizedRoot, file, validAssignments) is { IsDirectory: false, Kind: MediaKind.Movie })
            .Select(file => file.Path).ToHashSet(StringComparer.Ordinal);
        effectiveDecisions.AddRange(validAssignments
            .Where(assignment => assignment.IsDirectory
                && assignment.Kind is MediaKind.Movie or MediaKind.Series)
            .Select(assignment => new ExistingClassificationDecision(
                assignment.RelativePath,
                assignment.Kind == MediaKind.Series
                    ? ClassificationDecision.TvShows : ClassificationDecision.Movie)));
        var result = kind switch
        {
            LibraryKind.Movies => ScanMovies(
                normalizedRoot, automaticFiles, files.Issues, existingMovies, importReviewDecisions),
            LibraryKind.TvShows => ScanTvShows(
                normalizedRoot,
                automaticFiles,
                files.Issues,
                existingEpisodes,
                existingMovies,
                importReviewDecisions),
            LibraryKind.Automatic => ScanAutomatic(
                normalizedRoot,
                automaticFiles,
                files.Issues,
                existingEpisodes,
                effectiveDecisions,
                existingMovies ?? [],
                importReviewDecisions ?? [],
                explicitMoviePaths),
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
        result = ApplyAssignments(normalizedRoot, files.Files, result, validAssignments, existingEpisodes);
        return result with
        {
            FilesDiscovered = files.Files.Count,
            SkippedFiles = files.Files.Count - result.Items.Count(item => item.IsFile),
            Files = files.Files.Select(file => new DiscoveredScanFile(
                file.Path, Path.GetExtension(file.Path).ToLowerInvariant(), file.Size,
                file.ModifiedAt, file.FileSystemIdentity)).ToList(),
        };
    }

    private static MediaScanDiscovery ScanAutomatic(
        string rootPath,
        IReadOnlyList<ScannedFile> files,
        IReadOnlyList<ScanDiscoveryIssue> enumerationIssues,
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes,
        IReadOnlyList<ExistingClassificationDecision> decisions,
        IReadOnlyList<ExistingMovieBinding> existingMovies,
        IReadOnlyList<ExistingImportReviewDecision> importReviewDecisions,
        HashSet<string> explicitMoviePaths)
    {
        var normalizedRoot = Path.GetFullPath(rootPath);
        var decisionByPath = decisions.GroupBy(
                decision => NormalizeRelativePath(decision.RelativePath), StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Last().Decision, StringComparer.Ordinal);
        var candidates = new List<AutomaticCandidate>();
        var index = DirectoryIndex.Create(normalizedRoot, files);
        DiscoverAutomaticCandidates(index, index.Root, decisionByPath, explicitMoviePaths, candidates, isRoot: true);

        var items = new List<DiscoveredMediaItem>();
        var importReviews = new List<DiscoveredImportReview>();
        var issues = new List<ScanDiscoveryIssue>(enumerationIssues);
        var classifications = new List<DiscoveredClassification>();
        var skipped = 0;

        foreach (var candidate in candidates.OrderBy(item => item.Path, StringComparer.Ordinal))
        {
            var relativePath = Path.GetRelativePath(normalizedRoot, candidate.Path);
            if (relativePath == ".")
            {
                relativePath = string.Empty;
            }

            ClassificationDecision? decision = decisionByPath.TryGetValue(
                NormalizeRelativePath(relativePath),
                out var storedDecision)
                ? storedDecision
                : null;
            LibraryKind? selectedKind = decision switch
            {
                ClassificationDecision.Movie => LibraryKind.Movies,
                ClassificationDecision.TvShows => LibraryKind.TvShows,
                ClassificationDecision.Ignore => null,
                _ => candidate.Kind,
            };
            var ignored = decision == ClassificationDecision.Ignore;
            var needsReview = !ignored && !selectedKind.HasValue;
            classifications.Add(new DiscoveredClassification(
                relativePath,
                candidate.Title,
                candidate.Kind,
                ignored ? "manual_ignore" : candidate.Reason,
                needsReview));

            if (ignored)
            {
                skipped += candidate.Files.Count;
                continue;
            }

            if (!selectedKind.HasValue)
            {
                skipped += candidate.Files.Count;
                issues.Add(new ScanDiscoveryIssue(
                    "classification_required",
                    "Choose Movie, TV Show, or Ignore for this folder.",
                    candidate.Path));
                continue;
            }

            var result = selectedKind == LibraryKind.Movies
                ? ScanMovies(candidate.Path, candidate.Files, [], existingMovies, importReviewDecisions)
                : ScanTvShows(
                    candidate.Path,
                    candidate.Files,
                    [],
                    existingEpisodes,
                    existingMovies: existingMovies,
                    importReviewDecisions: importReviewDecisions,
                    forceSeriesRoot: true,
                    allowImplicitEpisodes: decision == ClassificationDecision.TvShows);
            items.AddRange(result.Items);
            issues.AddRange(result.Issues);
            importReviews.AddRange(result.ImportReviews ?? []);
            skipped += result.SkippedFiles;
        }

        return new MediaScanDiscovery(
            items, issues, files.Count, skipped, classifications, importReviews);
    }

    private static void DiscoverAutomaticCandidates(
        DirectoryIndex index,
        IndexedDirectory directory,
        IReadOnlyDictionary<string, ClassificationDecision> decisions,
        HashSet<string> explicitMoviePaths,
        List<AutomaticCandidate> candidates,
        bool isRoot)
    {
        if (directory.FileCount == 0) return;
        var relativePath = Path.GetRelativePath(index.Root.Path, directory.Path);
        if (decisions.TryGetValue(NormalizeRelativePath(relativePath == "." ? "" : relativePath),
                out var decision))
        {
            candidates.Add(new AutomaticCandidate(directory.Path, DisplayTitle(directory.Path),
                decision switch
                {
                    ClassificationDecision.Movie => LibraryKind.Movies,
                    ClassificationDecision.TvShows => LibraryKind.TvShows,
                    _ => null,
                }, "manual_classification", directory.DescendantFiles()));
            return;
        }

        var children = directory.Children.Values.OrderBy(child => child.Path, StringComparer.Ordinal).ToList();
        var contentChildren = children.Where(child => !IsSupplementFolder(Path.GetFileName(child.Path))).ToList();
        var mainFiles = directory.Files.Where(file => !FilenameMetadataParser.IsExplicitTrailerFile(file.Path)
            && !FilenameMetadataParser.IsExplicitExtraFile(file.Path)).ToList();
        var hasEpisodeEvidence = mainFiles.Any(file =>
        {
            if (explicitMoviePaths.Contains(file.Path)) return false;
            var episode = FilenameMetadataParser.Episode(file.Path, null);
            return episode.Season.HasValue && episode.Episode.HasValue;
        });
        var hasSeasonStructure = mainFiles.Count == 0
            && contentChildren.Any(child => FilenameMetadataParser.SeasonNumber(Path.GetFileName(child.Path)).HasValue)
            && contentChildren.All(child => FilenameMetadataParser.SeasonNumber(Path.GetFileName(child.Path)).HasValue
                || child.IsSeasonWrapper());
        if (hasSeasonStructure || (hasEpisodeEvidence && contentChildren.Count == 0))
        {
            candidates.Add(new AutomaticCandidate(directory.Path, DisplayTitle(directory.Path),
                LibraryKind.TvShows, hasSeasonStructure ? "season_folders" : "episode_names",
                directory.DescendantFiles()));
            return;
        }

        var directCandidateFiles = directory.Files.Concat(children
                .Where(child => IsSupplementFolder(Path.GetFileName(child.Path)))
                .SelectMany(child => child.DescendantFiles()))
            .OrderBy(file => file.Path, StringComparer.Ordinal).ToList();
        if (hasEpisodeEvidence || mainFiles.Count > 1)
        {
            candidates.Add(new AutomaticCandidate(directory.Path, DisplayTitle(directory.Path), null,
                hasEpisodeEvidence ? "mixed_root_episode_files" : "multiple_unmatched_videos", directCandidateFiles));
        }
        else if (mainFiles.Count == 1)
        {
            candidates.Add(new AutomaticCandidate(directory.Path,
                FilenameMetadataParser.Movie(mainFiles[0].Path).Title, LibraryKind.Movies,
                "single_main_video", directCandidateFiles));
        }
        else if (directCandidateFiles.Count > 0)
        {
            // Scan as supplemental candidates, never as independent main titles.
            candidates.Add(new AutomaticCandidate(directory.Path, DisplayTitle(directory.Path), LibraryKind.Movies,
                "supplement_without_owner", directCandidateFiles));
        }

        foreach (var child in contentChildren)
            DiscoverAutomaticCandidates(index, child, decisions, explicitMoviePaths, candidates, false);

        if (directCandidateFiles.Count == 0 && contentChildren.Count == 0)
            candidates.Add(new AutomaticCandidate(directory.Path,
                isRoot ? new DirectoryInfo(index.Root.Path).Name : DisplayTitle(directory.Path), null,
                "unrecognized_structure", directory.DescendantFiles()));
    }

    private static string DisplayTitle(string path)
    {
        return FilenameMetadataParser.Series(path).Title;
    }

    private static string NormalizeRelativePath(string path)
    {
        return path.Replace(Path.AltDirectorySeparatorChar, Path.DirectorySeparatorChar)
            .Trim(Path.DirectorySeparatorChar)
            .Normalize(NormalizationForm.FormKC)
            .ToUpperInvariant();
    }

    private static List<ExistingImportAssignment> ValidateAssignments(
        string rootPath, IReadOnlyList<ExistingImportAssignment> assignments)
    {
        return assignments.Where(assignment => IsSafeRelativePath(rootPath, assignment.RelativePath)
                && (assignment.ParentRelativePath is null
                    || IsSafeRelativePath(rootPath, assignment.ParentRelativePath)))
            .GroupBy(assignment => (NormalizeRelativePath(assignment.RelativePath), assignment.IsDirectory))
            .Select(group => group.Last()).ToList();
    }

    private static bool IsSafeRelativePath(string rootPath, string relativePath)
    {
        if (Path.IsPathRooted(relativePath)
            || relativePath.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Contains(".."))
            return false;
        return MediaPath.IsSameOrDescendant(MediaPath.Normalize(Path.Combine(rootPath, relativePath)),
            MediaPath.Normalize(rootPath));
    }

    private static ExistingImportAssignment? FindAssignment(
        string rootPath, ScannedFile file, IReadOnlyList<ExistingImportAssignment> assignments)
    {
        var relative = NormalizeRelativePath(Path.GetRelativePath(rootPath, file.Path));
        return assignments.Where(assignment =>
            {
                var source = NormalizeRelativePath(assignment.RelativePath);
                if (!assignment.IsDirectory && assignment.FileSystemIdentity is not null
                    && assignment.FileSystemIdentity == file.FileSystemIdentity
                    && assignment.FileSize == file.Size && assignment.FileModifiedAt is { } modified
                    && Math.Abs((modified - file.ModifiedAt).TotalSeconds) <= 1)
                    return true;
                return assignment.IsDirectory
                    ? source.Length == 0 || relative.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.Ordinal)
                    : relative == source;
            })
            .OrderBy(assignment => assignment.IsDirectory)
            .ThenByDescending(assignment => assignment.FileSystemIdentity is not null)
            .ThenByDescending(assignment => assignment.RelativePath.Length)
            .FirstOrDefault();
    }

    private static MediaScanDiscovery ApplyAssignments(
        string rootPath, IReadOnlyList<ScannedFile> files, MediaScanDiscovery discovery,
        List<ExistingImportAssignment> assignments,
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes)
    {
        if (assignments.Count == 0) return discovery;
        var items = discovery.Items.ToDictionary(item => MediaPath.Normalize(item.SourcePath), StringComparer.Ordinal);
        var reviews = (discovery.ImportReviews ?? []).ToDictionary(
            review => MediaPath.Normalize(review.SourcePath), StringComparer.Ordinal);
        var issues = discovery.Issues.ToList();
        var assignedPaths = new HashSet<string>(StringComparer.Ordinal);
        var explicitEpisodeNumbers = new Dictionary<(string Parent, int Season, string RulePath), int>();

        foreach (var file in files.OrderBy(file => FindAssignment(rootPath, file, assignments)
                is { IsDirectory: false, Kind: MediaKind.Movie } ? 0 : 1)
            .ThenBy(file => file.Path, NaturalPathComparer))
        {
            var assignment = FindAssignment(rootPath, file, assignments);
            if (assignment is null) continue;
            var pathKey = MediaPath.Normalize(file.Path);
            assignedPaths.Add(pathKey);
            reviews.Remove(pathKey);
            items.TryGetValue(pathKey, out var detected);
            items.Remove(pathKey);
            if (assignment.Kind is null) continue;

            if (assignment.IsDirectory && assignment.Kind is MediaKind.Movie or MediaKind.Series)
            {
                // These folder rules steer classification above. Preserve resolver
                // episode numbers and supplemental context rather than flattening it.
                if (detected is not null) items[pathKey] = detected;
                continue;
            }

            string? parent = assignment.ParentRelativePath is null
                ? detected?.ParentSourcePath
                : Path.GetFullPath(Path.Combine(rootPath, assignment.ParentRelativePath));
            var kind = assignment.Kind.Value;
            if (kind is MediaKind.Extra or MediaKind.Trailer or MediaKind.Episode)
            {
                if (parent is null)
                {
                    reviews[pathKey] = new DiscoveredImportReview(file.Path,
                        FilenameMetadataParser.CleanTitle(Path.GetFileNameWithoutExtension(file.Path)),
                        "Choose a movie or series for this file.");
                    continue;
                }
                var parentKey = MediaPath.Normalize(parent);
                if (!items.TryGetValue(parentKey, out var owner))
                {
                    // A manually selected series directory is a valid preview owner,
                    // but only if it actually contains enumerated media (no free paths).
                    if (!files.Any(candidate => MediaPath.IsSameOrDescendant(
                            MediaPath.Normalize(candidate.Path), parentKey)) || File.Exists(parent))
                    {
                        reviews[pathKey] = new DiscoveredImportReview(file.Path,
                            FilenameMetadataParser.CleanTitle(Path.GetFileNameWithoutExtension(file.Path)),
                            "The selected parent is not a recognized movie or series in this storage location.");
                        continue;
                    }
                    var identity = FilenameMetadataParser.Series(parent);
                    owner = new DiscoveredMediaItem(MediaKind.Series, parent, null, identity.Title, identity.Year,
                        null, null, string.Empty, null, null, null);
                    items[parentKey] = owner;
                }
                if (owner.Kind is not (MediaKind.Movie or MediaKind.Series)
                    || kind == MediaKind.Episode && owner.Kind != MediaKind.Series
                    || owner.Kind == MediaKind.Movie && assignment.SeasonNumber.HasValue)
                {
                    reviews[pathKey] = new DiscoveredImportReview(file.Path,
                        FilenameMetadataParser.CleanTitle(Path.GetFileNameWithoutExtension(file.Path)),
                        "The selected parent and season do not match this content type.");
                    continue;
                }
            }
            else parent = null;

            var season = assignment.SeasonNumber;
            var episode = assignment.EpisodeNumber;
            if (kind == MediaKind.Episode && (!season.HasValue || !episode.HasValue))
            {
                reviews[pathKey] = new DiscoveredImportReview(file.Path,
                    FilenameMetadataParser.CleanTitle(Path.GetFileNameWithoutExtension(file.Path)),
                    "Choose a season and episode number for this file.");
                continue;
            }
            if (kind == MediaKind.Episode && assignment.IsDirectory)
            {
                var key = (parent!, season!.Value, NormalizeRelativePath(assignment.RelativePath));
                if (!explicitEpisodeNumbers.TryGetValue(key, out var next)) next = episode!.Value;
                episode = next;
                explicitEpisodeNumbers[key] = next + 1;
            }
            var title = assignment.Title ?? detected?.DetectedTitle
                ?? FilenameMetadataParser.CleanTitle(Path.GetFileNameWithoutExtension(file.Path));
            items[pathKey] = ToItem(file, kind, parent, title,
                kind == MediaKind.Movie ? FilenameMetadataParser.Movie(file.Path).Year : detected?.Year,
                season, episode, assignment.Category ?? detected?.Category ?? string.Empty);
        }

        foreach (var assignment in assignments.Where(value => value.IsDirectory && value.Kind == MediaKind.Series))
        {
            var key = MediaPath.Normalize(Path.Combine(rootPath, assignment.RelativePath));
            if (assignment.Title is not null && items.TryGetValue(key, out var series))
                items[key] = series with { DetectedTitle = assignment.Title };
        }

        foreach (var group in items.Values.Where(item => item.Kind == MediaKind.Episode).GroupBy(item =>
            (Parent: MediaPath.Normalize(item.ParentSourcePath!), item.SeasonNumber, item.EpisodeNumber))
            .Where(group => group.Count() > 1).ToList())
        {
            var binding = existingEpisodes.FirstOrDefault(value => MediaPath.Normalize(value.SeriesPath) == group.Key.Parent
                && value.SeasonNumber == group.Key.SeasonNumber && value.EpisodeNumber == group.Key.EpisodeNumber);
            foreach (var duplicate in group.Where(item => binding is null
                || MediaPath.Normalize(item.SourcePath) != MediaPath.Normalize(binding.FilePath)))
            {
                var key = MediaPath.Normalize(duplicate.SourcePath);
                items.Remove(key);
                reviews[key] = new DiscoveredImportReview(duplicate.SourcePath, duplicate.DetectedTitle,
                    "This season and episode number occurs more than once. Choose a unique episode number.");
            }
        }

        var accepted = items.Values.Where(item => item.IsFile).ToList();
        var acceptedPaths = accepted.Select(item => item.SourcePath).ToHashSet(StringComparer.Ordinal);
        var occupiedSeries = accepted.Where(item => item.ParentSourcePath is not null)
            .Select(item => MediaPath.Normalize(item.ParentSourcePath!)).ToHashSet(StringComparer.Ordinal);
        var finalItems = items.Values.Where(item => item.Kind != MediaKind.Series
                || occupiedSeries.Contains(MediaPath.Normalize(item.SourcePath)))
            .OrderBy(item => item.Kind == MediaKind.Series ? 0 : 1)
            .ThenBy(item => item.SourcePath, NaturalPathComparer).ToList();
        issues.RemoveAll(issue => issue.Path is not null && assignedPaths.Contains(MediaPath.Normalize(issue.Path)));
        var unresolved = files.Where(file => !acceptedPaths.Contains(file.Path)
            && (FindAssignment(rootPath, file, assignments) is not { Kind: null })).ToList();
        issues.RemoveAll(issue => issue.Code == "classification_required" && issue.Path is not null
            && !unresolved.Any(file => MediaPath.IsSameOrDescendant(MediaPath.Normalize(file.Path), MediaPath.Normalize(issue.Path))));
        return discovery with
        {
            Items = finalItems,
            ImportReviews = reviews.Values.ToList(),
            Issues = issues,
            SkippedFiles = files.Count - accepted.Count,
            Classifications = discovery.Classifications?.Select(classification => classification with
            {
                NeedsReview = classification.NeedsReview && unresolved.Any(file => MediaPath.IsSameOrDescendant(
                    MediaPath.Normalize(file.Path), MediaPath.Normalize(Path.Combine(rootPath, classification.RelativePath)))),
            }).ToList(),
        };
    }

    private static MediaScanDiscovery ScanMovies(
        string rootPath,
        IReadOnlyList<ScannedFile> files,
        IReadOnlyList<ScanDiscoveryIssue> enumerationIssues,
        IReadOnlyList<ExistingMovieBinding>? existingMovies = null,
        IReadOnlyList<ExistingImportReviewDecision>? importReviewDecisions = null)
    {
        var movies = new List<DiscoveredMediaItem>();
        var pendingSupplements = new List<PendingSupplement>();
        var pendingTrailers = new List<ScannedFile>();
        var issues = new List<ScanDiscoveryIssue>(enumerationIssues);
        var importReviews = new List<DiscoveredImportReview>();

        foreach (var file in files)
        {
            var context = FolderContext.Create(rootPath, file.Path);
            if (context.SupplementIndex is null && !FilenameMetadataParser.IsExplicitExtraFile(file.Path))
            {
                var identity = FilenameMetadataParser.Movie(file.Path);
                if (FilenameMetadataParser.IsExplicitTrailerFile(file.Path))
                {
                    pendingTrailers.Add(file);
                    continue;
                }

                movies.Add(ToItem(file, MediaKind.Movie, null, identity.Title, identity.Year));
                continue;
            }

            var ownerDirectory = context.SupplementIndex.HasValue
                ? CombineComponents(rootPath, context.DirectoryComponents.Take(context.SupplementIndex.Value))
                : Path.GetDirectoryName(file.Path)!;
            pendingSupplements.Add(new PendingSupplement(file, ownerDirectory, context));
        }

        var items = movies
            .OrderBy(movie => movie.SourcePath, NaturalPathComparer)
            .ToList();
        var movieCandidates = movies.Select(movie => new MovieCandidate(
                movie.SourcePath,
                movie.DetectedTitle,
                movie.Year))
            .Concat((existingMovies ?? []).Where(movie => File.Exists(movie.SourcePath)).Select(movie =>
            {
                var identity = FilenameMetadataParser.Movie(movie.SourcePath);
                return new MovieCandidate(movie.SourcePath, identity.Title, movie.Year ?? identity.Year);
            }))
            .DistinctBy(movie => MediaPath.Normalize(movie.SourcePath), StringComparer.Ordinal)
            .ToList();
        var decisions = (importReviewDecisions ?? []).ToDictionary(
            decision => MediaPath.Normalize(decision.SourcePath),
            StringComparer.Ordinal);
        var skipped = 0;
        foreach (var supplement in pendingSupplements)
        {
            var trailerDecision = decisions.GetValueOrDefault(
                MediaPath.Normalize(supplement.File.Path));
            if (supplement.Context.IsTrailer
                && trailerDecision?.State == LibraryImportReviewState.Ignored)
            {
                skipped++;
                continue;
            }

            if (supplement.Context.IsTrailer
                && trailerDecision?.State == LibraryImportReviewState.Assigned)
            {
                var assignedOwner = trailerDecision.ParentSourcePath is null
                    ? null
                    : movieCandidates.FirstOrDefault(candidate =>
                        MediaPath.Normalize(candidate.SourcePath)
                        == MediaPath.Normalize(trailerDecision.ParentSourcePath));
                if (assignedOwner is null)
                {
                    var identity = FilenameMetadataParser.Movie(supplement.File.Path);
                    AddUnresolvedTrailer(
                        supplement.File,
                        identity.Title,
                        "The selected movie is no longer available in this storage location.",
                        items,
                        importReviews,
                        issues);
                }
                else
                {
                    items.Add(ToItem(
                        supplement.File,
                        MediaKind.Trailer,
                        assignedOwner.SourcePath,
                        FilenameMetadataParser.SupplementTitle(
                            supplement.File.Path,
                            assignedOwner.Title),
                        category: supplement.Context.Category));
                }

                continue;
            }

            var directMatches = movies.Where(movie =>
                Path.GetDirectoryName(movie.SourcePath) is { } directory
                && MediaPath.Normalize(directory) == MediaPath.Normalize(supplement.OwnerDirectory))
                .ToList();
            var possibleOwners = directMatches.Count > 0
                ? directMatches
                : movies.Where(movie => MediaPath.IsSameOrDescendant(
                    MediaPath.Normalize(movie.SourcePath),
                    MediaPath.Normalize(supplement.OwnerDirectory))).ToList();

            if (possibleOwners.Count != 1)
            {
                if (supplement.Context.IsTrailer)
                {
                    var identity = FilenameMetadataParser.Movie(supplement.File.Path);
                    AddUnresolvedTrailer(
                        supplement.File,
                        identity.Title,
                        "The trailer could not be matched to exactly one movie in this storage location.",
                        items,
                        importReviews,
                        issues);
                    continue;
                }

                skipped += 1;
                importReviews.Add(new DiscoveredImportReview(supplement.File.Path,
                    FilenameMetadataParser.CleanTitle(Path.GetFileNameWithoutExtension(supplement.File.Path)),
                    "The extra could not be assigned to exactly one movie."));
                issues.Add(new ScanDiscoveryIssue(
                    "ambiguous_movie_extra",
                    "The extra could not be assigned to exactly one movie.",
                    supplement.File.Path));
                continue;
            }

            var owner = possibleOwners[0];
            var supplementIdentity = supplement.Context.IsTrailer
                ? FilenameMetadataParser.Movie(supplement.File.Path)
                : null;
            items.Add(ToItem(
                supplement.File,
                supplement.Context.IsTrailer ? MediaKind.Trailer : MediaKind.Extra,
                owner.SourcePath,
                supplementIdentity?.Title
                    ?? FilenameMetadataParser.SupplementTitle(
                        supplement.File.Path,
                        owner.DetectedTitle),
                supplementIdentity?.Year,
                category: supplement.Context.Category));
        }

        foreach (var trailer in pendingTrailers)
        {
            var identity = FilenameMetadataParser.Movie(trailer.Path);
            var normalizedPath = MediaPath.Normalize(trailer.Path);
            var titleKey = FilenameMetadataParser.NormalizeMatchTitle(identity.Title);
            var decision = decisions.GetValueOrDefault(normalizedPath);
            if (decision?.State == LibraryImportReviewState.Ignored)
            {
                skipped++;
                continue;
            }
            MovieCandidate? owner = null;
            if (decision?.State == LibraryImportReviewState.Assigned
                && decision.ParentSourcePath is not null)
            {
                owner = movieCandidates.FirstOrDefault(candidate =>
                    MediaPath.Normalize(candidate.SourcePath)
                    == MediaPath.Normalize(decision.ParentSourcePath));
            }
            else if (titleKey.Length > 0)
            {
                var matches = movieCandidates.Where(candidate =>
                        MediaPath.Normalize(candidate.SourcePath) != normalizedPath
                        && FilenameMetadataParser.NormalizeMatchTitle(candidate.Title) == titleKey
                        && (!identity.Year.HasValue || !candidate.Year.HasValue
                            || identity.Year == candidate.Year))
                    .ToList();
                if (matches.Count == 1)
                {
                    owner = matches[0];
                }

                // A standalone Trailer/Teaser in a title directory has an
                // unambiguous structural owner even without a title in its name.
                if (owner is null && identity.Title is "Trailer" or "Teaser")
                {
                    var directMatches = movieCandidates.Where(candidate =>
                        Path.GetDirectoryName(candidate.SourcePath) == Path.GetDirectoryName(trailer.Path)).ToList();
                    if (directMatches.Count == 1) owner = directMatches[0];
                }

                if (owner is null)
                {
                    var reason = matches.Count == 0
                        ? "No exact movie title match was found in this storage location."
                        : "More than one movie has this title in this storage location.";
                    AddUnresolvedTrailer(
                        trailer,
                        identity.Title,
                        reason,
                        items,
                        importReviews,
                        issues);
                    continue;
                }
            }

            var parentPath = owner?.SourcePath;
            if (decision?.State == LibraryImportReviewState.Assigned && owner is null)
            {
                AddUnresolvedTrailer(
                    trailer,
                    identity.Title,
                    "The selected movie is no longer available in this storage location.",
                    items,
                    importReviews,
                    issues);
                continue;
            }

            items.Add(ToItem(
                trailer,
                MediaKind.Trailer,
                parentPath,
                string.IsNullOrWhiteSpace(identity.Title) ? "Trailer" : identity.Title,
                identity.Year));
        }

        return new MediaScanDiscovery(items, issues, files.Count, skipped, ImportReviews: importReviews);
    }

    private static void AddUnresolvedTrailer(
        ScannedFile file,
        string title,
        string reason,
        List<DiscoveredMediaItem> items,
        List<DiscoveredImportReview> importReviews,
        List<ScanDiscoveryIssue> issues)
    {
        var readableTitle = string.IsNullOrWhiteSpace(title) ? "Trailer" : title;
        importReviews.Add(new DiscoveredImportReview(file.Path, readableTitle, reason));
        issues.Add(new ScanDiscoveryIssue("trailer_needs_review", reason, file.Path));
    }

    private sealed record MovieCandidate(string SourcePath, string Title, int? Year);

    private static MediaScanDiscovery ScanTvShows(
        string rootPath,
        IReadOnlyList<ScannedFile> files,
        IReadOnlyList<ScanDiscoveryIssue> enumerationIssues,
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes,
        IReadOnlyList<ExistingMovieBinding>? existingMovies = null,
        IReadOnlyList<ExistingImportReviewDecision>? importReviewDecisions = null,
        bool forceSeriesRoot = false,
        bool allowImplicitEpisodes = true)
    {
        var seriesByPath = new Dictionary<string, DiscoveredMediaItem>(StringComparer.Ordinal);
        var episodes = new List<DiscoveredMediaItem>();
        var implicitEpisodes = new List<PendingImplicitEpisode>();
        var supplements = new List<DiscoveredMediaItem>();
        var issues = new List<ScanDiscoveryIssue>(enumerationIssues);
        var importReviews = new List<DiscoveredImportReview>();
        var skipped = 0;
        var movieCandidates = (existingMovies ?? []).Where(movie => File.Exists(movie.SourcePath)).Select(movie =>
        {
            var identity = FilenameMetadataParser.Movie(movie.SourcePath);
            return new MovieCandidate(movie.SourcePath, identity.Title, movie.Year ?? identity.Year);
        }).ToList();
        var reviewDecisions = (importReviewDecisions ?? []).ToDictionary(
            decision => MediaPath.Normalize(decision.SourcePath),
            StringComparer.Ordinal);
        var contexts = files.ToDictionary(file => file.Path,
            file => FolderContext.Create(rootPath, file.Path), StringComparer.Ordinal);
        var structuralSeriesPaths = files.Where(file => !contexts[file.Path].SupplementIndex.HasValue
                && !FilenameMetadataParser.IsExplicitTrailerFile(file.Path)
                && !FilenameMetadataParser.IsExplicitExtraFile(file.Path))
            .Where(file => allowImplicitEpisodes || FilenameMetadataParser.Episode(file.Path,
                contexts[file.Path].SeasonIndex is { } seasonIndex
                    ? FilenameMetadataParser.SeasonNumber(contexts[file.Path].DirectoryComponents[seasonIndex])
                    : null).Episode.HasValue)
            .Select(file => MediaPath.Normalize(DetermineSeriesPath(rootPath, file.Path, contexts[file.Path])))
            .ToHashSet(StringComparer.Ordinal);

        foreach (var file in files)
        {
            var context = contexts[file.Path];
            var structuralSeriesPath = forceSeriesRoot ? rootPath : DetermineSeriesPath(rootPath, file.Path, context);
            var hasStructuralSeriesOwner = forceSeriesRoot
                || structuralSeriesPaths.Contains(MediaPath.Normalize(structuralSeriesPath));
            if (context.SupplementIndex is null
                && FilenameMetadataParser.IsExplicitTrailerFile(file.Path)
                && !hasStructuralSeriesOwner)
            {
                var trailerIdentity = FilenameMetadataParser.Movie(file.Path);
                var decision = reviewDecisions.GetValueOrDefault(MediaPath.Normalize(file.Path));
                if (decision?.State == LibraryImportReviewState.Ignored)
                {
                    skipped++;
                    continue;
                }
                MovieCandidate? owner = null;
                if (decision?.State == LibraryImportReviewState.Assigned
                    && decision.ParentSourcePath is not null)
                {
                    owner = movieCandidates.FirstOrDefault(candidate =>
                        MediaPath.Normalize(candidate.SourcePath)
                        == MediaPath.Normalize(decision.ParentSourcePath));
                }
                else if (decision?.State != LibraryImportReviewState.Ignored)
                {
                    var titleKey = FilenameMetadataParser.NormalizeMatchTitle(trailerIdentity.Title);
                    var matches = movieCandidates.Where(candidate =>
                            titleKey.Length > 0
                            && FilenameMetadataParser.NormalizeMatchTitle(candidate.Title) == titleKey
                            && (!trailerIdentity.Year.HasValue || !candidate.Year.HasValue
                                || trailerIdentity.Year == candidate.Year))
                        .ToList();
                    if (matches.Count == 1) owner = matches[0];
                    else
                    {
                        AddUnresolvedTrailer(
                            file,
                            trailerIdentity.Title,
                            matches.Count == 0
                                ? "No exact movie title match was found in this storage location."
                                : "More than one movie has this title in this storage location.",
                            supplements,
                            importReviews,
                            issues);
                        continue;
                    }
                }

                if (decision?.State == LibraryImportReviewState.Assigned && owner is null)
                {
                    AddUnresolvedTrailer(
                        file,
                        trailerIdentity.Title,
                        "The selected movie is no longer available in this storage location.",
                        supplements,
                        importReviews,
                        issues);
                    continue;
                }

                supplements.Add(ToItem(
                    file,
                    MediaKind.Trailer,
                    owner?.SourcePath,
                    string.IsNullOrWhiteSpace(trailerIdentity.Title) ? "Trailer" : trailerIdentity.Title,
                    trailerIdentity.Year));
                continue;
            }

            var seriesPath = forceSeriesRoot
                ? rootPath
                : DetermineSeriesPath(rootPath, file.Path, context);
            var normalizedSeriesPath = MediaPath.Normalize(seriesPath);
            if (!seriesByPath.TryGetValue(normalizedSeriesPath, out var seriesItem))
            {
                var seriesIdentity = FilenameMetadataParser.Series(seriesPath);
                seriesItem = new DiscoveredMediaItem(
                    MediaKind.Series,
                    seriesPath,
                    null,
                    seriesIdentity.Title,
                    seriesIdentity.Year,
                    null,
                    null,
                    string.Empty,
                    null,
                    null,
                    null);
                seriesByPath[normalizedSeriesPath] = seriesItem;
            }

            var season = context.SeasonIndex.HasValue
                ? FilenameMetadataParser.SeasonNumber(
                    context.DirectoryComponents[context.SeasonIndex.Value])
                : null;
            if (context.SupplementIndex.HasValue || context.IsTrailer || FilenameMetadataParser.IsExplicitExtraFile(file.Path))
            {
                var seriesTitle = seriesItem.DetectedTitle;
                supplements.Add(ToItem(
                    file,
                    context.IsTrailer ? MediaKind.Trailer : MediaKind.Extra,
                    seriesPath,
                    FilenameMetadataParser.SupplementTitle(file.Path, seriesTitle),
                    seasonNumber: season,
                    category: context.Category));
                continue;
            }

            var identity = FilenameMetadataParser.Episode(file.Path, season);
            if (!identity.Season.HasValue || !identity.Episode.HasValue)
            {
                if (!allowImplicitEpisodes)
                {
                    skipped++;
                    const string reason = "No usable episode number was found. Choose Extra, Trailer, an episode number, or explicitly use natural ordering.";
                    importReviews.Add(new DiscoveredImportReview(file.Path, identity.Title, reason));
                    issues.Add(new ScanDiscoveryIssue("episode_needs_review", reason, file.Path));
                    continue;
                }
                // A fixed TV library, or a folder explicitly classified as a TV show,
                // is an explicit request to import these files as episodes. When the
                // name contains no usable number, use the stable natural file order
                // below instead of silently dropping the media.
                implicitEpisodes.Add(new PendingImplicitEpisode(
                    file,
                    seriesPath,
                    season ?? 1,
                    identity.Title));
                continue;
            }

            if (season.HasValue && season != identity.Season)
            {
                skipped += 1;
                issues.Add(new ScanDiscoveryIssue(
                    "season_mismatch",
                    "The season in the filename does not match its folder.",
                    file.Path));
                importReviews.Add(new DiscoveredImportReview(file.Path, identity.Title,
                    "The season in the filename does not match its folder."));
                continue;
            }

            episodes.Add(ToItem(
                file,
                MediaKind.Episode,
                seriesPath,
                identity.Title,
                seasonNumber: identity.Season,
                episodeNumber: identity.Episode));
        }

        foreach (var group in implicitEpisodes.GroupBy(episode => new
        {
            Series = MediaPath.Normalize(episode.SeriesPath),
            episode.SeasonNumber,
        }))
        {
            var usedNumbers = episodes
                .Where(episode => MediaPath.Normalize(episode.ParentSourcePath!) == group.Key.Series
                    && episode.SeasonNumber == group.Key.SeasonNumber
                    && episode.EpisodeNumber.HasValue)
                .Select(episode => episode.EpisodeNumber!.Value)
                .ToHashSet();
            var nextEpisode = 1;
            var unbound = new List<PendingImplicitEpisode>();
            foreach (var pending in group)
            {
                var binding = existingEpisodes.FirstOrDefault(value =>
                    MediaPath.Normalize(value.SeriesPath) == group.Key.Series
                    && value.SeasonNumber == group.Key.SeasonNumber
                    && MediaPath.Normalize(value.FilePath) == MediaPath.Normalize(pending.File.Path)
                    && !usedNumbers.Contains(value.EpisodeNumber));
                if (binding is null) unbound.Add(pending);
                else
                {
                    usedNumbers.Add(binding.EpisodeNumber);
                    episodes.Add(ToItem(pending.File, MediaKind.Episode, pending.SeriesPath, pending.Title,
                        seasonNumber: pending.SeasonNumber, episodeNumber: binding.EpisodeNumber));
                }
            }
            foreach (var pending in unbound.OrderBy(episode => episode.File.Path, NaturalPathComparer))
            {
                while (usedNumbers.Contains(nextEpisode)) nextEpisode++;
                usedNumbers.Add(nextEpisode);
                episodes.Add(ToItem(
                    pending.File,
                    MediaKind.Episode,
                    pending.SeriesPath,
                    pending.Title,
                    seasonNumber: pending.SeasonNumber,
                    episodeNumber: nextEpisode));
                nextEpisode++;
            }
        }

        var acceptedEpisodes = new List<DiscoveredMediaItem>();
        foreach (var group in episodes.GroupBy(episode => new
        {
            Series = MediaPath.Normalize(episode.ParentSourcePath!),
            episode.SeasonNumber,
            episode.EpisodeNumber,
        }))
        {
            var candidates = group.OrderBy(candidate => candidate.SourcePath, StringComparer.Ordinal)
                .ToList();
            if (candidates.Count == 1)
            {
                acceptedEpisodes.Add(candidates[0]);
                continue;
            }

            var existingPath = existingEpisodes.FirstOrDefault(binding =>
                MediaPath.Normalize(binding.SeriesPath) == group.Key.Series
                && binding.SeasonNumber == group.Key.SeasonNumber
                && binding.EpisodeNumber == group.Key.EpisodeNumber)?.FilePath;
            var preferred = existingPath is null
                ? null
                : candidates.SingleOrDefault(candidate =>
                    MediaPath.Normalize(candidate.SourcePath) == MediaPath.Normalize(existingPath));
            if (preferred is not null)
            {
                acceptedEpisodes.Add(preferred);
            }

            foreach (var candidate in candidates.Where(candidate => candidate != preferred))
            {
                skipped += 1;
                issues.Add(new ScanDiscoveryIssue(
                    "duplicate_episode",
                    "This season and episode number occurs more than once.",
                    candidate.SourcePath));
                importReviews.Add(new DiscoveredImportReview(candidate.SourcePath, candidate.DetectedTitle,
                    "This season and episode number occurs more than once."));
            }
        }

        var items = seriesByPath.Values
            .OrderBy(series => series.SourcePath, NaturalPathComparer)
            .Concat(acceptedEpisodes
                .OrderBy(episode => episode.SeasonNumber)
                .ThenBy(episode => episode.EpisodeNumber)
                .ThenBy(episode => episode.SourcePath, NaturalPathComparer))
            .Concat(supplements
                .OrderBy(supplement => supplement.SeasonNumber)
                .ThenBy(supplement => supplement.SourcePath, NaturalPathComparer))
            .ToList();
        return new MediaScanDiscovery(
            items, issues, files.Count, skipped, ImportReviews: importReviews);
    }

    private static string DetermineSeriesPath(
        string rootPath,
        string filePath,
        FolderContext context)
    {
        var boundary = new[] { context.SeasonIndex, context.SupplementIndex }
            .Where(index => index.HasValue)
            .Select(index => index!.Value)
            .DefaultIfEmpty(-1)
            .Min();
        if (boundary >= 0)
        {
            return CombineComponents(rootPath, context.DirectoryComponents.Take(boundary));
        }

        return context.DirectoryComponents.Count == 0
            ? rootPath
            : Path.GetDirectoryName(filePath)!;
    }

    private static DiscoveredMediaItem ToItem(
        ScannedFile file,
        MediaKind kind,
        string? parentSourcePath,
        string title,
        int? year = null,
        int? seasonNumber = null,
        int? episodeNumber = null,
        string category = "")
    {
        return new DiscoveredMediaItem(
            kind,
            file.Path,
            parentSourcePath,
            title,
            year,
            seasonNumber,
            episodeNumber,
            category,
            Path.GetExtension(file.Path).ToLowerInvariant(),
            file.Size,
            file.ModifiedAt,
            file.FileSystemIdentity);
    }

    private static EnumerationResult EnumerateVideoFiles(
        string rootPath,
        Action<int>? progress,
        CancellationToken cancellationToken)
    {
        var files = new List<ScannedFile>();
        var issues = new List<ScanDiscoveryIssue>();
        var pending = new Stack<DirectoryInfo>();
        pending.Push(new DirectoryInfo(rootPath));

        while (pending.Count > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var directory = pending.Pop();
            FileSystemInfo[] entries;
            try
            {
                entries = directory.EnumerateFileSystemInfos()
                    .OrderBy(entry => entry.FullName, StringComparer.Ordinal)
                    .ToArray();
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                issues.Add(new ScanDiscoveryIssue(
                    "unreadable_directory",
                    "A directory could not be read.",
                    directory.FullName));
                continue;
            }

            foreach (var entry in entries)
            {
                cancellationToken.ThrowIfCancellationRequested();
                bool shouldSkip;
                try
                {
                    shouldSkip = ShouldSkip(entry);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    issues.Add(new ScanDiscoveryIssue(
                        "unreadable_entry",
                        "A filesystem entry could not be inspected.",
                        entry.FullName));
                    continue;
                }

                if (shouldSkip)
                {
                    continue;
                }

                if (entry is DirectoryInfo childDirectory)
                {
                    pending.Push(childDirectory);
                    continue;
                }

                if (entry is not FileInfo file
                    || !SupportedExtensions.Contains(file.Extension))
                {
                    continue;
                }

                try
                {
                    file.Refresh();
                    var modifiedAt = new DateTimeOffset(file.LastWriteTimeUtc, TimeSpan.Zero);
                    files.Add(new ScannedFile(
                        Path.GetFullPath(file.FullName),
                        file.Length,
                        DateTimeOffset.FromUnixTimeMilliseconds(
                            modifiedAt.ToUnixTimeMilliseconds()),
                        FileSystemIdentity.TryRead(file.FullName)));
                    progress?.Invoke(files.Count);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    issues.Add(new ScanDiscoveryIssue(
                        "unreadable_file",
                        "A video file's metadata could not be read.",
                        file.FullName));
                }
            }
        }

        return new EnumerationResult(
            files.OrderBy(file => file.Path, StringComparer.Ordinal).ToList(),
            issues);
    }

    private static bool ShouldSkip(FileSystemInfo entry)
    {
        if (entry.Name.StartsWith('.')
            || (entry.Attributes & (FileAttributes.Hidden | FileAttributes.ReparsePoint)) != 0)
        {
            return true;
        }

        return entry is DirectoryInfo && PackageExtensions.Contains(entry.Extension);
    }

    private static string CombineComponents(string rootPath, IEnumerable<string> components)
    {
        return components.Aggregate(Path.GetFullPath(rootPath), Path.Combine);
    }

    private static bool IsSupplementFolder(string value)
    {
        var normalized = FilenameMetadataParser.NormalizeFolderToken(
            Regex.Replace(value, @"[\s._-]+\d+(?:[._-]\d+)*$", string.Empty,
                RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100)));
        return ExtrasFolderNames.Contains(normalized) || TrailerFolderNames.Contains(normalized);
    }

    private static bool IsTrailerToken(string value)
    {
        var normalized = FilenameMetadataParser.NormalizeFolderToken(value);
        return TrailerFolderNames.Contains(normalized)
            || FilenameMetadataParser.IsExplicitTrailerFile(value);
    }

    private sealed record ScannedFile(
        string Path,
        long Size,
        DateTimeOffset ModifiedAt,
        string? FileSystemIdentity);

    private sealed record EnumerationResult(
        IReadOnlyList<ScannedFile> Files,
        IReadOnlyList<ScanDiscoveryIssue> Issues);

    private sealed record PendingSupplement(
        ScannedFile File,
        string OwnerDirectory,
        FolderContext Context);

    private sealed record PendingImplicitEpisode(
        ScannedFile File,
        string SeriesPath,
        int SeasonNumber,
        string Title);

    private sealed record AutomaticCandidate(
        string Path,
        string Title,
        LibraryKind? Kind,
        string Reason,
        IReadOnlyList<ScannedFile> Files);

    private sealed class DirectoryIndex
    {
        private DirectoryIndex(IndexedDirectory root) => Root = root;
        public IndexedDirectory Root { get; }

        public static DirectoryIndex Create(string rootPath, IReadOnlyList<ScannedFile> files)
        {
            var root = new IndexedDirectory(rootPath);
            foreach (var file in files)
            {
                var relative = Path.GetRelativePath(rootPath, file.Path);
                var components = relative.Split(Path.DirectorySeparatorChar);
                var node = root;
                node.FileCount++;
                foreach (var component in components.Take(components.Length - 1))
                {
                    if (!node.Children.TryGetValue(component, out var child))
                    {
                        child = new IndexedDirectory(Path.Combine(node.Path, component));
                        node.Children[component] = child;
                    }
                    node = child;
                    node.FileCount++;
                }
                node.Files.Add(file);
            }
            return new DirectoryIndex(root);
        }
    }

    private sealed class IndexedDirectory(string path)
    {
        public string Path { get; } = path;
        public int FileCount { get; set; }
        public List<ScannedFile> Files { get; } = [];
        public Dictionary<string, IndexedDirectory> Children { get; } = new(StringComparer.Ordinal);

        public List<ScannedFile> DescendantFiles()
        {
            var result = new List<ScannedFile>(FileCount);
            var pending = new Stack<IndexedDirectory>();
            pending.Push(this);
            while (pending.TryPop(out var directory))
            {
                result.AddRange(directory.Files);
                foreach (var child in directory.Children.Values) pending.Push(child);
            }
            return result;
        }

        public bool IsSeasonWrapper()
        {
            var contentChildren = Children.Values.Where(child => !IsSupplementFolder(System.IO.Path.GetFileName(child.Path))).ToList();
            return Files.Count == 0 && contentChildren.Count > 0
                && contentChildren.All(child => FilenameMetadataParser.SeasonNumber(System.IO.Path.GetFileName(child.Path)).HasValue);
        }
    }

    private sealed record FolderContext(
        IReadOnlyList<string> DirectoryComponents,
        int? SeasonIndex,
        int? SupplementIndex,
        bool IsTrailer,
        string Category)
    {
        public static FolderContext Create(string rootPath, string filePath)
        {
            var relativeDirectory = Path.GetDirectoryName(Path.GetRelativePath(rootPath, filePath));
            var components = string.IsNullOrEmpty(relativeDirectory) || relativeDirectory == "."
                ? []
                : relativeDirectory.Split(Path.DirectorySeparatorChar).ToList();
            var seasonIndex = components.FindLastIndex(component =>
                FilenameMetadataParser.SeasonNumber(component).HasValue);
            var supplementIndex = components.FindIndex(IsSupplementFolder);
            var trailerTokens = components.Append(Path.GetFileName(filePath)).ToList();
            var isTrailer = trailerTokens.Any(IsTrailerToken);
            var category = supplementIndex < 0 || isTrailer
                ? string.Empty
                : string.Join(
                    " / ",
                    components.Skip(supplementIndex + 1).Where(component =>
                        !IsTrailerToken(component) && !FilenameMetadataParser.SeasonNumber(component).HasValue));
            return new FolderContext(
                components,
                seasonIndex < 0 ? null : seasonIndex,
                supplementIndex < 0 ? null : supplementIndex,
                isTrailer,
                category);
        }
    }
}
