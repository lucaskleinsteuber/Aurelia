using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Views;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>The offline mode with invented downloads in a temporary folder; nothing is played or fetched.</summary>
public sealed class OfflineModeTests : IDisposable
{
    private static readonly JsonSerializerOptions WebJson = new(JsonSerializerDefaults.Web);
    private static readonly Guid Mia = Guid.Parse("22222222-0000-4000-8000-000000000002");
    private readonly string root = Path.Combine(Path.GetTempPath(), "aurelia-offline-mode-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
    }

    private static OfflineTitle Title(string name, MediaKind kind, Guid user, long position = 0, string? series = null, int? season = null, int? episode = null) =>
        new(Guid.NewGuid(), FakeServer.ServerId, user, name, null, kind, "title.mkv", "video/x-matroska", 4, DateTimeOffset.UtcNow, position, 600_000,
            false, position > 0 ? DateTimeOffset.UtcNow : null, false, [], ParentTitle: series, SeasonNumber: season, EpisodeNumber: episode, Year: 2024);

    /// <summary>Downloads of invented titles, written as the app writes them.</summary>
    private OfflineDownloads Downloads(params OfflineTitle[] titles)
    {
        foreach (var title in titles)
        {
            var folder = Path.Combine(root, title.Id.ToString("N"));
            Directory.CreateDirectory(folder);
            File.WriteAllBytes(Path.Combine(folder, title.FileName), [1, 2, 3, 4]);
        }
        Directory.CreateDirectory(root);
        File.WriteAllText(Path.Combine(root, "index.json"), JsonSerializer.Serialize(titles, WebJson));
        return new OfflineDownloads(root);
    }

    private static WatchingProfile Profile(Guid id, string name, bool pin = true) => new(id, name, UserRole.User, false, pin);

    private sealed class ManualTime : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;

        public override DateTimeOffset GetUtcNow() => Now;
    }

    [Fact]
    public void ACardChecksThePinWithoutKeepingIt()
    {
        var card = OfflineProfileCard.Make(FakeServer.ServerId, Profile(Mia, "Mia"), "4821", DateTimeOffset.UtcNow);
        Assert.True(card.PinProtected);
        Assert.True(card.Accepts("4821"));
        Assert.False(card.Accepts("4820"));
        Assert.False(card.Accepts(null));
        Assert.DoesNotContain("4821", JsonSerializer.Serialize(card, WebJson), StringComparison.Ordinal);
        Assert.True(OfflineProfileCard.Make(FakeServer.ServerId, Profile(Mia, "Mia", pin: false), null, DateTimeOffset.UtcNow).Accepts(null));
    }

    [Fact]
    public void FiveWrongPinsMakeFurtherTriesWaitLongerEachTime()
    {
        var downloads = Downloads(Title("Invented Film", MediaKind.Movie, Mia));
        var store = new OfflineProfileStore(null);
        var card = OfflineProfileCard.Make(FakeServer.ServerId, Profile(Mia, "Mia"), "4821", DateTimeOffset.UtcNow);
        store.Remember(card);
        var time = new ManualTime();
        var model = new OfflineModeModel(downloads, store, FakeServer.ServerId, "Living Room Server", time);
        Assert.Null(model.Session);
        for (var attempt = 0; attempt < 5; attempt++) Assert.False(model.OpenProfile(card, "0000"));
        Assert.Equal(time.Now.AddSeconds(30), model.LockedUntil);
        // While locked even the right PIN waits.
        Assert.False(model.OpenProfile(card, "4821"));
        time.Now = time.Now.AddSeconds(31);
        Assert.False(model.OpenProfile(card, "0000"));
        Assert.Equal(time.Now.AddSeconds(60), model.LockedUntil);
        time.Now = time.Now.AddSeconds(61);
        Assert.True(model.OpenProfile(card, "4821"));
        Assert.Null(model.LockedUntil);
        Assert.Equal("Invented Film", Assert.Single(model.Titles).Title);
    }

    [Fact]
    public void CardsArePrivateKeptPerServerAndForgottenWithIt()
    {
        var path = Path.Combine(root, "offline-profiles.json");
        var store = new OfflineProfileStore(path);
        store.Remember(OfflineProfileCard.Make(FakeServer.ServerId, Profile(Mia, "Mia", pin: false), null, DateTimeOffset.UtcNow));
        store.Remember(OfflineProfileCard.Make(FakeServer.ServerId, Profile(Mia, "Mia Renamed", pin: false), null, DateTimeOffset.UtcNow));
        var other = Guid.NewGuid();
        store.Remember(OfflineProfileCard.Make(other, Profile(Mia, "Mia", pin: false), null, DateTimeOffset.UtcNow));
        if (!OperatingSystem.IsWindows())
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(path));
        var reopened = new OfflineProfileStore(path);
        Assert.Equal("Mia Renamed", Assert.Single(reopened.Cards(FakeServer.ServerId)).Name);
        reopened.Forget(FakeServer.ServerId);
        Assert.Empty(new OfflineProfileStore(path).Cards(FakeServer.ServerId));
        Assert.Single(new OfflineProfileStore(path).Cards(other));
    }

    [Fact]
    public void TheLibraryFeaturesWhatPlaysAndGroupsEpisodesBySeries()
    {
        var film = Title("Amber Fields", MediaKind.Movie, Mia);
        var second = Title("The Return", MediaKind.Episode, Mia, series: "Cobalt Station", season: 1, episode: 2);
        var first = Title("Arrival", MediaKind.Episode, Mia, position: 120_000, series: "Cobalt Station", season: 1, episode: 1);
        var layout = new OfflineLibraryLayout([film, second, first]);
        Assert.Equal(first.Id, layout.Featured!.Id);
        Assert.Equal([first.Id], layout.ContinueWatching.Select(t => t.Id));
        Assert.Equal(["Amber Fields"], layout.Movies.Select(t => t.Title));
        var series = Assert.Single(layout.SeriesList);
        Assert.Equal("Cobalt Station", series.Title);
        Assert.Equal(["Arrival", "The Return"], series.Episodes.Select(t => t.Title));
        Assert.Equal("S1 E2", OfflineLibraryLayout.EpisodeLabel(second));
    }

    [AvaloniaFact]
    public void ASilentServerOffersTheDownloadsAndAPinOpensThem()
    {
        var downloads = Downloads(
            Title("Invented Film", MediaKind.Movie, Mia, position: 60_000),
            Title("Arrival", MediaKind.Episode, Mia, series: "Cobalt Station", season: 1, episode: 1));
        var keyring = new MemoryCredentialStore
        {
            Server = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
                "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30)),
        };
        new OfflineProfileStore(Path.Combine(root, "offline-profiles.json"))
            .Remember(OfflineProfileCard.Make(FakeServer.ServerId, Profile(Mia, "Mia"), "4821", DateTimeOffset.UtcNow));
        var window = TestWindows.Show(AppServices.ForTests(transport: new UnreachableTransport(), credentials: keyring) with { Downloads = downloads });
        window.Session.StopWaiting();
        FakeLibrary.Pump(() => window.Flow.Screen == AppScreen.ServerUnreachable, rounds: 400);
        Click(Visible<Button>(window, b => b.Content as string == "Watch Downloads Offline"));
        Assert.Equal(AppScreen.Offline, window.Flow.Screen);
        Assert.True(window.Session.IsOffline);

        Click(Visible<Button>(window, b => AutomationProperties.GetName(b) == "Mia"));
        var pin = Visible<TextBox>(window, t => AutomationProperties.GetName(t) == "PIN");
        pin.Text = "1111";
        Click(Visible<Button>(window, b => AutomationProperties.GetName(b) == "Open Profile"));
        Assert.Contains(Texts(window), t => t == "PIN is incorrect.");
        pin = Visible<TextBox>(window, t => AutomationProperties.GetName(t) == "PIN");
        pin.Text = "4821";
        Click(Visible<Button>(window, b => AutomationProperties.GetName(b) == "Open Profile"));

        var texts = Texts(window);
        Assert.Contains("Continue Watching", texts);
        Assert.Contains("Movies", texts);
        Assert.Contains("Cobalt Station", texts);
        Assert.Contains(window.CurrentScreen!.GetVisualDescendants().OfType<Button>(), b => AutomationProperties.GetName(b) == "Play Invented Film");
        FakeLibrary.Pump(() => false, rounds: 20);
        using (var frame = window.CaptureRenderedFrame()!) TestWindows.SaveSnapshot(frame, "offline-library");

        // Leaving looks for the server again.
        Click(Visible<Button>(window, b => b.Content as string == "Connect to Server"));
        Assert.False(window.Session.IsOffline);
        Assert.NotEqual(AppScreen.Offline, window.Flow.Screen);
    }

    [AvaloniaFact]
    public void OpeningAureliaOffersTheDownloadsWhileItWaitsForTheServer()
    {
        var downloads = Downloads(Title("Invented Film", MediaKind.Movie, Mia));
        var keyring = new MemoryCredentialStore
        {
            Server = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
                "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30)),
        };
        var window = TestWindows.Show(AppServices.ForTests(transport: new UnreachableTransport(), credentials: keyring) with { Downloads = downloads });
        // The start screen exists before the saved server is read; the offer follows once it is being reached.
        FakeLibrary.Pump(() => window.CurrentScreen is StartingView
            && window.CurrentScreen.GetVisualDescendants().OfType<Button>().Any(b => b.IsEffectivelyVisible && b.Content as string == "Watch Downloads Offline"), rounds: 400);
        Assert.IsType<StartingView>(window.CurrentScreen);
        Click(Visible<Button>(window, b => b.Content as string == "Watch Downloads Offline"));
        Assert.Equal(AppScreen.Offline, window.Flow.Screen);
        Assert.True(window.Session.IsOffline);
    }

    private static List<string?> Texts(MainWindow window) =>
        [.. window.CurrentScreen!.GetVisualDescendants().OfType<TextBlock>().Where(t => t.IsEffectivelyVisible).Select(t => t.Text)];

    private static T Visible<T>(MainWindow window, Func<T, bool> match) where T : Control =>
        window.CurrentScreen!.GetVisualDescendants().OfType<T>().First(control => control.IsEffectivelyVisible && match(control));

    private static void Click(Button button)
    {
        button.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        for (var index = 0; index < 5; index++)
        {
            Dispatcher.UIThread.RunJobs();
            Thread.Sleep(5);
        }
        Dispatcher.UIThread.RunJobs();
    }

    /// <summary>A network where the server never answers.</summary>
    private sealed class UnreachableTransport : Aurelia.Linux.Core.Api.IServerTransport
    {
        public HttpClient CreateClient(Uri address, string? expectedFingerprint, Aurelia.Linux.Core.Api.CapturedFingerprint? captured, TimeSpan timeout) =>
            new(new Failing()) { BaseAddress = address, Timeout = timeout };

        private sealed class Failing : HttpMessageHandler
        {
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
                throw new HttpRequestException("no route");
        }
    }
}
