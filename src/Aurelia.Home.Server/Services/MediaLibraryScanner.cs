using Aurelia.Home.Contracts;

namespace Aurelia.Home.Server.Services;

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

public sealed record MediaScanDiscovery(
    IReadOnlyList<DiscoveredMediaItem> Items,
    IReadOnlyList<ScanDiscoveryIssue> Issues,
    int FilesDiscovered,
    int SkippedFiles);

public interface IMediaLibraryScanner
{
    MediaScanDiscovery Scan(
        string rootPath,
        LibraryKind kind,
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes,
        Action<int>? progress,
        CancellationToken cancellationToken);
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
        CancellationToken cancellationToken)
    {
        var files = EnumerateVideoFiles(rootPath, progress, cancellationToken);
        return kind == LibraryKind.Movies
            ? ScanMovies(rootPath, files.Files, files.Issues)
            : ScanTvShows(rootPath, files.Files, files.Issues, existingEpisodes);
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
        IReadOnlyList<ExistingEpisodeBinding> existingEpisodes)
    {
        var seriesByPath = new Dictionary<string, DiscoveredMediaItem>(StringComparer.Ordinal);
        var episodes = new List<DiscoveredMediaItem>();
        var supplements = new List<DiscoveredMediaItem>();
        var issues = new List<ScanDiscoveryIssue>(enumerationIssues);
        var skipped = 0;

        foreach (var file in files)
        {
            var context = FolderContext.Create(rootPath, file.Path);
            var seriesPath = DetermineSeriesPath(rootPath, file.Path, context);
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
