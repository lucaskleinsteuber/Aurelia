using Aurelia.Contracts;
using Aurelia.Desktop.Core;
using Aurelia.Desktop.Playback;
using Xunit;

namespace Aurelia.Desktop.Tests;

/// <summary>
/// The whole way with the real server and real VLC: a synthetic movie in a synthetic library,
/// found, opened and played through the stream relay over pinned TLS, with a seek, saved
/// progress and timeline previews through the preview relay. Silent and windowless.
/// </summary>
public sealed class RealPlaybackTests : IDisposable
{
    private readonly string media = Path.Combine(Path.GetTempPath(), "aurelia-desktop-media-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(media)) Directory.Delete(media, recursive: true);
    }

    private sealed class SilentEngines : IVideoEngineFactory
    {
        public IVideoEngine Create(bool nightMode) => new VlcVideoEngine(nightMode, 300, ["--aout=dummy"]);
    }

    [Fact]
    public async Task FindsPlaysSeeksSavesAndPreviewsASyntheticMovie()
    {
        Assert.SkipWhen(SyntheticServer.Executable is null, "Run scripts/test-desktop.sh, which builds the server for this test.");
        var cancellation = TestContext.Current.CancellationToken;
        Directory.CreateDirectory(media);
        byte[] levels = [20, 90, 160, 235, 120, 60];
        SyntheticMedia.WriteAvi(Path.Combine(media, "Synthetic Movie (2020).avi"), levels, secondsPerLevel: 10);
        await using var server = await SyntheticServer.StartAsync();
        await server.AddMovieLibraryAsync(media);

        using var api = new AureliaServerApi();
        using var flow = new ConnectionFlow(api, new ConnectionStore(new MemorySecretStore()), new NoServerDiscovery(), "Synthetic PC",
            action => action());
        await flow.StartAsync();
        flow.Address = $"127.0.0.1:{server.HttpsPort}";
        await flow.ConnectAsync();
        var pairing = flow.TrustAndPairAsync();
        for (var attempt = 0; attempt < 100 && flow.PairingCode.Length == 0; attempt++) await Task.Delay(50, cancellation);
        await server.ApproveAsync(flow.PairingCode);
        await pairing.WaitAsync(TimeSpan.FromSeconds(30), cancellation);
        await flow.ChooseProfileAsync(flow.Profiles.Single(profile => profile.Name == SyntheticServer.GuestName));
        Assert.Equal(ConnectionPhase.Connected, flow.Phase);

        using var client = new LibraryClient(api, flow.Connection!, flow.Session!);
        var library = new LibraryModel(client);
        await library.ShowAsync(LibrarySection.Movies);
        var movie = Assert.Single(library.Movies);
        Assert.Equal("Synthetic Movie", movie.Title);
        await library.OpenDetailAsync(movie.Id);
        Assert.Equal("Play", library.PlayLabel);
        PlaybackRequest? request = null;
        library.PlayRequested += value => request = value;
        await library.PlayDetailAsync();
        Assert.NotNull(request);

        var settings = new PlaybackSettingsStore(Path.Combine(media, "settings", "playback.json"));
        var gate = new Lock();
        await using var player = new PlayerModel(client, new SilentEngines(), settings, request, action => { lock (gate) action(); });
        await player.StartAsync();
        await WaitAsync(() => !player.IsStarting && player.Position > 1_500, "the picture to move");
        var engine = (VlcVideoEngine)player.Engine;
        Assert.InRange(SyntheticMedia.Brightness(engine.Frames.Snapshot(out _, out _)!), 0, 45);
        Assert.Equal(60_000, player.Duration, tolerance: 1_500);

        // The server keeps progress between 10 s and the last 30 s of this one-minute movie.
        player.Seek(20_000);
        await WaitAsync(() => player.Position is > 20_500 and < 28_000, "the seek");
        await Task.Delay(300, cancellation);
        Assert.InRange(SyntheticMedia.Brightness(engine.Frames.Snapshot(out _, out _)!), 140, 180);

        player.Pause();
        await WaitAsync(() => !player.IsPlaying, "the pause");
        await Task.Delay(300, cancellation);
        var saved = await client.ProgressAsync(movie.Id, cancellation);
        Assert.True(saved.PositionMilliseconds is >= 20_000 and <= 30_000, $"saved {saved.PositionMilliseconds} ms, message: {player.Message}");

        // Previews read through their own relay, marked as previews for the server.
        Assert.True(player.PreviewsParallel);
        using var previews = new ScrubPreviews(player.PreviewSource!, player.Duration, player.PreviewsParallel, TimeSpan.Zero);
        previews.Start();
        await WaitAsync(() => previews.PreparedCount >= 6, "six preview frames");
        using var frame = SkiaSharp.SKBitmap.Decode(previews.Frame(24_000));
        Assert.InRange(frame.GetPixel(frame.Width / 2, frame.Height / 2).Green, 140, 180);

        await player.CloseAsync();
        var after = await client.ProgressAsync(movie.Id, cancellation);
        Assert.False(after.IsCompleted);
    }

    private static async Task WaitAsync(Func<bool> condition, string what)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(30);
        while (!condition())
        {
            if (DateTimeOffset.UtcNow > deadline) Assert.Fail($"Timed out waiting for {what}.");
            await Task.Delay(50, TestContext.Current.CancellationToken);
        }
    }
}
