using System.Text;
using System.Net;
using System.Text.Json;
using System.Runtime.InteropServices;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Playback;
using Avalonia;
using Avalonia.Headless.XUnit;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>Preview and diagnostic regression tests use invented pixels and simulated engines, never VLC or video files.</summary>
public sealed class PlaybackPreviewTests
{
    private sealed class Rig : IAsyncDisposable
    {
        public FakeServer Server { get; } = FakeLibrary.Create(pictures: false);
        public PreviewEngines Engines { get; } = new();
        public AureliaApi Api { get; }
        public PlaybackController Player { get; }

        public Rig()
        {
            Api = new AureliaApi(Server);
            var stored = new StoredServer(FakeServer.ServerId, "Private server name", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
                "private-device-token-000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));
            var profile = new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Private profile", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
                "private-profile-token-00000000000000000001", DateTimeOffset.UtcNow.AddHours(12));
            var library = new LibraryClient(Api, stored, profile, ["library-state-v1"]);
            Player = new PlaybackController(new PlaybackClient(Api, library), Engines, new MemorySettingsStore(), new ProgressOutbox(null), TimeProvider.System, action => action());
        }

        public Task StartAsync(Guid id) => Player.StartAsync(FakeLibrary.Item(id, MediaKind.Movie, "Private title", 2024, []), false);

        public async ValueTask DisposeAsync()
        {
            await Player.DisposeAsync();
            Api.Dispose();
        }
    }

    private sealed class PreviewEngines : IVideoEngineFactory, IScrubPreviewDecoderFactory
    {
        public List<PreviewDecoder> Previews { get; } = [];
        public bool InvalidFrame { get; set; }
        public IVideoEngine Create(bool nightMode) => new SimulatedEngine();
        public IScrubPreviewDecoder CreatePreviewDecoder()
        {
            var decoder = new PreviewDecoder(InvalidFrame);
            Previews.Add(decoder);
            return decoder;
        }
    }

    private sealed class PreviewDecoder(bool invalid) : IScrubPreviewDecoder
    {
        public bool Disposed { get; private set; }
        public Uri? Url { get; private set; }
        public long Position { get; private set; }
        public Task<ScrubPreviewFrame?> CaptureAsync(Uri loopbackSource, long milliseconds, CancellationToken cancellation)
        {
            Url = loopbackSource;
            Position = milliseconds;
            return Task.FromResult<ScrubPreviewFrame?>(invalid ? new ScrubPreviewFrame(321, 1, []) : new ScrubPreviewFrame(2, 1, [0, 0, 255, 255, 255, 0, 0, 255]));
        }
        public void Dispose() => Disposed = true;
    }

    [AvaloniaFact]
    public async Task MissingServerPictureUsesASilentLocalDecoderThroughItsOwnRelay()
    {
        await using var rig = new Rig();
        await rig.StartAsync(FakeLibrary.MovieA);
        using var previews = new ScrubPreviews(rig.Player);
        var picture = await previews.GetAsync(41_000);
        Assert.NotNull(picture);
        Assert.Equal(new PixelSize(2, 1), picture.PixelSize);
        var decoder = Assert.Single(rig.Engines.Previews);
        Assert.True(decoder.Url!.IsLoopback);
        Assert.Equal("http", decoder.Url.Scheme);
        Assert.StartsWith("/stream/", decoder.Url.AbsolutePath, StringComparison.Ordinal);
        Assert.Equal(45_000, decoder.Position);
        Assert.True(decoder.Disposed);
        Assert.Same(picture, await previews.GetAsync(42_000));
        Assert.Single(rig.Engines.Previews);
        Assert.Contains($"GET /api/v1/media/{FakeLibrary.MovieA}/scrub-previews/45", rig.Server.Requests);
        previews.Dispose();
        Assert.Equal(0, previews.CachedPictures);
        Assert.Null(await previews.GetAsync(41_000));
    }

    [AvaloniaTheory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task BrokenServerPicturesFallBackWithoutEscapingIntoThePlayer(bool serverFailure)
    {
        await using var rig = new Rig();
        await rig.StartAsync(FakeLibrary.MovieA);
        var path = $"/api/v1/media/{FakeLibrary.MovieA}/scrub-previews/45";
        if (serverFailure) rig.Server.Replace("GET", path, "{\"code\":\"preview_failed\",\"message\":\"Synthetic failure\"}", HttpStatusCode.InternalServerError);
        else rig.Server.Image(path, "This is not an image."u8.ToArray());
        using var previews = new ScrubPreviews(rig.Player);
        Assert.NotNull(await previews.GetAsync(41_000));
        Assert.Single(rig.Engines.Previews);
    }

    [AvaloniaFact]
    public async Task PreparedServerPictureSkipsTheLocalDecoderAndChangingTitleClearsTheCache()
    {
        await using var rig = new Rig();
        await rig.StartAsync(FakeLibrary.MovieA);
        using var image = new WriteableBitmap(new PixelSize(2, 1), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Opaque);
        using var encoded = new MemoryStream();
        image.Save(encoded, PngBitmapEncoderOptions.Default);
        rig.Server.Image($"/api/v1/media/{FakeLibrary.MovieA}/scrub-previews/45", encoded.ToArray());
        using var previews = new ScrubPreviews(rig.Player);
        Assert.NotNull(await previews.GetAsync(40_000));
        Assert.Empty(rig.Engines.Previews);
        Assert.Equal(1, previews.CachedPictures);
        await rig.StartAsync(FakeLibrary.EpisodeOne);
        rig.Engines.InvalidFrame = true;
        Assert.Null(await previews.GetAsync(40_000));
        Assert.Equal(0, previews.CachedPictures);
        Assert.True(Assert.Single(rig.Engines.Previews).Disposed);
    }

    [AvaloniaFact]
    public async Task FastPointerMovementCancelsStalePreviewWork()
    {
        await using var rig = new Rig();
        await rig.StartAsync(FakeLibrary.MovieA);
        using var previews = new ScrubPreviews(rig.Player);
        var old = previews.GetAsync(10_000);
        var latest = previews.GetAsync(500_000);
        Assert.Null(await old);
        Assert.NotNull(await latest);
        Assert.Equal(505_000, Assert.Single(rig.Engines.Previews).Position);
        Assert.DoesNotContain($"GET /api/v1/media/{FakeLibrary.MovieA}/scrub-previews/15", rig.Server.Requests);
    }

    [Fact]
    public async Task ProductionFrameCallbacksCaptureSmallStillsFromABackgroundThread()
    {
        using var frames = new VideoFrames(maximumWidth: 320);
        var chroma = Marshal.AllocHGlobal(4);
        var planes = Marshal.AllocHGlobal(IntPtr.Size);
        try
        {
            await Task.Run(() =>
            {
                var opaque = IntPtr.Zero;
                uint width = 1920, height = 1080, pitch = 0, lines = 0;
                Assert.Equal(1u, frames.Format(ref opaque, chroma, ref width, ref height, ref pitch, ref lines));
                Assert.Equal(320u, width);
                Assert.Equal(180u, height);
                frames.LockFrame(opaque, planes);
                var pixels = Enumerable.Repeat((byte)42, (int)(pitch * lines)).ToArray();
                Marshal.Copy(pixels, 0, Marshal.ReadIntPtr(planes), pixels.Length);
                frames.Display(opaque, IntPtr.Zero);
                var still = Assert.IsType<ScrubPreviewFrame>(frames.Snapshot());
                Assert.Equal(320, still.Width);
                Assert.Equal(180, still.Height);
                Assert.All(still.Pixels, value => Assert.Equal(42, value));
            }, TestContext.Current.CancellationToken);
        }
        finally
        {
            Marshal.FreeHGlobal(chroma);
            Marshal.FreeHGlobal(planes);
        }
        frames.Dispose();
        Assert.Null(frames.Snapshot());
    }

    [Fact]
    public void DiagnosticsAreBoundedAndExcludeUnrecognizedErrorText()
    {
        var diagnostics = new PlaybackDiagnostics(TimeProvider.System);
        var secret = "https://private-server/media/private-title?token=private-secret /home/person/media";
        for (var index = 0; index < 250; index++)
            diagnostics.Record(PlaybackDiagnosticKind.Failed, index, -1, PlayerState.Failed, 9999, new AureliaApiException(9999, secret, secret));
        Assert.Equal(PlaybackDiagnostics.Capacity, diagnostics.Events.Count);
        Assert.Equal(50, diagnostics.Events[0].PositionMilliseconds);
        Assert.All(diagnostics.Events, entry =>
        {
            Assert.Null(entry.Attempt);
            Assert.Null(entry.HttpStatus);
            Assert.Null(entry.ProblemCode);
            Assert.Equal(0, entry.DurationMilliseconds);
        });
        var json = Encoding.UTF8.GetString(diagnostics.Export());
        Assert.DoesNotContain("private-", json, StringComparison.Ordinal);
        Assert.DoesNotContain("/home/", json, StringComparison.Ordinal);
        Assert.Equal(1, JsonDocument.Parse(json).RootElement.GetProperty("formatVersion").GetInt32());
    }

    [Fact]
    public async Task ControllerDiagnosticsRecordActionsAndSanitizeServerFailures()
    {
        await using var rig = new Rig();
        await rig.StartAsync(FakeLibrary.MovieA);
        rig.Player.SeekBy(true);
        rig.Player.SelectAudio(new MediaTrack(1, "Private audio track"));
        await rig.Player.CloseAsync();
        Assert.Contains(rig.Player.Diagnostics.Events, entry => entry.Kind == PlaybackDiagnosticKind.Started);
        Assert.Contains(rig.Player.Diagnostics.Events, entry => entry.Kind == PlaybackDiagnosticKind.Seeked);
        Assert.Contains(rig.Player.Diagnostics.Events, entry => entry.Kind == PlaybackDiagnosticKind.AudioChanged);
        Assert.Contains(rig.Player.Diagnostics.Events, entry => entry.Kind == PlaybackDiagnosticKind.Stopped);
        var json = Encoding.UTF8.GetString(rig.Player.Diagnostics.Export());
        Assert.DoesNotContain("Private", json, StringComparison.Ordinal);
        Assert.DoesNotContain("private-", json, StringComparison.Ordinal);
        Assert.DoesNotContain("192.168", json, StringComparison.Ordinal);

        await using var failing = new Rig();
        failing.Server.Replace("POST", $"/api/v1/media/{FakeLibrary.MovieA}/playback",
            """{"code":"access_denied","message":"private-secret and private-path"}""", System.Net.HttpStatusCode.Forbidden);
        await failing.StartAsync(FakeLibrary.MovieA);
        Assert.Contains(failing.Player.Diagnostics.Events, entry => entry.Kind == PlaybackDiagnosticKind.Failed && entry.HttpStatus == 403 && entry.ProblemCode == "access_denied");
        Assert.DoesNotContain("private-", Encoding.UTF8.GetString(failing.Player.Diagnostics.Export()), StringComparison.Ordinal);
    }
}
