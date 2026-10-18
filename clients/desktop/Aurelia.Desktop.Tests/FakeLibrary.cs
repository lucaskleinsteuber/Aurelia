using Aurelia.Contracts;
using Aurelia.Desktop.Core;
using SkiaSharp;

namespace Aurelia.Desktop.Tests;

/// <summary>A scripted library: two movies, one series with two episodes, synthetic artwork.</summary>
internal sealed class FakeLibraryApi : ILibraryApi
{
    public static readonly Guid MovieId = Guid.Parse("00000000-0000-0000-0000-00000000a001");
    public static readonly Guid SecondMovieId = Guid.Parse("00000000-0000-0000-0000-00000000a002");
    public static readonly Guid SeriesId = Guid.Parse("00000000-0000-0000-0000-00000000b001");
    public static readonly Guid EpisodeOneId = Guid.Parse("00000000-0000-0000-0000-00000000c001");
    public static readonly Guid EpisodeTwoId = Guid.Parse("00000000-0000-0000-0000-00000000c002");
    private static readonly DateTimeOffset Added = new(2026, 10, 1, 12, 0, 0, TimeSpan.Zero);

    public List<string> Calls { get; } = [];
    public List<(Guid Media, long Position, long Duration, bool Finished, long Revision)> Saves { get; } = [];
    public List<Guid> Revoked { get; } = [];
    public Dictionary<Guid, long> ResumePositions { get; } = [];
    public bool FailSaveWithConflict { get; set; }
    public long Revision { get; set; } = 3;
    public int TicketCount { get; private set; }

    public static ArtworkSummary Art(string name, ArtworkKind kind = ArtworkKind.Poster) =>
        new(GuidFor(name), kind, $"/api/v1/artwork/{GuidFor(name)}", "image/png", 1000, 1);

    public static CatalogItemSummary Movie => new(MovieId, MediaKind.Movie, "Synthetic Movie", null, 2020,
        "A synthetic movie for tests.", ["Drama"], Art("movie"), Art("movie-backdrop", ArtworkKind.Backdrop), MediaAvailability.Available,
        false, null, Added);

    public static CatalogItemSummary SecondMovie => new(SecondMovieId, MediaKind.Movie, "Second Feature", null, 2024, null, ["Comedy"],
        Art("second"), null, MediaAvailability.Available, true, null, Added);

    public static CatalogItemSummary Series => new(SeriesId, MediaKind.Series, "Synthetic Series", null, 2008, "A synthetic series.",
        ["Drama"], Art("series"), Art("series-backdrop", ArtworkKind.Backdrop), MediaAvailability.Available, false, null, Added);

    public static CatalogItemSummary Episode(int number) => new(number == 1 ? EpisodeOneId : EpisodeTwoId, MediaKind.Episode,
        number == 1 ? "Pilot" : "The Second One", null, 2008, "An episode.", [], null, Art($"still-{number}", ArtworkKind.Still),
        MediaAvailability.Available, false,
        number == 1 ? new PlaybackProgressResponse(EpisodeOneId, 600_000, 2_700_000, false, Added, Added, 3) : null, Added,
        "Synthetic Series", 1, number, SeriesId);

    public Task<HomeResponse> HomeAsync(CancellationToken cancellation)
    {
        Calls.Add("home");
        return Task.FromResult(new HomeResponse(Series, [Episode(1)], [Movie, SecondMovie, Series], [SecondMovie],
            [new CollectionSummary(Guid.NewGuid(), "Synthetic Collection", null, [Movie])], Added));
    }

    public Task<PagedResponse<CatalogItemSummary>> BrowseAsync(MediaKind kind, int offset, int limit, CancellationToken cancellation)
    {
        Calls.Add($"browse {kind} {offset}");
        IReadOnlyList<CatalogItemSummary> all = kind == MediaKind.Movie ? [Movie, SecondMovie] : [Series];
        return Task.FromResult(new PagedResponse<CatalogItemSummary>([.. all.Skip(offset).Take(limit)], offset, limit, all.Count));
    }

    public Task<PagedResponse<CatalogItemSummary>> SearchAsync(string term, int offset, int limit, CancellationToken cancellation)
    {
        Calls.Add("search " + term);
        IReadOnlyList<CatalogItemSummary> found = [.. new[] { Movie, SecondMovie, Series }
            .Where(item => item.Title.Contains(term, StringComparison.OrdinalIgnoreCase))];
        return Task.FromResult(new PagedResponse<CatalogItemSummary>(found, offset, limit, found.Count));
    }

    public Task<CatalogDetailPresentation> DetailAsync(Guid id, CancellationToken cancellation)
    {
        Calls.Add("detail " + id);
        var item = id == SeriesId ? Series : id == SecondMovieId ? SecondMovie : Movie;
        var metadata = new MediaMetadataSummary(id, item.Title, null, item.Overview, null, item.Year, id == SeriesId ? null : 104, null,
            "12", item.Genres, [], [], [], item.Poster, item.Backdrop, null, null, null, MetadataReviewState.Matched);
        IReadOnlyList<SeasonPresentation> seasons = id == SeriesId
            ? [new SeasonPresentation(1, [new EpisodePresentation(Episode(1), 1, 1), new EpisodePresentation(Episode(2), 1, 2)], [])]
            : [];
        IReadOnlyList<SupplementPresentation> extras = id == MovieId
            ? [new SupplementPresentation(new CatalogItemSummary(Guid.NewGuid(), MediaKind.Trailer, "Synthetic Trailer", null, null, null, [],
                null, null, MediaAvailability.Available, false, null, Added), "Trailer", null)]
            : [];
        return Task.FromResult(new CatalogDetailPresentation(item, metadata, seasons, extras));
    }

    public Task<PlaybackPlanResponse> PlaybackPlanAsync(Guid id, CancellationToken cancellation)
    {
        Calls.Add("plan " + id);
        return Task.FromResult(id == SeriesId || id == EpisodeOneId
            ? new PlaybackPlanResponse(Episode(1), SeriesId, [Episode(2)], PlaybackPlanAction.Resume, true)
            : id == EpisodeTwoId
                ? new PlaybackPlanResponse(Episode(2), SeriesId, [], PlaybackPlanAction.Play, true)
                : new PlaybackPlanResponse(id == SecondMovieId ? SecondMovie : Movie, null, [], PlaybackPlanAction.Play, false));
    }

    public Task<bool> SetFavoriteAsync(Guid id, bool favorite, CancellationToken cancellation)
    {
        Calls.Add($"favorite {id} {favorite}");
        return Task.FromResult(favorite);
    }

    public Task<byte[]> ArtworkAsync(ArtworkSummary artwork, int width, CancellationToken cancellation)
    {
        Calls.Add("artwork " + artwork.Id);
        return Task.FromResult(Picture(artwork.Id, artwork.Kind == ArtworkKind.Poster ? (200, 300) : (640, 360)));
    }

    public Task<PlaybackSourceResponse> CreatePlaybackAsync(Guid mediaId, CancellationToken cancellation)
    {
        TicketCount++;
        Calls.Add("ticket " + mediaId);
        var resume = ResumePositions.GetValueOrDefault(mediaId);
        return Task.FromResult(new PlaybackSourceResponse(Guid.NewGuid(), mediaId, "/api/v1/streams/" + new string('t', 40), "video/x-msvideo",
            1000, DateTimeOffset.UtcNow.AddHours(12),
            new PlaybackProgressResponse(mediaId, resume, 2_700_000, false, null, null, Revision)));
    }

    public Task RevokePlaybackAsync(Guid ticketId, CancellationToken cancellation)
    {
        Revoked.Add(ticketId);
        return Task.CompletedTask;
    }

    public Task<PlaybackProgressResponse> ProgressAsync(Guid mediaId, CancellationToken cancellation) =>
        Task.FromResult(new PlaybackProgressResponse(mediaId, 999_000, 2_700_000, false, null, null, Revision + 5));

    public Task<PlaybackProgressResponse> SaveProgressAsync(Guid mediaId, long position, long duration, bool finished, long expectedRevision,
        Guid mutationId, CancellationToken cancellation)
    {
        Saves.Add((mediaId, position, duration, finished, expectedRevision));
        if (FailSaveWithConflict) return Task.FromException<PlaybackProgressResponse>(new AureliaApiException(409, "progress_conflict", "Conflict"));
        return Task.FromResult(new PlaybackProgressResponse(mediaId, position, duration, finished, null, null, expectedRevision + 1, mutationId));
    }

    public Task<IReadOnlyList<string>> CapabilitiesAsync(CancellationToken cancellation) =>
        Task.FromResult<IReadOnlyList<string>>(["library-state-v1", "preview-streams-v1"]);

    public StreamSource StreamSource(PlaybackSourceResponse ticket) =>
        new(new Uri("https://192.168.1.20:43111" + ticket.StreamPath), new HttpClient(), "synthetic-profile-token");

    private static Guid GuidFor(string name) => new(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(name))[..16]);

    /// <summary>A gradient picture whose colour depends on the artwork, so screens look plausible.</summary>
    private static byte[] Picture(Guid id, (int Width, int Height) size)
    {
        var bytes = id.ToByteArray();
        using var bitmap = new SKBitmap(size.Width, size.Height);
        using (var canvas = new SKCanvas(bitmap))
        {
            using var paint = new SKPaint
            {
                Shader = SKShader.CreateLinearGradient(new SKPoint(0, 0), new SKPoint(size.Width, size.Height),
                    [new SKColor(bytes[0], bytes[1], bytes[2]), new SKColor((byte)(bytes[3] / 3), (byte)(bytes[4] / 3), (byte)(bytes[5] / 3))],
                    SKShaderTileMode.Clamp),
            };
            canvas.DrawRect(0, 0, size.Width, size.Height, paint);
        }
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 90);
        return data.ToArray();
    }
}

/// <summary>A scripted decoder: the test moves its clock and raises its events.</summary>
internal sealed class FakeVideoEngine : IVideoEngine
{
    public event Action? Changed;
    public event Action<EngineEnd>? Finished;

    public bool NightMode { get; init; }
    public List<(Uri Url, long Start)> Opened { get; } = [];
    public List<long> Seeks { get; } = [];
    public bool Disposed { get; private set; }
    public long Time { get; set; }
    public long Length { get; set; } = 2_700_000;
    public bool IsPlaying { get; set; }
    public double Rate { get; set; } = 1;
    public int Volume { get; set; } = 100;
    public bool Muted { get; set; }
    public IReadOnlyList<MediaTrack> AudioTracks { get; set; } = [];
    public IReadOnlyList<MediaTrack> SubtitleTracks { get; set; } = [];
    public int AudioTrack { get; set; } = -1;
    public int SubtitleTrack { get; set; } = -1;

    public void Open(Uri url, long startMilliseconds)
    {
        Opened.Add((url, startMilliseconds));
        Time = 0;
        IsPlaying = true;
    }

    public void Play() => IsPlaying = true;
    public void Pause() => IsPlaying = false;
    public void Unload() => IsPlaying = false;

    public void Seek(long milliseconds)
    {
        Seeks.Add(milliseconds);
        Time = milliseconds;
    }

    /// <summary>Moves the clock and tells the player, like VLC's time events.</summary>
    public void Advance(long time)
    {
        Time = time;
        Changed?.Invoke();
    }

    public void Raise(EngineEnd end) => Finished?.Invoke(end);
    public void Dispose() => Disposed = true;
}

internal sealed class FakeEngineFactory : IVideoEngineFactory
{
    public List<FakeVideoEngine> Created { get; } = [];

    public IVideoEngine Create(bool nightMode)
    {
        var engine = new FakeVideoEngine { NightMode = nightMode };
        Created.Add(engine);
        return engine;
    }
}

/// <summary>A relay that only hands out an address; the fake engine never reads it.</summary>
internal sealed class FakeRelay(string? purpose) : IStreamRelay
{
    public string? Purpose => purpose;
    public bool Disposed { get; private set; }
    public event Action<int>? Failed;

    public Uri Start() => new($"http://127.0.0.1:9/{purpose ?? "stream"}");

    public void Fail(int status) => Failed?.Invoke(status);

    public ValueTask DisposeAsync()
    {
        Disposed = true;
        return ValueTask.CompletedTask;
    }
}
