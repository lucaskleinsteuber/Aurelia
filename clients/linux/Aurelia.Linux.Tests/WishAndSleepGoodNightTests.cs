using System.Net;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Library;
using Aurelia.Linux.Playback;
using Aurelia.Linux.Settings;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Input;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class WishAndSleepGoodNightTests
{
    private sealed class RecordingPlaybackSystem : IPlaybackSystem
    {
        public List<bool> AwakeStates { get; } = [];

        public bool IsAwake { get; private set; }

        public void KeepAwake(bool awake)
        {
            IsAwake = awake;
            AwakeStates.Add(awake);
        }

        public void Update(PlaybackController? controller)
        {
        }
    }

    private sealed class RecordingNotifications : IDesktopNotificationService
    {
        public List<WishNotificationEvent> Sent { get; } = [];

        public Task NotifyAsync(WishNotificationEvent notification, CancellationToken cancellation = default)
        {
            Sent.Add(notification);
            return Task.CompletedTask;
        }
    }

    [Fact]
    public void LegacyPlaybackPreferencesDecodeWithShowGoodNightOff()
    {
        const string legacyJson = """{"automaticResume":true,"preventSleep":true,"autoplayNextEpisode":false}""";
        var decoded = JsonSerializer.Deserialize<PlaybackPreferences>(legacyJson, AureliaJson.Options);
        Assert.NotNull(decoded);
        Assert.False(decoded.ShowGoodNightOnSleepTimer);
        Assert.True(decoded.AutomaticResume);
        Assert.True(decoded.PreventSleep);
    }

    [Fact]
    public void ScreenTimeTextFormatsSleepTimerGoodNightAndOmitsStopOrOff()
    {
        var sleep = ScreenTimeText.GoodNight(new SleepTimerEndedResponse("sleep", true, 5), "Lucas");
        Assert.Equal("Good night, Lucas", sleep.Title);
        Assert.Contains("goes to sleep in about 5 minutes", sleep.Text);

        var shutdown = ScreenTimeText.GoodNight(new SleepTimerEndedResponse("shutdown", true, 1), "");
        Assert.Equal("Good night", shutdown.Title);
        Assert.Contains("turns off in about 1 minute", shutdown.Text);

        var off = ScreenTimeText.GoodNight(new SleepTimerEndedResponse("off", true, 5), "Mia");
        Assert.Equal("Sleep well.", off.Text);

        var stop = ScreenTimeText.GoodNight(new SleepTimerEndedResponse("stop", true, 5), "Mia");
        Assert.Equal("Sleep well.", stop.Text);

        var notAfterTimer = ScreenTimeText.GoodNight(new SleepTimerEndedResponse("sleep", false, 5), "Mia");
        Assert.Equal("Sleep well.", notAfterTimer.Text);
    }

    [Fact]
    public void WishPresentationCalculatesBadgesNotificationsAndYearValidation()
    {
        var summary = new WishSummaryResponse(OpenCount: 4, NewlyFulfilledCount: 2);
        Assert.Equal(6, WishPresentation.BadgeCount(summary, isAdmin: true));
        Assert.Equal(2, WishPresentation.BadgeCount(summary, isAdmin: false));
        Assert.Equal(0, WishPresentation.BadgeCount(null, isAdmin: true));

        Assert.Null(WishPresentation.NotificationForChange(null, summary, isAdmin: true));

        var baseline = new WishSummaryResponse(1, 0);
        var openIncreased = WishPresentation.NotificationForChange(baseline, new WishSummaryResponse(2, 0), isAdmin: true);
        Assert.NotNull(openIncreased);
        Assert.Equal("New family wish", openIncreased.Title);
        Assert.Null(WishPresentation.NotificationForChange(baseline, new WishSummaryResponse(2, 0), isAdmin: false));

        var fulfilled = WishPresentation.NotificationForChange(baseline, new WishSummaryResponse(1, 1), isAdmin: false);
        Assert.NotNull(fulfilled);
        Assert.Equal("Your wish is here", fulfilled.Title);

        Assert.Equal(2024, WishPresentation.ParseYear("2024", out var validError));
        Assert.Null(validError);
        Assert.Equal(2024, WishPresentation.ParseYear(" 2024 ", out validError));
        Assert.Null(validError);
        Assert.Null(WishPresentation.ParseYear("1700", out var rangeError));
        Assert.NotNull(rangeError);
        Assert.Null(WishPresentation.ParseYear("abc", out var parseError));
        Assert.NotNull(parseError);
    }

    [Fact]
    public async Task SleepTimerGoodNightReleasesWakeLockAndAutoClosesAfterFiveMinutes()
    {
        var server = FakeLibrary.Create(pictures: false);
        server.Answer("POST", "/api/v1/playback/sleep-timer-ended", """{"powerMode":"sleep","afterSleepTimer":true,"minutes":5}""");
        server.Answer("DELETE", "/api/v1/playback/" + Guid.Empty, "{}");
        server.Replace("POST", $"/api/v1/media/{FakeLibrary.MovieA}/playback", JsonSerializer.Serialize(new PlaybackSourceResponse(
            Guid.NewGuid(), FakeLibrary.MovieA, "/api/v1/streams/ticket-movie", "video/x-matroska", 1000, DateTimeOffset.UtcNow.AddHours(4),
            new PlaybackProgressResponse(FakeLibrary.MovieA, 0, 3_600_000, false, null, null, 1), null,
            new ScreenTimeStatus(ScreenTimeState.Open, ScreenTimeReason.None, 10, 120, 110, null, null, null, ScreenTimeLockScope.WholeProfile, ScreenTimeEnding.FinishTitle, false)),
            AureliaJson.Options));

        using var api = new AureliaApi(server);
        var stored = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
            "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));
        var profile = new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
            "profile-token-synthetic-0000000000000000001", DateTimeOffset.UtcNow.AddHours(12));
        var client = new LibraryClient(api, stored, profile, ["library-state-v1"]);
        var settings = new MemorySettingsStore();
        new PlaybackPreferences(ShowGoodNightOnSleepTimer: true, PreventSleep: true).Save(settings);
        var engines = new SimulatedEngines();
        var time = new ManualTime();
        var system = new RecordingPlaybackSystem();
        var closed = 0;

        await using var player = new PlaybackController(new PlaybackClient(api, client), engines, settings, new ProgressOutbox(null), time, a => a(), system);
        player.Closed += () => closed++;
        await player.StartAsync(FakeLibrary.Item(FakeLibrary.MovieA, MediaKind.Movie, "Quiet Orbit", 2024, []), resume: false);
        Assert.True(system.IsAwake);

        player.SetSleepTimer(new SleepTimer(1, false));
        for (var second = 0; second < 60 && !player.ShowsGoodNight; second++)
        {
            engines.Last.Advance(1_000);
            time.Advance(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
        }
        for (var i = 0; i < 40 && player.SleepTimerEndedStatus is null; i++) await Task.Delay(5, TestContext.Current.CancellationToken);

        Assert.True(player.ShowsGoodNight);
        Assert.True(player.ShowsSleepTimerGoodNight);
        Assert.False(player.GoodNightEndsProfile, "Sleep-timer Good Night must never end a profile.");
        Assert.False(system.IsAwake, "Wake lock must end when Good Night shows.");
        Assert.Equal("sleep", player.SleepTimerEndedStatus?.PowerMode);
        Assert.Equal(5, player.SleepTimerEndedStatus?.Minutes);
        Assert.Equal(0, closed);

        time.Advance(TimeSpan.FromMinutes(4), TimeSpan.FromMinutes(1));
        await Task.Delay(20, TestContext.Current.CancellationToken);
        Assert.Equal(0, closed);

        time.Advance(TimeSpan.FromMinutes(1), TimeSpan.FromSeconds(30));
        for (var i = 0; i < 40 && closed == 0; i++) await Task.Delay(5, TestContext.Current.CancellationToken);
        Assert.Equal(1, closed);
    }

    [Fact]
    public async Task DismissSleepGoodNightCancelsAutoCloseAndClosesImmediately()
    {
        var server = FakeLibrary.Create(pictures: false);
        server.Answer("POST", "/api/v1/playback/sleep-timer-ended", """{"powerMode":"off","afterSleepTimer":false,"minutes":0}""");
        server.Answer("DELETE", "/api/v1/playback/" + Guid.Empty, "{}");
        server.Replace("POST", $"/api/v1/media/{FakeLibrary.MovieA}/playback", JsonSerializer.Serialize(new PlaybackSourceResponse(
            Guid.NewGuid(), FakeLibrary.MovieA, "/api/v1/streams/ticket-movie", "video/x-matroska", 1000, DateTimeOffset.UtcNow.AddHours(4),
            new PlaybackProgressResponse(FakeLibrary.MovieA, 0, 3_600_000, false, null, null, 1)), AureliaJson.Options));

        using var api = new AureliaApi(server);
        var stored = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
            "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));
        var profile = new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
            "profile-token-synthetic-0000000000000000001", DateTimeOffset.UtcNow.AddHours(12));
        var client = new LibraryClient(api, stored, profile, ["library-state-v1"]);
        var settings = new MemorySettingsStore();
        new PlaybackPreferences(ShowGoodNightOnSleepTimer: true).Save(settings);
        var engines = new SimulatedEngines();
        var time = new ManualTime();
        var closed = 0;

        await using var player = new PlaybackController(new PlaybackClient(api, client), engines, settings, new ProgressOutbox(null), time, a => a());
        player.Closed += () => closed++;
        await player.StartAsync(FakeLibrary.Item(FakeLibrary.MovieA, MediaKind.Movie, "Quiet Orbit", 2024, []), resume: false);

        player.SetSleepTimer(new SleepTimer(1, false));
        for (var second = 0; second < 60 && !player.ShowsGoodNight; second++)
        {
            engines.Last.Advance(1_000);
            time.Advance(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
        }
        for (var i = 0; i < 40 && player.SleepTimerEndedStatus is null; i++) await Task.Delay(5, TestContext.Current.CancellationToken);
        Assert.True(player.ShowsSleepTimerGoodNight);

        await player.DismissSleepGoodNightAsync();
        Assert.Equal(1, closed);

        time.Advance(TimeSpan.FromMinutes(6), TimeSpan.FromMinutes(1));
        await Task.Delay(20, TestContext.Current.CancellationToken);
        Assert.Equal(1, closed);
    }

    [Fact]
    public async Task WishPosterCacheDeduplicatesAndEnforcesDiskLimit()
    {
        var temp = Directory.CreateTempSubdirectory("aurelia-wish-cache-");
        try
        {
            var server = FakeLibrary.Create(pictures: false, wishes: true);
            var payload = Enumerable.Repeat((byte)0xAB, 700).ToArray();
            server.Image("/api/v1/wishes/poster", payload);
            using var api = new AureliaApi(server);
            var stored = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
                "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));
            var profile = new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
                "profile-token-synthetic-0000000000000000001", DateTimeOffset.UtcNow.AddHours(12));
            var client = new LibraryClient(api, stored, profile, ["library-state-v1", ServerFeatures.Wishes]);

            var cache = new WishPosterCache(temp.FullName, memoryLimit: 1024, diskLimit: 1024);
            var first = cache.LoadAsync(client, "/p1.jpg", CancellationToken.None);
            var second = cache.LoadAsync(client, "/p1.jpg", CancellationToken.None);
            var results = await Task.WhenAll(first, second);
            Assert.Equal(700, results[0]?.Length);
            Assert.Equal(700, results[1]?.Length);
            Assert.Equal(1, server.Requests.Count(r => r == "GET /api/v1/wishes/poster"));

            await cache.LoadAsync(client, "/p2.jpg", CancellationToken.None);
            Assert.True(cache.MemoryByteCount <= 1024);
            cache.PruneDiskNow();
            var totalDisk = new DirectoryInfo(temp.FullName).GetFiles("*.img").Sum(f => f.Length);
            Assert.True(totalDisk <= 1024, $"Expected pruned cache <= 1024 bytes, found {totalDisk}");
        }
        finally
        {
            temp.Delete(true);
        }
    }

    [Fact]
    public async Task FreedesktopNotificationsNoOpGracefullyAndStoreRefreshesOnUserStateSync()
    {
        await new FreedesktopNotificationService().NotifyAsync(new WishNotificationEvent("Title", "Body"), TestContext.Current.CancellationToken);

        var server = FakeLibrary.Create(pictures: false, wishes: true);
        using var api = new AureliaApi(server);
        var stored = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
            "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));
        var profile = new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
            "profile-token-synthetic-0000000000000000001", DateTimeOffset.UtcNow.AddHours(12));
        var client = new LibraryClient(api, stored, profile, ["library-state-v1", ServerFeatures.Wishes]);
        var prefs = new GeneralPreferences(new MemorySettingsStore());
        var sent = new List<WishNotificationEvent>();
        var store = new LibraryStore(client, new ArtworkCache(null), prefs, _ => { }, new WishPosterCache(null));
        store.WishNotificationRequested += e => sent.Add(e);

        await store.RefreshAsync();
        Assert.Empty(sent);
        Assert.Equal(1, store.WishBadgeCount);
        Assert.DoesNotContain("GET /api/v1/wishes", server.Requests);

        server.Replace("GET", "/api/v1/wishes/summary", JsonSerializer.Serialize(new WishSummaryResponse(2, 0), AureliaJson.Options));
        await store.ApplyChangesAsync(new SyncChangesResponse(2, false, [SyncChangeArea.UserState], [FakeLibrary.MovieA]));
        Assert.Single(sent);
        Assert.Equal(2, store.WishBadgeCount);

        prefs.WishNotificationsEnabled = false;
        server.Replace("GET", "/api/v1/wishes/summary", JsonSerializer.Serialize(new WishSummaryResponse(3, 0), AureliaJson.Options));
        await store.ApplyChangesAsync(new SyncChangesResponse(3, false, [SyncChangeArea.UserState], [FakeLibrary.MovieA]));
        Assert.Single(sent);
        Assert.Equal(3, store.WishBadgeCount);
    }

    [AvaloniaFact]
    public void PlayerViewDisplaysAndDismissesSleepTimerGoodNightWithoutEndingProfile()
    {
        var server = FakeLibrary.Create(wishes: true);
        server.Answer("POST", "/api/v1/playback/sleep-timer-ended", """{"powerMode":"sleep","afterSleepTimer":true,"minutes":8}""");
        var time = new ManualTime();
        var engines = new SimulatedEngines();
        var window = FakeLibrary.ShowLibrary(server, engines, time: time);
        new PlaybackPreferences(ShowGoodNightOnSleepTimer: true).Save(window.Session.Preferences.Store);

        var movie = window.Session.Library!.Catalog.First(i => i.Id == FakeLibrary.MovieA);
        _ = window.PlayAsync(movie, resume: false);
        FakeLibrary.Pump(() => window.Player?.State == PlayerState.Playing);
        var view = window.GetVisualDescendants().OfType<PlayerView>().Single();

        window.Player!.SetSleepTimer(new SleepTimer(1, false));
        time.Advance(TimeSpan.FromSeconds(61), TimeSpan.FromSeconds(1));
        FakeLibrary.Pump(() => window.Player?.SleepTimerEndedStatus is not null);
        FakeLibrary.Pump(() => false, rounds: 10);

        var texts = view.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text).ToList();
        Assert.Contains("Good night, Lucas", texts);
        Assert.Contains(texts, t => t?.Contains("goes to sleep in about 8 minutes", StringComparison.Ordinal) == true);
        Assert.Equal(Core.Flow.AppScreen.Library, window.Flow.Screen);

        view.Focus();
        window.KeyPressQwerty(PhysicalKey.Escape, RawInputModifiers.None);
        FakeLibrary.Pump(() => window.Player is null);
        Assert.Null(window.Player);
        Assert.Equal(Core.Flow.AppScreen.Library, window.Flow.Screen);
    }

    [AvaloniaFact]
    public void SidebarSettingsAndWishesPageWorkEndToEnd()
    {
        var unsupported = FakeLibrary.ShowLibrary(FakeLibrary.Create(wishes: false));
        Assert.DoesNotContain(unsupported.Shell!.SidebarItems, item => item.Destination == LibraryDestination.Wishes);

        var server = FakeLibrary.Create(wishes: true);
        var notifier = new RecordingNotifications();
        var window = FakeLibrary.ShowLibrary(server, notifications: notifier);

        var wishesItem = Assert.Single(window.Shell!.SidebarItems, item => item.Destination == LibraryDestination.Wishes);
        Assert.Equal(1, wishesItem.BadgeCount);

        var settings = window.OpenSettings(SettingsCategory.Playback);
        FakeLibrary.Pump(() => false, rounds: 10);
        var sleepToggle = settings.Page!.GetVisualDescendants().OfType<ToggleSwitch>()
            .Single(t => AutomationProperties.GetName(t) == "Show Good Night When the Sleep Timer Ends");
        Assert.False(sleepToggle.IsChecked == true);
        sleepToggle.IsChecked = true;
        Assert.True(PlaybackPreferences.Load(window.Session.Preferences.Store).ShowGoodNightOnSleepTimer);

        settings.Category = SettingsCategory.General;
        FakeLibrary.Pump(() => false, rounds: 10);
        var notifToggle = settings.Page!.GetVisualDescendants().OfType<ToggleSwitch>()
            .Single(t => AutomationProperties.GetName(t) == "Family Wish Notifications");
        Assert.True(notifToggle.IsChecked == true);
        notifToggle.IsChecked = false;
        Assert.False(window.Session.Preferences.WishNotificationsEnabled);
        Assert.Contains(SettingsCategory.Playback, SettingsView.Matching("good night"));
        Assert.Contains(SettingsCategory.General, SettingsView.Matching("wishes"));

        settings.Close();
        window.Shell.Destination = LibraryDestination.Wishes;
        var page = Assert.IsType<WishesPage>(window.Shell.CurrentPage);
        FakeLibrary.Pump(() => page.LoadedWishes.Count > 0);
        Assert.Equal("Solaris Horizon", page.LoadedWishes[0].Title);
        Assert.Contains("GET /api/v1/wishes", server.Requests);

        var texts = page.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text).ToList();
        Assert.Contains(texts, t => t?.Contains("Solaris Horizon", StringComparison.Ordinal) == true);
        Assert.Contains(texts, t => t?.Contains("Also wished by Ben", StringComparison.Ordinal) == true);
    }

    [AvaloniaFact]
    public void SettingsViewSavesAndSearchesGoodNightWithoutBreakingMatches()
    {
        Assert.Equal([SettingsCategory.Playback], SettingsView.Matching("subtitle"));
        Assert.Contains(SettingsCategory.Playback, SettingsView.Matching("sleep timer"));
    }
}
