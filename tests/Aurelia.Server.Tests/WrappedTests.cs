using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>Wrapped, the year as slides, from an invented household's viewing; nothing is played.</summary>
public sealed class WrappedTests
{
    [Fact]
    public async Task AYearBecomesSlidesWithTheTopSeriesAndTheRewatchedFilm()
    {
        await using var home = await Home.CreateAsync();
        var lucas = home.Person("Lucas");
        var saga = home.Title(MediaKind.Series, "Invented Saga", null, "Horror");
        // Eleven episodes on 14 March from 20:00, one more the next evening and one deep in the night after.
        for (var episode = 0; episode < 11; episode++)
        {
            var item = home.Title(MediaKind.Episode, $"Chapter {episode}", saga, null);
            home.Watched(lucas, item, new DateTimeOffset(2026, 3, 14, 20, 0, 0, TimeSpan.Zero).AddMinutes(episode * 20), minutes: 20, completed: true);
        }
        var bonus = home.Title(MediaKind.Episode, "Chapter Bonus", saga, null);
        home.Watched(lucas, bonus, new DateTimeOffset(2026, 3, 15, 18, 0, 0, TimeSpan.Zero), minutes: 20, completed: true);
        var latest = home.Title(MediaKind.Episode, "Chapter Late", saga, null);
        home.Watched(lucas, latest, new DateTimeOffset(2026, 3, 16, 3, 42, 0, TimeSpan.Zero), minutes: 30, completed: true);
        var film = home.Title(MediaKind.Movie, "Invented Heist", null, "Crime");
        home.Watched(lucas, film, new DateTimeOffset(2026, 5, 1, 21, 0, 0, TimeSpan.Zero), minutes: 120, completed: true);
        home.Watched(lucas, film, new DateTimeOffset(2026, 6, 1, 21, 0, 0, TimeSpan.Zero), minutes: 120, completed: true);
        // Another year does not count.
        home.Watched(lucas, film, new DateTimeOffset(2025, 6, 1, 21, 0, 0, TimeSpan.Zero), minutes: 120, completed: true);
        await home.SaveAsync();

        var wrapped = await home.History.GetWrappedAsync(lucas.Id, 2026, default);

        Assert.Equal("Lucas", wrapped.ProfileName);
        Assert.Equal(["intro", "hours", "top-series", "top-movie", "genre", "night-owl", "binge", "rhythm", "summary"],
            wrapped.Slides.Select(slide => slide.Kind));
        var hours = wrapped.Slides.Single(slide => slide.Kind == "hours");
        Assert.Equal("8", hours.BigNumber);
        var series = wrapped.Slides.Single(slide => slide.Kind == "top-series");
        Assert.Equal("Invented Saga", series.Headline);
        Assert.Equal("13", series.BigNumber);
        Assert.Equal(saga.Id, series.MediaId);
        Assert.NotNull(series.Poster);
        var movie = wrapped.Slides.Single(slide => slide.Kind == "top-movie");
        Assert.Equal("On repeat", movie.Eyebrow);
        Assert.Equal("2", movie.BigNumber);
        Assert.Equal("Horror", wrapped.Slides.Single(slide => slide.Kind == "genre").Headline);
        var owl = wrapped.Slides.Single(slide => slide.Kind == "night-owl");
        Assert.Equal("03:42", owl.BigNumber);
        Assert.Contains("Monday in March", owl.Detail, StringComparison.Ordinal);
        var binge = wrapped.Slides.Single(slide => slide.Kind == "binge");
        Assert.Equal("11", binge.BigNumber);
        Assert.Contains("14 March", binge.Detail, StringComparison.Ordinal);
        var summary = wrapped.Slides.Single(slide => slide.Kind == "summary");
        Assert.Equal(2, summary.Posters!.Count);
        Assert.Contains(summary.Facts!, fact => fact.Label == "Genre" && fact.Value == "Horror");
        Assert.DoesNotContain(wrapped.Slides, slide => slide.Quip.Contains('{', StringComparison.Ordinal));

        // The lines are the cheeky ones and stay the same when the year is opened again.
        Assert.Contains(wrapped.Slides[0].Quip, WrappedLines.Intro);
        var again = await home.History.GetWrappedAsync(lucas.Id, 2026, default);
        Assert.Equal(wrapped.Slides.Select(slide => slide.Quip), again.Slides.Select(slide => slide.Quip));
    }

    [Fact]
    public async Task AChildsYearGetsTheFriendlyLinesAndOnlyItsOwnViewing()
    {
        await using var home = await Home.CreateAsync();
        var lucas = home.Person("Lucas");
        var mia = home.Person("Mia", ageLimit: 6);
        var cartoon = home.Title(MediaKind.Movie, "Invented Cartoon", null, "Animation");
        var thriller = home.Title(MediaKind.Movie, "Invented Thriller", null, "Thriller");
        home.Watched(mia, cartoon, new DateTimeOffset(2026, 2, 1, 16, 0, 0, TimeSpan.Zero), minutes: 80, completed: true);
        home.Watched(lucas, thriller, new DateTimeOffset(2026, 2, 1, 22, 0, 0, TimeSpan.Zero), minutes: 600, completed: true);
        await home.SaveAsync();

        var wrapped = await home.History.GetWrappedAsync(mia.Id, 2026, default);

        Assert.DoesNotContain(wrapped.Slides, slide => slide.Headline.Contains("Thriller", StringComparison.Ordinal));
        Assert.Equal("Invented Cartoon", wrapped.Slides.Single(slide => slide.Kind == "top-movie").Headline);
        var gentle = WrappedLines.IntroGentle.Concat(WrappedLines.HoursGentle).Concat(WrappedLines.TopMovieGentle).Concat(WrappedLines.GenreGentle)
            .Concat(WrappedLines.SummaryGentle).Select(line => line.Replace("{period}", "year", StringComparison.Ordinal)).ToHashSet();
        Assert.All(wrapped.Slides, slide => Assert.Contains(slide.Quip, gentle));
    }

    [Fact]
    public async Task AnEmptyYearSaysSoAndAWrongYearIsRefused()
    {
        await using var home = await Home.CreateAsync();
        var lucas = home.Person("Lucas");
        await home.SaveAsync();

        var empty = await home.History.GetWrappedAsync(lucas.Id, 2026, default);
        Assert.Equal("empty", Assert.Single(empty.Slides).Kind);
        await Assert.ThrowsAsync<MetadataException>(() => home.History.GetWrappedAsync(lucas.Id, 1999, default));
    }

    [Fact]
    public async Task AMonthIsWrappedFromTheSecondOfTheNextMonth()
    {
        await using var home = await Home.CreateAsync(new DateTimeOffset(2026, 4, 2, 0, 0, 0, TimeSpan.Zero));
        var lucas = home.Person("Lucas");
        var saga = home.Title(MediaKind.Series, "Invented Saga", null, "Horror");
        for (var episode = 0; episode < 6; episode++)
        {
            var item = home.Title(MediaKind.Episode, $"Chapter {episode}", saga, null);
            home.Watched(lucas, item, new DateTimeOffset(2026, 3, 14, 20, 0, 0, TimeSpan.Zero).AddMinutes(episode * 30), minutes: 30, completed: true);
        }
        var late = home.Title(MediaKind.Episode, "Chapter Late", saga, null);
        home.Watched(lucas, late, new DateTimeOffset(2026, 3, 15, 2, 10, 0, TimeSpan.Zero), minutes: 30, completed: true);
        // April does not count for March.
        var film = home.Title(MediaKind.Movie, "Invented Heist", null, "Crime");
        home.Watched(lucas, film, new DateTimeOffset(2026, 4, 1, 21, 0, 0, TimeSpan.Zero), minutes: 120, completed: true);
        await home.SaveAsync();

        var march = await home.History.GetWrappedAsync(lucas.Id, 2026, 3, default);

        Assert.Equal(3, march.Month);
        Assert.Equal(["intro", "hours", "top-series", "genre", "night-owl", "binge", "rhythm", "summary"], march.Slides.Select(slide => slide.Kind));
        Assert.Equal("March Wrapped", march.Slides[0].Eyebrow);
        Assert.Equal("Your series of the month", march.Slides.Single(slide => slide.Kind == "top-series").Eyebrow);
        Assert.Contains("Sunday, 15 March", march.Slides.Single(slide => slide.Kind == "night-owl").Detail, StringComparison.Ordinal);
        Assert.Equal("Saturdays were your thing", march.Slides.Single(slide => slide.Kind == "rhythm").Headline);
        Assert.Equal("March 2026 in Aurelia", march.Slides[^1].Eyebrow);
        Assert.DoesNotContain(march.Slides, slide => slide.Quip.Contains('{', StringComparison.Ordinal));

        // April is not ready until 2 May; a month that does not exist is refused.
        var early = await Assert.ThrowsAsync<MetadataException>(() => home.History.GetWrappedAsync(lucas.Id, 2026, 4, default));
        Assert.Equal("wrapped_not_ready", early.Code);
        Assert.Contains("2 May", early.Message, StringComparison.Ordinal);
        await Assert.ThrowsAsync<MetadataException>(() => home.History.GetWrappedAsync(lucas.Id, 2026, 13, default));
    }

    [Fact]
    public async Task AMonthIsNotReadyOnTheFirst()
    {
        await using var home = await Home.CreateAsync(new DateTimeOffset(2026, 4, 1, 23, 59, 0, TimeSpan.Zero));
        var lucas = home.Person("Lucas");
        await home.SaveAsync();
        await Assert.ThrowsAsync<MetadataException>(() => home.History.GetWrappedAsync(lucas.Id, 2026, 3, default));
        Assert.Equal("empty", Assert.Single((await home.History.GetWrappedAsync(lucas.Id, 2026, 2, default)).Slides).Kind);
    }

    [Fact]
    public async Task TheApiAnswersWithTheProfilesOwnYear()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/statistics/year/2026/wrapped", owner.Token);
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var wrapped = await ApiTestClient.ReadAsync<YearWrapped>(response);
        Assert.Equal(2026, wrapped.Year);
        Assert.Equal("empty", Assert.Single(wrapped.Slides).Kind);
        using var wrong = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/statistics/year/1999/wrapped", owner.Token);
        using var refused = await ApiTestClient.SendAsync(client, wrong);
        Assert.Equal(HttpStatusCode.BadRequest, refused.StatusCode);
        using var month = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/statistics/year/2025/month/12/wrapped", owner.Token);
        using var monthly = await ApiTestClient.SendAsync(client, month);
        Assert.Equal(HttpStatusCode.OK, monthly.StatusCode);
        Assert.Equal(12, (await ApiTestClient.ReadAsync<YearWrapped>(monthly)).Month);
        using var future = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/statistics/year/9000/month/1/wrapped", owner.Token);
        using var notReady = await ApiTestClient.SendAsync(client, future);
        Assert.Equal(HttpStatusCode.NotFound, notReady.StatusCode);
    }

    private sealed class Home(string root, SqliteConnection connection, AureliaDbContext database, LibraryRoot storage, DateTimeOffset? now) : IAsyncDisposable
    {
        public WatchHistoryService History { get; } = new(database, new UtcClock(now));

        public static async Task<Home> CreateAsync(DateTimeOffset? now = null)
        {
            var root = TestPaths.CreateDataDirectory();
            Directory.CreateDirectory(root);
            var connection = new SqliteConnection($"Data Source={Path.Combine(root, "wrapped.db")}");
            await connection.OpenAsync();
            var database = new AureliaDbContext(new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite(connection).Options);
            await database.Database.MigrateAsync();
            var storage = new LibraryRoot { Id = Guid.NewGuid(), Name = "Invented", Path = root, NormalizedPath = root, MonitoringEnabled = false, Availability = LibraryAvailability.Available };
            database.LibraryRoots.Add(storage);
            return new Home(root, connection, database, storage, now);
        }

        public ServerUser Person(string name, int? ageLimit = null)
        {
            var person = new ServerUser
            {
                Id = Guid.NewGuid(),
                Username = name,
                NormalizedUsername = name.ToUpperInvariant(),
                PasswordHash = "invented-only",
                Role = ageLimit is null ? UserRole.Owner : UserRole.User,
                AccessMode = ProfileAccessMode.EntireLibrary,
                AgeLimit = ageLimit,
            };
            database.Users.Add(person);
            return person;
        }

        public MediaItem Title(MediaKind kind, string title, MediaItem? parent, string? genre)
        {
            var id = Guid.NewGuid();
            var item = new MediaItem
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
                    ProviderGenresJson = genre is null ? "[]" : MetadataPresentation.SerializeList([genre]),
                    Artwork = kind == MediaKind.Episode ? [] :
                    [
                        new ArtworkAsset
                        {
                            Id = Guid.NewGuid(),
                            MediaItemId = id,
                            Kind = ArtworkKind.Poster,
                            ProviderPath = $"/{id:N}.jpg",
                            RelativeFilePath = $"{id:N}.jpg",
                            ContentType = "image/jpeg",
                        },
                    ],
                },
            };
            database.MediaItems.Add(item);
            return item;
        }

        /// <summary>A sitting that started at <paramref name="started"/>; the event is stamped when it ended.</summary>
        public void Watched(ServerUser person, MediaItem item, DateTimeOffset started, int minutes, bool completed) =>
            database.WatchEvents.Add(new WatchEvent
            {
                Id = Guid.NewGuid(),
                UserId = person.Id,
                MediaItemId = item.Id,
                Timestamp = started.AddMinutes(minutes),
                DurationMilliseconds = minutes * 60_000L,
                PositionMilliseconds = minutes * 60_000L,
                SecondsWatched = minutes * 60L,
                IsCompleted = completed,
            });

        public async Task SaveAsync()
        {
            await database.SaveChangesAsync();
            database.ChangeTracker.Clear();
        }

        public async ValueTask DisposeAsync()
        {
            await database.DisposeAsync();
            await connection.DisposeAsync();
            SqliteConnection.ClearAllPools();
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    /// <summary>The server's clock in UTC, stopped at <paramref name="now"/> when one is given.</summary>
    private sealed class UtcClock(DateTimeOffset? now) : TimeProvider
    {
        public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;

        public override DateTimeOffset GetUtcNow() => now ?? base.GetUtcNow();
    }
}
