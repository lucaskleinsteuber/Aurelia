using System.Data.Common;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// A household that watched a long series: many episodes, each with stills, of one series with
/// many pictures and a large cast. History, statistics and smart lists must read each title once,
/// not once per watch event and picture.
/// </summary>
public sealed class HistoryQuerySizeTests
{
    private const int Episodes = 100, Stills = 2, SeriesPictures = 25, Films = 50, FilmPictures = 25;

    [Fact]
    public async Task AHistoryPageReadsEachPictureOnce()
    {
        await using var library = await Library.CreateAsync();
        library.Rows.Reset();

        var page = await new WatchHistoryService(library.Database, TimeProvider.System).GetHistoryAsync(library.OwnerId, 0, 100, default);

        Assert.Equal(Episodes, page.Items.Count);
        Assert.All(page.Items, item => Assert.NotNull(item.Poster));
        // Events, episodes, their stills, the series and its pictures; not stills times series pictures per event.
        Assert.True(library.Rows.Count < Episodes * (2 + Stills) + SeriesPictures + 50, $"The history page read {library.Rows.Count} rows.");
        Assert.True(library.Rows.FullDescriptions <= Episodes + 10, $"The history page read {library.Rows.FullDescriptions} full descriptions.");
    }

    [Fact]
    public async Task StatisticsReadEachTitleOnceHoweverOftenItWasWatched()
    {
        await using var library = await Library.CreateAsync(watchesPerEpisode: 5);
        library.Rows.Reset();
        var history = new WatchHistoryService(library.Database, TimeProvider.System);

        var statistics = await history.GetStatisticsAsync(library.OwnerId, default);
        var year = await history.GetYearInReviewAsync(library.OwnerId, Library.WatchedAt.Year, default);

        Assert.Equal("Synthetic Saga", Assert.Single(statistics.TopTitles).Name);
        Assert.Equal("Drama", Assert.Single(statistics.TopGenres).Name);
        Assert.Equal(Episodes * 5, year.EpisodesWatched);
        Assert.Equal("Synthetic Saga", year.TopTitle);
        // Twice (statistics and the year): every episode and the series, not every watch event.
        Assert.True(library.Rows.FullDescriptions <= 2 * (Episodes + 10), $"Statistics read {library.Rows.FullDescriptions} full descriptions.");
    }

    [Fact]
    public async Task ASmartListReadsEachTitlesDescriptionOnce()
    {
        await using var library = await Library.CreateAsync();
        SmartListEvaluator.InvalidateCache();
        library.Rows.Reset();

        var (items, total) = await SmartListEvaluator.EvaluateAsync(library.Database, library.OwnerId,
            SmartListEvaluator.Parse("{\"kind\":\"movie\"}")!, 0, 50, default);

        Assert.Equal(Films, total);
        Assert.Equal(Films, items.Count);
        Assert.All(items, item => Assert.Equal(FilmPictures, item.Metadata!.Artwork.Count));
        Assert.True(library.Rows.FullDescriptions <= Films + 5, $"The smart list read {library.Rows.FullDescriptions} full descriptions.");
    }

    private sealed class Library(string root, SqliteConnection connection, AureliaDbContext database, RowCounter rows, Guid ownerId) : IAsyncDisposable
    {
        public static readonly DateTimeOffset WatchedAt = new(2026, 3, 14, 20, 0, 0, TimeSpan.Zero);
        public AureliaDbContext Database { get; } = database;
        public RowCounter Rows { get; } = rows;
        public Guid OwnerId { get; } = ownerId;

        public static async Task<Library> CreateAsync(int watchesPerEpisode = 1)
        {
            var root = TestPaths.CreateDataDirectory();
            Directory.CreateDirectory(root);
            var connection = new SqliteConnection($"Data Source={Path.Combine(root, "history.db")}");
            await connection.OpenAsync();
            var rows = new RowCounter();
            var database = new AureliaDbContext(new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite(connection).AddInterceptors(rows).Options);
            await database.Database.MigrateAsync();
            var owner = new ServerUser { Id = Guid.NewGuid(), Username = "Synthetic", NormalizedUsername = "SYNTHETIC", PasswordHash = "synthetic-only", Role = UserRole.Owner, AccessMode = ProfileAccessMode.EntireLibrary };
            var storage = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", Path = root, NormalizedPath = root, MonitoringEnabled = false, Availability = LibraryAvailability.Available };
            database.Users.Add(owner);
            database.LibraryRoots.Add(storage);

            var series = Title(storage, MediaKind.Series, "Synthetic Saga", null, SeriesPictures, ArtworkKind.Backdrop);
            database.MediaItems.Add(series);
            for (var index = 0; index < Episodes; index++)
            {
                var episode = Title(storage, MediaKind.Episode, $"Chapter {index}", series, Stills, ArtworkKind.Still);
                episode.SeasonNumber = 1;
                episode.EpisodeNumber = index + 1;
                database.MediaItems.Add(episode);
                for (var watch = 0; watch < watchesPerEpisode; watch++)
                {
                    database.WatchEvents.Add(new WatchEvent
                    {
                        Id = Guid.NewGuid(),
                        UserId = owner.Id,
                        MediaItemId = episode.Id,
                        Timestamp = WatchedAt.AddMinutes(index * 10 + watch),
                        DurationMilliseconds = 2_400_000,
                        PositionMilliseconds = 2_400_000,
                        SecondsWatched = 2_400,
                        IsCompleted = true,
                    });
                }
            }
            for (var index = 0; index < Films; index++)
                database.MediaItems.Add(Title(storage, MediaKind.Movie, $"Synthetic Film {index}", null, FilmPictures, ArtworkKind.Backdrop));
            await database.SaveChangesAsync();
            database.ChangeTracker.Clear();
            return new Library(root, connection, database, rows, owner.Id);
        }

        private static MediaItem Title(LibraryRoot storage, MediaKind kind, string title, MediaItem? parent, int pictures, ArtworkKind pictureKind)
        {
            var id = Guid.NewGuid();
            return new MediaItem
            {
                Id = id,
                LibraryRoot = storage,
                LibraryRootId = storage.Id,
                Kind = kind,
                Parent = parent,
                ParentId = parent?.Id,
                DetectedTitle = title,
                SourcePath = Path.Combine(storage.Path, id.ToString("N") + ".mkv"),
                NormalizedSourcePath = id.ToString("N").ToUpperInvariant() + ".MKV",
                Availability = MediaAvailability.Available,
                Metadata = new MediaMetadata
                {
                    MediaItemId = id,
                    ProviderTitle = title,
                    ReviewState = MetadataReviewState.Matched,
                    ProviderGenresJson = kind == MediaKind.Episode ? "[]" : "[\"Drama\"]",
                    ProviderCreditsJson = "[" + string.Join(",", Enumerable.Range(0, 300).Select(index => $"{{\"name\":\"Person {index}\"}}")) + "]",
                    Artwork = Enumerable.Range(0, pictures).Select(index => new ArtworkAsset
                    {
                        Id = Guid.NewGuid(),
                        MediaItemId = id,
                        Kind = index == 0 && kind != MediaKind.Episode ? ArtworkKind.Poster : pictureKind,
                        ProviderPath = $"/{id:N}-{index}.jpg",
                        RelativeFilePath = $"{id:N}-{index}.jpg",
                        ContentType = "image/jpeg",
                    }).ToList(),
                },
            };
        }

        public async ValueTask DisposeAsync()
        {
            await Database.DisposeAsync();
            await connection.DisposeAsync();
            SqliteConnection.ClearAllPools();
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private sealed class RowCounter : DbCommandInterceptor
    {
        public int Count { get; private set; }

        /// <summary>Rows that carried a title's whole description, its full provider credits included.</summary>
        public int FullDescriptions { get; private set; }

        public void Reset() => (Count, FullDescriptions) = (0, 0);

        private void Add(DbCommand command, int read)
        {
            Count += read;
            if (command.CommandText.Contains("ProviderCreditsJson", StringComparison.Ordinal)) FullDescriptions += read;
        }

        public override InterceptionResult DataReaderClosing(DbCommand command, DataReaderClosingEventData eventData, InterceptionResult result)
        {
            Add(command, eventData.ReadCount);
            return result;
        }

        public override ValueTask<InterceptionResult> DataReaderClosingAsync(DbCommand command, DataReaderClosingEventData eventData, InterceptionResult result)
        {
            Add(command, eventData.ReadCount);
            return ValueTask.FromResult(result);
        }
    }
}
