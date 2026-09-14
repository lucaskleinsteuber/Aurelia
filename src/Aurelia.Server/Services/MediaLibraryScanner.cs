using System.Text;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public sealed record ExistingEpisodeBinding(
    string SeriesPath,
    int SeasonNumber,
    int EpisodeNumber,
    string FilePath);

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
    DateTimeOffset? FileModifiedAt)
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
    IReadOnlyList<DiscoveredClassification>? Classifications = null);

public interface IMediaLibraryScanner
{
    MediaScanDiscovery Scan(
        string rootPath,
        LibraryKind kind,
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes,
        Action<int>? progress,
        CancellationToken cancellationToken,
        IReadOnlyList<ExistingClassificationDecision>? classificationDecisions = null);
}

public sealed class MediaLibraryScanner : IMediaLibraryScanner
{
    private static readonly HashSet<string> SupportedExtensions = new(
        [".mkv", ".mp4", ".mov", ".m4v", ".avi", ".webm"],
        StringComparer.OrdinalIgnoreCase);

    private static readonly HashSet<string> ExtrasFolderNames =
    [
        "extra",
        "extras",
        "bonus",
        "bonusmaterial",
        "specialfeatures",
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
        IReadOnlyList<ExistingClassificationDecision>? classificationDecisions = null)
    {
        var files = EnumerateVideoFiles(rootPath, progress, cancellationToken);
        return kind switch
        {
            LibraryKind.Movies => ScanMovies(rootPath, files.Files, files.Issues),
            LibraryKind.TvShows => ScanTvShows(
                rootPath,
                files.Files,
                files.Issues,
                existingEpisodes),
            LibraryKind.Automatic => ScanAutomatic(
                rootPath,
                files.Files,
                files.Issues,
                existingEpisodes,
                classificationDecisions ?? []),
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
    }

    private static MediaScanDiscovery ScanAutomatic(
        string rootPath,
        IReadOnlyList<ScannedFile> files,
        IReadOnlyList<ScanDiscoveryIssue> enumerationIssues,
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes,
        IReadOnlyList<ExistingClassificationDecision> decisions)
    {
        var normalizedRoot = Path.GetFullPath(rootPath);
        var decisionByPath = decisions.ToDictionary(
            decision => NormalizeRelativePath(decision.RelativePath),
            decision => decision.Decision,
            StringComparer.Ordinal);
        var candidates = new List<AutomaticCandidate>();
        DiscoverAutomaticCandidates(normalizedRoot, normalizedRoot, files, candidates, isRoot: true);

        var items = new List<DiscoveredMediaItem>();
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
                ? ScanMovies(candidate.Path, candidate.Files, [])
                : ScanTvShows(
                    candidate.Path,
                    candidate.Files,
                    [],
                    existingEpisodes,
                    forceSeriesRoot: true);
            items.AddRange(result.Items);
            issues.AddRange(result.Issues);
            skipped += result.SkippedFiles;
        }

        return new MediaScanDiscovery(items, issues, files.Count, skipped, classifications);
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
            !IsExtrasFolder(Path.GetFileName(path))).ToList();
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

        var directMainFiles = directFiles.Where(file => !IsSupplementPath(directoryPath, file.Path))
            .ToList();
        var directCandidateFiles = directFiles.Concat(
            immediateDirectories
                .Where(path => IsExtrasFolder(Path.GetFileName(path)))
                .SelectMany(path => containedFiles.Where(file => MediaPath.IsSameOrDescendant(
                    MediaPath.Normalize(file.Path),
                    MediaPath.Normalize(path)))))
            .DistinctBy(file => file.Path, StringComparer.Ordinal)
            .OrderBy(file => file.Path, StringComparer.Ordinal)
            .ToList();

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

        if (contentDirectories.Count > 0)
        {
            foreach (var child in contentDirectories)
            {
                DiscoverAutomaticCandidates(storageRoot, child, containedFiles, candidates, false);
            }

            return;
        }

        if (directMainFiles.Count > 0)
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
            .Where(path => !IsExtrasFolder(Path.GetFileName(path)))
            .ToList();
        return immediateDirectories.Count > 0 && immediateDirectories.All(IsSeasonFolder);
    }

    private static bool IsSupplementPath(string rootPath, string filePath)
    {
        return FolderContext.Create(rootPath, filePath).ExtrasIndex.HasValue;
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
        IReadOnlyList<ScanDiscoveryIssue> enumerationIssues)
    {
        var movies = new List<DiscoveredMediaItem>();
        var pendingSupplements = new List<PendingSupplement>();
        var issues = new List<ScanDiscoveryIssue>(enumerationIssues);

        foreach (var file in files)
        {
            var context = FolderContext.Create(rootPath, file.Path);
            if (context.ExtrasIndex is null)
            {
                var identity = FilenameMetadataParser.Movie(file.Path);
                movies.Add(ToItem(file, MediaKind.Movie, null, identity.Title, identity.Year));
                continue;
            }

            var ownerDirectory = CombineComponents(
                rootPath,
                context.DirectoryComponents.Take(context.ExtrasIndex.Value));
            pendingSupplements.Add(new PendingSupplement(file, ownerDirectory, context));
        }

        var items = new List<DiscoveredMediaItem>(movies);
        var skipped = 0;
        foreach (var supplement in pendingSupplements)
        {
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
                skipped += 1;
                issues.Add(new ScanDiscoveryIssue(
                    "ambiguous_movie_extra",
                    "The extra could not be assigned to exactly one movie.",
                    supplement.File.Path));
                continue;
            }

            var owner = possibleOwners[0];
            items.Add(ToItem(
                supplement.File,
                supplement.Context.IsTrailer ? MediaKind.Trailer : MediaKind.Extra,
                owner.SourcePath,
                FilenameMetadataParser.SupplementTitle(
                    supplement.File.Path,
                    owner.DetectedTitle),
                category: supplement.Context.Category));
        }

        return new MediaScanDiscovery(items, issues, files.Count, skipped);
    }

    private static MediaScanDiscovery ScanTvShows(
        string rootPath,
        IReadOnlyList<ScannedFile> files,
        IReadOnlyList<ScanDiscoveryIssue> enumerationIssues,
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes,
        bool forceSeriesRoot = false)
    {
        var seriesByPath = new Dictionary<string, DiscoveredMediaItem>(StringComparer.Ordinal);
        var episodes = new List<DiscoveredMediaItem>();
        var supplements = new List<DiscoveredMediaItem>();
        var issues = new List<ScanDiscoveryIssue>(enumerationIssues);
        var skipped = 0;

        foreach (var file in files)
        {
            var context = FolderContext.Create(rootPath, file.Path);
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
            if (context.ExtrasIndex.HasValue)
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
                skipped += 1;
                issues.Add(new ScanDiscoveryIssue(
                    "unmatched_episode",
                    "No unambiguous season and episode number was found.",
                    file.Path));
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
            .OrderBy(series => series.SourcePath, StringComparer.Ordinal)
            .Concat(acceptedEpisodes.OrderBy(episode => episode.SourcePath, StringComparer.Ordinal))
            .Concat(supplements.OrderBy(supplement => supplement.SourcePath, StringComparer.Ordinal))
            .ToList();
        return new MediaScanDiscovery(items, issues, files.Count, skipped);
    }

    private static string DetermineSeriesPath(
        string rootPath,
        string filePath,
        FolderContext context)
    {
        var boundary = new[] { context.SeasonIndex, context.ExtrasIndex }
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
            file.ModifiedAt);
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
                            modifiedAt.ToUnixTimeMilliseconds())));
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

    private static bool IsExtrasFolder(string value)
    {
        return ExtrasFolderNames.Contains(FilenameMetadataParser.NormalizeFolderToken(value));
    }

    private static bool IsTrailerToken(string value)
    {
        var normalized = FilenameMetadataParser.NormalizeFolderToken(value);
        return normalized.Contains("trailer", StringComparison.Ordinal)
            || normalized.Contains("teaser", StringComparison.Ordinal);
    }

    private sealed record ScannedFile(string Path, long Size, DateTimeOffset ModifiedAt);

    private sealed record EnumerationResult(
        IReadOnlyList<ScannedFile> Files,
        IReadOnlyList<ScanDiscoveryIssue> Issues);

    private sealed record PendingSupplement(
        ScannedFile File,
        string OwnerDirectory,
        FolderContext Context);

    private sealed record AutomaticCandidate(
        string Path,
        string Title,
        LibraryKind? Kind,
        string Reason,
        IReadOnlyList<ScannedFile> Files);

    private sealed record FolderContext(
        IReadOnlyList<string> DirectoryComponents,
        int? SeasonIndex,
        int? ExtrasIndex,
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
            var extrasIndex = components.FindIndex(IsExtrasFolder);
            var category = extrasIndex < 0
                ? string.Empty
                : string.Join(
                    " / ",
                    components.Skip(extrasIndex + 1).Where(component => !IsTrailerToken(component)));
            var trailerTokens = components.Append(Path.GetFileNameWithoutExtension(filePath));
            return new FolderContext(
                components,
                seasonIndex < 0 ? null : seasonIndex,
                extrasIndex < 0 ? null : extrasIndex,
                trailerTokens.Any(IsTrailerToken),
                category);
        }
    }
}
