using System.Data.Common;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class DetailQuerySizeTests
{
    // A film with many pictures and a large cast. Read as one query, every combination of
    // picture and credit became a row carrying the full provider credits: a detail page of a
    // real film wrote gigabytes of temporary files and never finished.
    [Fact]
    public async Task ADetailPageReadsEachPictureAndCreditOnce()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        try
        {
            await using var connection = new SqliteConnection($"Data Source={Path.Combine(root, "detail.db")}");
            await connection.OpenAsync();
            var rows = new RowCounter();
            var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite(connection).AddInterceptors(rows).Options;
            await using var database = new AureliaDbContext(options);
            await database.Database.MigrateAsync();
            var owner = new ServerUser { Id = Guid.NewGuid(), Username = "Synthetic", NormalizedUsername = "SYNTHETIC", PasswordHash = "synthetic-only", Role = UserRole.Owner, AccessMode = ProfileAccessMode.EntireLibrary };
            var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", Path = root, NormalizedPath = root, MonitoringEnabled = false, Availability = LibraryAvailability.Available };
            var film = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRoot = library,
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                DetectedTitle = "Synthetic Epic",
                SourcePath = Path.Combine(root, "Epic.mkv"),
                NormalizedSourcePath = "EPIC.MKV",
                Availability = MediaAvailability.Available
            };
            const int pictures = 25, credits = 300;
            film.Metadata = new MediaMetadata
            {
                MediaItemId = film.Id,
                ProviderTitle = "Synthetic Epic",
                ReviewState = MetadataReviewState.Matched,
                ProviderCreditsJson = "[" + string.Join(",", Enumerable.Range(0, credits).Select(index => $"{{\"name\":\"Person {index}\"}}")) + "]",
                Artwork = Enumerable.Range(0, pictures).Select(index => new ArtworkAsset
                {
                    Id = Guid.NewGuid(),
                    MediaItemId = film.Id,
                    Kind = index == 0 ? ArtworkKind.Poster : ArtworkKind.Backdrop,
                    ProviderPath = $"/picture{index}.jpg",
                    RelativeFilePath = $"picture{index}.jpg",
                    ContentType = "image/jpeg"
                }).ToList(),
                Credits = Enumerable.Range(0, credits).Select(index => new MediaCredit
                {
                    Id = Guid.NewGuid(),
                    MediaItemId = film.Id,
                    Name = $"Person {index}",
                    Department = "Acting",
                    SortOrder = index
                }).ToList()
            };
            database.Users.Add(owner);
            database.LibraryRoots.Add(library);
            database.MediaItems.Add(film);
            await database.SaveChangesAsync();
            database.ChangeTracker.Clear();

            rows.Count = 0;
            var detail = await new PresentationService(database, TimeProvider.System, new MediaSearchIndexService(database))
                .DetailAsync(owner.Id, film.Id, default);

            Assert.Equal("Synthetic Epic", detail.Metadata.Title);
            Assert.NotNull(detail.Metadata.Poster);
            Assert.Equal(credits, detail.Metadata.Credits.Count);
            Assert.True(rows.Count < pictures + credits + 50, $"The detail page read {rows.Count} rows.");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private sealed class RowCounter : DbCommandInterceptor
    {
        public int Count { get; set; }

        public override InterceptionResult DataReaderClosing(DbCommand command, DataReaderClosingEventData eventData, InterceptionResult result)
        {
            Count += eventData.ReadCount;
            return result;
        }

        public override ValueTask<InterceptionResult> DataReaderClosingAsync(DbCommand command, DataReaderClosingEventData eventData, InterceptionResult result)
        {
            Count += eventData.ReadCount;
            return ValueTask.FromResult(result);
        }
    }
}
