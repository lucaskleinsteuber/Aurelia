using System.Text;
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
    IReadOnlyList<DiscoveredImportReview>? ImportReviews = null);

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
        IReadOnlyList<ExistingImportReviewDecision>? importReviewDecisions = null);
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
        "specialfeatures",
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
        IReadOnlyList<ExistingImportReviewDecision>? importReviewDecisions = null)
    {
        var files = EnumerateVideoFiles(rootPath, progress, cancellationToken);
        return kind switch
        {
            LibraryKind.Movies => ScanMovies(
                rootPath, files.Files, files.Issues, existingMovies, importReviewDecisions),
            LibraryKind.TvShows => ScanTvShows(
                rootPath,
                files.Files,
                files.Issues,
                existingEpisodes,
                existingMovies,
                importReviewDecisions),
            LibraryKind.Automatic => ScanAutomatic(
                rootPath,
                files.Files,
                files.Issues,
                existingEpisodes,
                classificationDecisions ?? [],
                existingMovies ?? [],
                importReviewDecisions ?? []),
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
    }

    private static MediaScanDiscovery ScanAutomatic(
        string rootPath,
        IReadOnlyList<ScannedFile> files,
        IReadOnlyList<ScanDiscoveryIssue> enumerationIssues,
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes,
        IReadOnlyList<ExistingClassificationDecision> decisions,
        IReadOnlyList<ExistingMovieBinding> existingMovies,
        IReadOnlyList<ExistingImportReviewDecision> importReviewDecisions)
    {
        var normalizedRoot = Path.GetFullPath(rootPath);
        var decisionByPath = decisions.ToDictionary(
            decision => NormalizeRelativePath(decision.RelativePath),
            decision => decision.Decision,
            StringComparer.Ordinal);
        var candidates = new List<AutomaticCandidate>();
        DiscoverAutomaticCandidates(normalizedRoot, normalizedRoot, files, candidates, isRoot: true);

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
                candidate.Reason,
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
                    forceSeriesRoot: true);
            items.AddRange(result.Items);
            issues.AddRange(result.Issues);
            importReviews.AddRange(result.ImportReviews ?? []);
            skipped += result.SkippedFiles;
        }

        return new MediaScanDiscovery(
            items, issues, files.Count, skipped, classifications, importReviews);
    }

    private static void DiscoverAutomaticCandidates(
        string storageRoot,
        string directoryPath,
        IReadOnlyList<ScannedFile> files,
        List<AutomaticCandidate> candidates,
        bool isRoot)
    {
        var normalizedDirectory = MediaPath.Normalize(directoryPath);
        var containedFiles = files.Where(file => MediaPath.IsSameOrDescendant(
            MediaPath.Normalize(file.Path),
            normalizedDirectory)).ToList();
        if (containedFiles.Count == 0)
        {
            return;
        }

        var directFiles = containedFiles.Where(file =>
            MediaPath.Normalize(Path.GetDirectoryName(file.Path)!) == normalizedDirectory).ToList();
        var immediateDirectories = containedFiles
            .Select(file => FirstDirectoryBelow(directoryPath, file.Path))
            .Where(path => path is not null)
            .Select(path => path!)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(path => path, StringComparer.Ordinal)
            .ToList();
        var immediateSeasonDirectories = immediateDirectories.Where(path =>
            FilenameMetadataParser.SeasonNumber(Path.GetFileName(path)).HasValue).ToList();
        var contentDirectories = immediateDirectories.Where(path =>
            !IsSupplementFolder(Path.GetFileName(path))).ToList();
        var directEpisodeEvidence = directFiles.Any(file =>
        {
            var episode = FilenameMetadataParser.Episode(file.Path, null);
            return episode.Season.HasValue && episode.Episode.HasValue;
        });
        var seasonStructureIsComplete = contentDirectories.Count > 0
            && directFiles.Count == 0
            && immediateSeasonDirectories.Count > 0
            && contentDirectories.All(path =>
                IsSeasonFolder(path) || HasImmediateSeasonStructure(path, containedFiles));
        if (seasonStructureIsComplete
            || (directEpisodeEvidence && contentDirectories.Count == 0))
        {
            candidates.Add(new AutomaticCandidate(
                directoryPath,
                DisplayTitle(directoryPath),
                LibraryKind.TvShows,
                seasonStructureIsComplete ? "season_folders" : "episode_names",
                containedFiles));
            return;
        }

        var directMainFiles = directFiles.Where(file =>
                !IsSupplementPath(directoryPath, file.Path)
                && !FilenameMetadataParser.IsExplicitTrailerFile(file.Path))
            .ToList();
        var directCandidateFiles = directFiles.Concat(
            immediateDirectories
                .Where(path => IsSupplementFolder(Path.GetFileName(path)))
                .SelectMany(path => containedFiles.Where(file => MediaPath.IsSameOrDescendant(
                    MediaPath.Normalize(file.Path),
                    MediaPath.Normalize(path)))))
            .DistinctBy(file => file.Path, StringComparer.Ordinal)
            .OrderBy(file => file.Path, StringComparer.Ordinal)
            .ToList();

        var hasTrailerWithoutMovie = contentDirectories.Count == 0
            && directMainFiles.Count == 0
            && directCandidateFiles.Any(file =>
                FolderContext.Create(directoryPath, file.Path).IsTrailer);
        if (directEpisodeEvidence)
        {
            candidates.Add(new AutomaticCandidate(
                directoryPath,
                DisplayTitle(directoryPath),
                null,
                "mixed_root_episode_files",
                directCandidateFiles));
        }
        else if (directMainFiles.Count == 1)
        {
            candidates.Add(new AutomaticCandidate(
                directoryPath,
                FilenameMetadataParser.Movie(directMainFiles[0].Path).Title,
                LibraryKind.Movies,
                "single_main_video",
                directCandidateFiles));
        }
        else if (directMainFiles.Count > 1)
        {
            candidates.Add(new AutomaticCandidate(
                directoryPath,
                DisplayTitle(directoryPath),
                null,
                "multiple_unmatched_videos",
                directCandidateFiles));
        }
        else if (hasTrailerWithoutMovie)
        {
            candidates.Add(new AutomaticCandidate(
                directoryPath,
                DisplayTitle(directoryPath),
                LibraryKind.Movies,
                "trailer_without_movie",
                directCandidateFiles));
        }

        if (contentDirectories.Count > 0)
        {
            foreach (var child in contentDirectories)
            {
                DiscoverAutomaticCandidates(storageRoot, child, containedFiles, candidates, false);
            }

            return;
        }

        if (directMainFiles.Count > 0 || hasTrailerWithoutMovie)
        {
            return;
        }

        candidates.Add(new AutomaticCandidate(
            directoryPath,
            isRoot ? new DirectoryInfo(storageRoot).Name : DisplayTitle(directoryPath),
            null,
            "unrecognized_structure",
            containedFiles));
    }

    private static string? FirstDirectoryBelow(string rootPath, string filePath)
    {
        var relative = Path.GetRelativePath(rootPath, filePath);
        var components = relative.Split(Path.DirectorySeparatorChar);
        return components.Length < 2 ? null : Path.Combine(rootPath, components[0]);
    }

    private static bool IsSeasonFolder(string path)
    {
        return FilenameMetadataParser.SeasonNumber(Path.GetFileName(path)).HasValue;
    }

    private static bool HasImmediateSeasonStructure(
        string directoryPath,
        IReadOnlyList<ScannedFile> files)
    {
        var normalizedDirectory = MediaPath.Normalize(directoryPath);
        var immediateDirectories = files
            .Where(file => MediaPath.IsSameOrDescendant(
                MediaPath.Normalize(file.Path),
                normalizedDirectory))
            .Select(file => FirstDirectoryBelow(directoryPath, file.Path))
            .Where(path => path is not null)
            .Select(path => path!)
            .Distinct(StringComparer.Ordinal)
            .Where(path => !IsSupplementFolder(Path.GetFileName(path)))
            .ToList();
        return immediateDirectories.Count > 0 && immediateDirectories.All(IsSeasonFolder);
    }

    private static bool IsSupplementPath(string rootPath, string filePath)
    {
        return FolderContext.Create(rootPath, filePath).SupplementIndex.HasValue;
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
            if (context.SupplementIndex is null)
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

            var ownerDirectory = CombineComponents(
                rootPath,
                context.DirectoryComponents.Take(context.SupplementIndex.Value));
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
                var ignoredIdentity = FilenameMetadataParser.Movie(supplement.File.Path);
                items.Add(ToItem(
                    supplement.File,
                    MediaKind.Trailer,
                    null,
                    ignoredIdentity.Title,
                    ignoredIdentity.Year,
                    category: supplement.Context.Category));
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
            MovieCandidate? owner = null;
            if (decision?.State == LibraryImportReviewState.Assigned
                && decision.ParentSourcePath is not null)
            {
                owner = movieCandidates.FirstOrDefault(candidate =>
                    MediaPath.Normalize(candidate.SourcePath)
                    == MediaPath.Normalize(decision.ParentSourcePath));
            }
            else if (decision?.State != LibraryImportReviewState.Ignored && titleKey.Length > 0)
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
        items.Add(ToItem(file, MediaKind.Trailer, null, readableTitle));
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
        bool forceSeriesRoot = false)
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

        foreach (var file in files)
        {
            var context = FolderContext.Create(rootPath, file.Path);
            if (context.SupplementIndex is null
                && FilenameMetadataParser.IsExplicitTrailerFile(file.Path))
            {
                var trailerIdentity = FilenameMetadataParser.Movie(file.Path);
                var decision = reviewDecisions.GetValueOrDefault(MediaPath.Normalize(file.Path));
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
            if (context.SupplementIndex.HasValue)
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
            foreach (var pending in group.OrderBy(episode => episode.File.Path, NaturalPathComparer))
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
        var normalized = FilenameMetadataParser.NormalizeFolderToken(value);
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
            var trailerTokens = components.Append(Path.GetFileNameWithoutExtension(filePath)).ToList();
            var isTrailer = trailerTokens.Any(IsTrailerToken);
            var category = supplementIndex < 0 || isTrailer
                ? string.Empty
                : string.Join(
                    " / ",
                    components.Skip(supplementIndex + 1).Where(component => !IsTrailerToken(component)));
            return new FolderContext(
                components,
                seasonIndex < 0 ? null : seasonIndex,
                supplementIndex < 0 ? null : supplementIndex,
                isTrailer,
                category);
        }
    }
}
