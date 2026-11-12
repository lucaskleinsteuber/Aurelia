using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Views;
using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;

namespace Aurelia.Linux.Tests;

/// <summary>
/// An invented library for interface tests: made-up titles, generated gradient pictures as
/// artwork, served by <see cref="FakeServer"/>. Nothing here comes from a real library.
/// </summary>
internal static class FakeLibrary
{
    public static readonly Guid OwnerId = Guid.Parse("11111111-0000-4000-8000-000000000001");
    public static readonly Guid SeriesId = Guid.Parse("a0000000-0000-4000-8000-000000000001");
    public static readonly Guid MovieA = Guid.Parse("a0000000-0000-4000-8000-000000000002");
    public static readonly Guid MovieB = Guid.Parse("a0000000-0000-4000-8000-000000000003");
    public static readonly Guid MovieC = Guid.Parse("a0000000-0000-4000-8000-000000000004");
    public static readonly Guid EpisodeOne = Guid.Parse("a0000000-0000-4000-8000-000000000011");
    public static readonly Guid EpisodeTwo = Guid.Parse("a0000000-0000-4000-8000-000000000012");
    public static readonly Guid CollectionId = Guid.Parse("c0000000-0000-4000-8000-000000000001");

    private static int artworkCount;

    public static ArtworkSummary Art(ArtworkKind kind) =>
        new(Guid.Parse($"f0000000-0000-4000-8000-{++artworkCount:000000000000}"), kind, "/art", "image/png", 100, 1);

    public static CatalogItemSummary Item(Guid id, MediaKind kind, string title, int year, string[] genres, bool favorite = false,
        long position = 0, CatalogWatchState state = CatalogWatchState.Unplayed, Guid? parent = null, int? season = null, int? episode = null) =>
        new(id, kind, title, null, year, $"An invented story about {title}.", genres, Art(ArtworkKind.Poster), Art(ArtworkKind.Backdrop),
            MediaAvailability.Available, favorite,
            position > 0 ? new PlaybackProgressResponse(id, position, 3_600_000, false, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, 1) : null,
            DateTimeOffset.UtcNow.AddDays(-2), kind == MediaKind.Episode ? "Cobalt Station" : null, season, episode, parent, state);

    public static FakeServer Create(bool watchlist = true, bool pictures = true)
    {
        artworkCount = 0;
        var series = Item(SeriesId, MediaKind.Series, "Cobalt Station", 2024, ["Science Fiction", "Drama"]);
        var movieA = Item(MovieA, MediaKind.Movie, "Quiet Orbit", 2024, ["Science Fiction"], favorite: true, position: 1_200_000);
        var movieB = Item(MovieB, MediaKind.Movie, "The Quiet Harbor", 2023, ["Drama"]);
        var movieC = Item(MovieC, MediaKind.Movie, "Amber Fields", 2019, ["Action", "Drama"], state: CatalogWatchState.Completed);
        var episodeOne = Item(EpisodeOne, MediaKind.Episode, "Arrival", 2024, ["Science Fiction"], position: 600_000, parent: SeriesId, season: 1, episode: 1);
        var episodeTwo = Item(EpisodeTwo, MediaKind.Episode, "Signal", 2024, ["Science Fiction"], parent: SeriesId, season: 1, episode: 2);
        var catalog = new[] { series, movieA, movieB, movieC };
        var collection = new CollectionSummary(CollectionId, "Weekend Picks", null, [movieA, movieB], TotalCount: 2, IsShared: false, UserId: OwnerId,
            Overview: "Invented double-feature box.", CanEdit: true, ItemCount: 2, WatchedCount: 1, YearRange: "2023–2024", SortMode: "custom");
        var collectionDetail = new CollectionDetail(
            CollectionId, "Weekend Picks", "Invented double-feature box.", null, null, null, true, false, false, OwnerId, null, "custom",
            2, 1, "2023–2024", 7_200, ["Science Fiction", "Drama"],
            [
                new CollectionMember(Guid.Parse("c1000000-0000-4000-8000-000000000001"), MovieA, MediaKind.Movie, movieA.Title, null, movieA, null),
                new CollectionMember(Guid.Parse("c1000000-0000-4000-8000-000000000002"), MovieB, MediaKind.Movie, movieB.Title, null, movieB, null),
            ],
            new CollectionNextResponse(movieA, true, 1_200_000, 0, 2));
        var home = new HomeResponse(series, [movieA, episodeOne], catalog, [movieA], [collection], DateTimeOffset.UtcNow.AddHours(6));
        var credits = new[]
        {
            new CreditSummary("Ada Lovelace", "Acting", null, "Captain Rhea", 0, null, PersonKey: "ada"),
            new CreditSummary("Grace Hopper", "Acting", null, "Doctor Ilse", 1, null, PersonKey: "grace"),
            new CreditSummary("Ada Lovelace", "Writing", "Writer", null, 5, null, PersonKey: "ada"),
        };
        var metadata = new MediaMetadataSummary(SeriesId, "Cobalt Station", null, series.Overview, "2024-03-01", 2024, null, 8.1, "12",
            series.Genres, ["Invented Studio"], ["Germany"], credits, series.Poster, series.Backdrop, null, null, null, MetadataReviewState.Matched, 12);
        var detail = new CatalogDetailPresentation(series, metadata,
            [new SeasonPresentation(1, [new EpisodePresentation(episodeOne, 1, 1), new EpisodePresentation(episodeTwo, 1, 2)], [])],
            [new SupplementPresentation(Item(Guid.NewGuid(), MediaKind.Trailer, "Official Trailer", 2024, []), "Trailer", null)]);
        var plan = new PlaybackPlanResponse(episodeOne, SeriesId, [episodeOne, episodeTwo], PlaybackPlanAction.Resume, true);
        string Json<T>(T value) => JsonSerializer.Serialize(value, AureliaJson.Options);
        var capabilities = watchlist ? "\"library-state-v1\",\"watchlist-people-v1\",\"artwork-variants-v1\",\"collections-v3\"" : "\"library-state-v1\",\"collections-v3\"";
        var server = new FakeServer()
            .Answer("GET", "/api/v1/server/info", $$"""
                {"serverId":"{{FakeServer.ServerId}}","name":"Living Room Server","version":"1.26.3","isSetup":true,"lanAccessEnabled":true,
                 "lanHttpsPort":43111,"publicKeyFingerprint":"{{FakeServer.Fingerprint}}","capabilities":[{{capabilities}}]}
                """)
            .Answer("GET", "/api/v1/home", Json(home))
            .Answer("GET", "/api/v1/catalog/items", Json(new PagedResponse<CatalogItemSummary>(catalog, 0, 100, catalog.Length, "r1")))
            .Answer("GET", "/api/v1/catalog/search", Json(new PagedResponse<CatalogItemSummary>([movieA], 0, 100, 1, "r1")))
            .Answer("GET", "/api/v1/catalog/collections", Json(new[] { collection }))
            .Answer("GET", $"/api/v1/collections/{CollectionId}", Json(collectionDetail))
            .Answer("GET", $"/api/v1/collections/{CollectionId}/next", Json(collectionDetail.NextItem!))
            .Answer("PUT", $"/api/v1/collections/{CollectionId}/order", Json(collectionDetail))
            .Answer("GET", "/api/v1/catalog/franchises", "[]")
            .Answer("GET", "/api/v1/watchlist", Json(new WatchlistResponse([movieB], [MovieB])))
            .Answer("GET", $"/api/v1/catalog/items/{SeriesId}", Json(detail))
            .Answer("GET", $"/api/v1/media/{SeriesId}/playback-plan", Json(plan))
            .Answer("GET", $"/api/v1/media/{EpisodeOne}/playback-plan", Json(plan))
            .Answer("GET", $"/api/v1/media/{SeriesId}/watch-state", Json(new WatchStateResponse(SeriesId, WatchStateScope.Season, 1, CatalogWatchState.InProgress, 2, "token-1", false)))
            .Answer("PUT", $"/api/v1/media/{SeriesId}/watch-state", Json(new WatchStateResponse(SeriesId, WatchStateScope.Season, 1, CatalogWatchState.Completed, 2, "token-2", false)))
            .Answer("PUT", $"/api/v1/media/{MovieB}/favorite", "{}")
            .Answer("POST", "/api/v1/collections", Json(collection with { Id = Guid.NewGuid(), Name = "New One" }))
            .Answer("GET", "/api/v1/history", Json(new WatchHistoryPage(
                [new WatchHistoryItem(Guid.NewGuid(), MovieA, "Quiet Orbit", "Movie", 2024, MediaKind.Movie, movieA.Poster, DateTimeOffset.Now.AddSeconds(-1), 1_200_000, 3_600_000, 1_200, false),
                 new WatchHistoryItem(Guid.NewGuid(), MovieC, "Amber Fields", "Movie", 2019, MediaKind.Movie, movieC.Poster, DateTimeOffset.Now.AddDays(-1), 5_400_000, 5_400_000, 5_400, true)], 0, 50, 2)))
            .Answer("GET", "/api/v1/statistics", Json(new UserStatistics(31.5, 4.2, 12.75,
                [.. Enumerable.Range(1, 12).Select(week => new PeriodHours($"2026-W{week + 30}", week % 5 + 0.5))], [],
                [new NamedCount("Science Fiction", 8, 14.5), new NamedCount("Drama", 5, 9)], [new NamedCount("Cobalt Station", 6, 6.5)],
                3, 9, "Saturday", "evening", 0.72, [2026])))
            .Answer("POST", $"/api/v1/media/{MovieA}/playback", Json(new PlaybackSourceResponse(Guid.NewGuid(), MovieA, "/api/v1/streams/ticket-a",
                "video/x-matroska", 1000, DateTimeOffset.UtcNow.AddHours(4), new PlaybackProgressResponse(MovieA, 1_200_000, 3_600_000, false, null, null, 2))))
            .Answer("POST", $"/api/v1/media/{EpisodeOne}/playback", Json(new PlaybackSourceResponse(Guid.NewGuid(), EpisodeOne, "/api/v1/streams/ticket-e1",
                "video/x-matroska", 1000, DateTimeOffset.UtcNow.AddHours(4), new PlaybackProgressResponse(EpisodeOne, 600_000, 3_600_000, false, null, null, 1))))
            .Answer("PUT", $"/api/v1/media/{MovieA}/progress", Json(new PlaybackProgressResponse(MovieA, 1, 3_600_000, false, null, null, 3)))
            .Answer("PUT", $"/api/v1/media/{EpisodeOne}/progress", Json(new PlaybackProgressResponse(EpisodeOne, 1, 3_600_000, false, null, null, 2)))
            .Answer("GET", $"/api/v1/media/{MovieA}/notes", "[]")
            .Answer("GET", $"/api/v1/media/{EpisodeOne}/notes", "[]")
            .Answer("PUT", "/api/v1/profile/pin-protection", Json(new UserSummary(OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow)))
            .Answer("POST", "/api/v1/profile/end", "{}")
            .Answer("DELETE", "/api/v1/device", "{}")
            .Answer("GET", "/api/v1/profiles", $$"""
                {"formatVersion":2,"minimumClientVersion":"1.0","managementSetupRequired":false,"profiles":[
                  {"id":"{{OwnerId}}","name":"Lucas","role":"owner","needsPinSetup":false,"pinProtectionEnabled":true}]}
                """)
            .Answer("GET", "/api/v1/statistics/year/2026", Json(new YearInReview(2026, 31.5, 12, 7, 18, "Science Fiction", "Cobalt Station", "Saturday", 4.5)));
        if (pictures)
        {
            foreach (var art in ArtworkIds()) server.Image($"/api/v1/artwork/{art.Id}", Picture(art.Index));
        }
        return server;
    }

    /// <summary>Opens the main window with the invented library and an open owner profile.</summary>
    public static MainWindow ShowLibrary(FakeServer server, SimulatedEngines? engines = null, TimeProvider? time = null, MemoryCredentialStore? keyring = null)
    {
        keyring ??= new MemoryCredentialStore
        {
            Server = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
                "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30)),
        };
        var window = TestWindows.Show(AppServices.ForTests(transport: server, credentials: keyring, engines: engines, time: time));
        Pump(() => window.Flow.Screen == Core.Flow.AppScreen.ProfilePicker);
        window.Session.OpenProfile(new ProfileSession(
            new UserSummary(OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(), "profile-token-synthetic-0000000000000000001", DateTimeOffset.UtcNow.AddHours(12)));
        Pump(() => window.Session.Library?.Home is not null && window.Shell is not null);
        Pump(() => false, rounds: 10);
        return window;
    }

    public static void Pump(Func<bool> done, int rounds = 300)
    {
        for (var round = 0; round < rounds && !done(); round++)
        {
            Dispatcher.UIThread.RunJobs();
            Thread.Sleep(5);
        }
        Dispatcher.UIThread.RunJobs();
    }

    private static IEnumerable<(Guid Id, int Index)> ArtworkIds()
    {
        for (var index = 1; index <= 80; index++) yield return (Guid.Parse($"f0000000-0000-4000-8000-{index:000000000000}"), index);
    }

    /// <summary>A generated gradient picture, different for every artwork.</summary>
    private static byte[] Picture(int seed)
    {
        var colors = new[] { ("#5B7CFF", "#14161C"), ("#FF8C66", "#2A1414"), ("#5CD6CC", "#0E2224"), ("#BD7DFF", "#1A1230"), ("#FFB85C", "#2A1E0E") };
        var (top, bottom) = colors[seed % colors.Length];
        using var bitmap = new RenderTargetBitmap(new PixelSize(320, 240));
        using (var context = bitmap.CreateDrawingContext())
        {
            context.FillRectangle(new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
                EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(Color.Parse(top), 0), new GradientStop(Color.Parse(bottom), 1) },
            }, new Rect(0, 0, 320, 240));
            context.DrawEllipse(new SolidColorBrush(Color.FromArgb(0x55, 0xFF, 0xFF, 0xFF)), null, new Point(220, 110), 60, 60);
        }
        using var stream = new MemoryStream();
        bitmap.Save(stream, PngBitmapEncoderOptions.Default);
        return stream.ToArray();
    }
}
