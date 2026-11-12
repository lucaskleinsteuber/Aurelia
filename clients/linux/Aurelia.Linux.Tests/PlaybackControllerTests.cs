using System.Net;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class PlaybackControllerTests : IAsyncDisposable
{
    private static readonly Guid Movie = FakeLibrary.MovieA;
    private readonly FakeServer server;
    private readonly SimulatedEngines engines = new();
    private readonly ManualTime time = new();
    private readonly MemorySettingsStore settings = new();
    private readonly AureliaApi api;
    private PlaybackController? controller;
    private int closed;

    public PlaybackControllerTests()
    {
        server = FakeLibrary.Create(pictures: false);
        AddTicket(Movie, "ticket-movie", position: 600_000, revision: 3);
        AddTicket(FakeLibrary.EpisodeOne, "ticket-episode-1", position: 0, revision: 1);
        AddTicket(FakeLibrary.EpisodeTwo, "ticket-episode-2", position: 0, revision: 1);
        server.Answer("GET", "/api/v1/streams/ticket-movie/subtitles",
            """[{"index":0,"format":"subrip","language":"eng","title":null,"isDefault":false,"isForced":false,"supported":true,"isSidecar":false},{"index":2,"format":"subrip","language":"deu","title":"Deutsch","isDefault":false,"isForced":false,"supported":true,"isSidecar":true}]""");
        server.Replace("PUT", $"/api/v1/media/{Movie}/progress", Progress(Movie, 4));
        server.Replace("PUT", $"/api/v1/media/{FakeLibrary.EpisodeOne}/progress", Progress(FakeLibrary.EpisodeOne, 2));
        server.Answer("PUT", $"/api/v1/media/{FakeLibrary.EpisodeTwo}/progress", Progress(FakeLibrary.EpisodeTwo, 2));
        server.Answer("DELETE", "/api/v1/playback/" + Guid.Empty, "{}");
        server.Answer("POST", "/api/v1/playback/sleep-timer-ended", "{}");
        api = new AureliaApi(server);
    }

    public async ValueTask DisposeAsync()
    {
        if (controller is not null) await controller.CloseAsync();
        api.Dispose();
    }

    private PlaybackController Controller(PlaybackPreferences? preferences = null, params string[] features)
    {
        (preferences ?? new PlaybackPreferences()).Save(settings);
        var stored = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
            "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));
        var profile = new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
            "profile-token-synthetic-0000000000000000001", DateTimeOffset.UtcNow.AddHours(12));
        var library = new LibraryClient(api, stored, profile, ["library-state-v1", .. features]);
        controller = new PlaybackController(new PlaybackClient(api, library), engines, settings, new ProgressOutbox(null), time, action => action());
        controller.Closed += () => closed++;
        return controller;
    }

    private static CatalogItemSummary Item(Guid id, MediaKind kind = MediaKind.Movie) =>
        FakeLibrary.Item(id, kind, "Title", 2024, [], parent: kind == MediaKind.Episode ? FakeLibrary.SeriesId : null, season: kind == MediaKind.Episode ? 1 : null, episode: kind == MediaKind.Episode ? 1 : null);

    private void AddTicket(Guid media, string ticket, long position, long revision, MediaSegmentsDto? segments = null) =>
        server.Replace("POST", $"/api/v1/media/{media}/playback", JsonSerializer.Serialize(new PlaybackSourceResponse(Guid.NewGuid(), media,
            $"/api/v1/streams/{ticket}", "video/x-matroska", 1000, DateTimeOffset.UtcNow.AddHours(4),
            new PlaybackProgressResponse(media, position, 3_600_000, false, null, null, revision), segments), AureliaJson.Options));

    private async Task<PlaybackController> StartEpisodeWithSegments(PlaybackPreferences? preferences = null)
    {
        AddTicket(FakeLibrary.EpisodeOne, "ticket-episode-1", position: 0, revision: 1, new MediaSegmentsDto(60_000, 90_000, 3_300_000));
        var player = Controller(preferences);
        await player.StartAsync(FakeLibrary.Item(FakeLibrary.SeriesId, MediaKind.Series, "Cobalt Station", 2024, []), resume: false);
        return player;
    }

    [Fact]
    public async Task SkipIntroShowsWhileTheIntroPlaysAndJumpsToItsEnd()
    {
        var player = await StartEpisodeWithSegments();
        engines.Last.Advance(58_000);
        Assert.False(player.ShowsSkipIntro);
        engines.Last.Advance(2_000);
        Assert.True(player.ShowsSkipIntro);
        player.SkipIntro();
        Assert.Equal(90_000, engines.Last.Time);
        Assert.False(player.ShowsSkipIntro);
    }

    [Fact]
    public async Task IntrosAreSkippedAutomaticallyOnceButNotAfterMovingIntoThem()
    {
        var player = await StartEpisodeWithSegments(new PlaybackPreferences(IntroSkipping: IntroSkipping.Automatic));
        engines.Last.Advance(60_000);
        Assert.Equal(90_000, engines.Last.Time);
        player.SeekTo(70_000);
        engines.Last.Advance(1_000);
        Assert.Equal(71_000, engines.Last.Time);
        Assert.True(player.ShowsSkipIntro, "The button stays offered after going back into the intro.");
    }

    [Fact]
    public async Task IntrosOffDoesNotOfferSkipIntro()
    {
        var player = await StartEpisodeWithSegments(new PlaybackPreferences(IntroSkipping: IntroSkipping.Off));
        engines.Last.Advance(70_000);
        Assert.False(player.ShowsSkipIntro);
    }

    [Fact]
    public async Task UpNextAppearsWithTheCreditsAndWatchCreditsKeepsTheNextEpisode()
    {
        var player = await StartEpisodeWithSegments(new PlaybackPreferences(UpNextCountdownSeconds: 10));
        engines.Last.Advance(3_299_000);
        Assert.Null(player.UpNext);
        engines.Last.Advance(1_000);
        Assert.Equal(FakeLibrary.EpisodeTwo, player.UpNext?.Id);
        Assert.True(player.UpNextDuringCredits);
        Assert.Equal(10, player.UpNextSeconds);
        player.DismissUpNext();
        Assert.Null(player.UpNext);
        engines.Last.Advance(300_000);
        engines.Last.End();
        await Settle();
        Assert.Equal(FakeLibrary.EpisodeTwo, player.Item?.Id);
        Assert.Equal(0, closed);
    }

    [Fact]
    public async Task TheCreditsCountdownStartsTheNextEpisodeAndFinishesThisOne()
    {
        var player = await StartEpisodeWithSegments(new PlaybackPreferences(UpNextCountdownSeconds: 10));
        engines.Last.Advance(3_300_000);
        engines.Last.Advance(10_000);
        await Settle();
        Assert.Equal(FakeLibrary.EpisodeTwo, player.Item?.Id);
        Assert.Contains("\"isFinished\":true", server.Bodies[$"PUT /api/v1/media/{FakeLibrary.EpisodeOne}/progress"], StringComparison.Ordinal);
    }

    [Fact]
    public async Task WithoutUpNextAtCreditsTheCardWaitsForTheLastSeconds()
    {
        var player = await StartEpisodeWithSegments(new PlaybackPreferences(UpNextAtCredits: false));
        engines.Last.Advance(3_400_000);
        Assert.Null(player.UpNext);
    }

    private static string Progress(Guid media, long revision) =>
        JsonSerializer.Serialize(new PlaybackProgressResponse(media, 1, 3_600_000, false, null, DateTimeOffset.UtcNow, revision), AureliaJson.Options);

    private static async Task Settle()
    {
        for (var i = 0; i < 20; i++) await Task.Yield();
        await Task.Delay(20);
    }

    [Fact]
    public async Task ResumesAtTheSavedPositionThroughTheRelayWithSidecarSubtitles()
    {
        var player = Controller();
        await player.StartAsync(Item(Movie), resume: true);
        await Settle();
        var engine = engines.Last;
        Assert.Equal(600_000, engine.OpenedAt);
        Assert.Equal("127.0.0.1", engine.OpenedUrl!.Host);
        Assert.StartsWith("/stream/", engine.OpenedUrl.AbsolutePath, StringComparison.Ordinal);
        Assert.Equal(PlayerState.Playing, player.State);
        var sidecar = Assert.Single(engine.AddedSubtitles);
        Assert.EndsWith("/2", sidecar.AbsolutePath, StringComparison.Ordinal);
        Assert.StartsWith("/subtitles/", sidecar.AbsolutePath, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AStreamingQualityPlaysTheServersHlsStreamThroughTheRelayWhenTheServerOffersIt()
    {
        var player = Controller(new PlaybackPreferences(StreamingQuality: StreamingQuality.UpTo720p), ServerFeatures.AdaptiveStreaming);
        await player.StartAsync(Item(Movie), resume: true);
        await Settle();
        var engine = engines.Last;
        Assert.Equal("127.0.0.1", engine.OpenedUrl!.Host);
        Assert.Matches("^/stream/[0-9a-f]+/hls/master\\.m3u8$", engine.OpenedUrl.AbsolutePath);
        Assert.Equal([":network-caching=1500", ":adaptive-maxheight=720", ":adaptive-logic=highest"], engine.OpenedOptions);
        Assert.Equal(600_000, engine.OpenedAt);
        await player.CloseAsync();

        // A server without adaptive streaming plays the original, whatever the setting.
        var original = Controller(new PlaybackPreferences(StreamingQuality: StreamingQuality.Automatic));
        await original.StartAsync(Item(Movie), resume: true);
        await Settle();
        Assert.Matches("^/stream/[0-9a-f]+$", engines.Last.OpenedUrl!.AbsolutePath);
        Assert.Empty(engines.Last.OpenedOptions);
    }

    [Fact]
    public async Task StartsOverWhenAutomaticResumeIsOff()
    {
        var player = Controller(new PlaybackPreferences(AutomaticResume: false));
        await player.StartAsync(Item(Movie), resume: true);
        Assert.Equal(0, engines.Last.OpenedAt);
    }

    [Fact]
    public async Task UsesRememberedAndDefaultTracks()
    {
        new TrackMemory(settings, FakeLibrary.OwnerId).RememberAudio(new MediaTrack(9, "Track 2 - [German]", "German"), null);
        var player = Controller(new PlaybackPreferences(DefaultSubtitleLanguage: "de"));
        await player.StartAsync(Item(Movie), resume: false);
        Assert.Equal(2, engines.Last.AudioTrack);
        Assert.Equal(4, engines.Last.SubtitleTrack);
        Assert.Equal(4, player.SubtitleTrack);

        player.SelectSubtitle(null);
        Assert.Equal(-1, engines.Last.SubtitleTrack);
        Assert.True(new TrackMemory(settings, FakeLibrary.OwnerId).LastSubtitle?.Off);
    }

    [Fact]
    public async Task SavesProgressWithItsRevisionOnPauseAndEveryFifteenSeconds()
    {
        var player = Controller();
        await player.StartAsync(Item(Movie), resume: true);
        engines.Last.Advance(5_000);
        player.PlayPause();
        await Settle();
        Assert.Equal(PlayerState.Paused, player.State);
        var body = server.Bodies[$"PUT /api/v1/media/{Movie}/progress"];
        Assert.Contains("\"positionMilliseconds\":605000", body, StringComparison.Ordinal);
        Assert.Contains("\"expectedRevision\":3", body, StringComparison.Ordinal);
        Assert.Contains("\"enforceRevision\":true", body, StringComparison.Ordinal);
        Assert.Contains("\"isFinished\":false", body, StringComparison.Ordinal);

        player.PlayPause();
        var saves = server.Requests.Count(r => r == $"PUT /api/v1/media/{Movie}/progress");
        engines.Last.Advance(16_000);
        time.Advance(TimeSpan.FromSeconds(16));
        await Settle();
        Assert.True(server.Requests.Count(r => r == $"PUT /api/v1/media/{Movie}/progress") > saves);
        Assert.Contains("\"expectedRevision\":4", server.Bodies[$"PUT /api/v1/media/{Movie}/progress"], StringComparison.Ordinal);
    }

    [Fact]
    public async Task ASeriesPlaysTheNextEpisodeAtTheNaturalEnd()
    {
        var player = Controller();
        await player.StartAsync(FakeLibrary.Item(FakeLibrary.SeriesId, MediaKind.Series, "Cobalt Station", 2024, []), resume: false);
        Assert.Equal(FakeLibrary.EpisodeOne, player.Item?.Id);
        Assert.Equal(FakeLibrary.EpisodeTwo, player.NextItem?.Id);
        var first = engines.Last;
        first.Advance(3_600_000);
        Assert.Equal(FakeLibrary.EpisodeTwo, player.UpNext?.Id);
        first.End();
        await Settle();
        Assert.Contains("\"isFinished\":true", server.Bodies[$"PUT /api/v1/media/{FakeLibrary.EpisodeOne}/progress"], StringComparison.Ordinal);
        Assert.Equal(FakeLibrary.EpisodeTwo, player.Item?.Id);
        Assert.NotSame(first, engines.Last);
        Assert.True(first.Unloaded);
        Assert.True(player.HasPrevious);
        Assert.Equal(0, closed);
    }

    [Fact]
    public async Task UpNextShowsInTheCountdownAndCancelStopsAtTheEnd()
    {
        var player = Controller(new PlaybackPreferences(UpNextCountdownSeconds: 10));
        await player.StartAsync(FakeLibrary.Item(FakeLibrary.SeriesId, MediaKind.Series, "Cobalt Station", 2024, []), resume: false);
        engines.Last.Advance(3_585_000);
        Assert.Null(player.UpNext);
        engines.Last.Advance(8_000);
        Assert.NotNull(player.UpNext);
        Assert.Equal(7, player.UpNextSeconds);
        player.DismissUpNext();
        Assert.Null(player.UpNext);
        engines.Last.Advance(7_000);
        engines.Last.End();
        await Settle();
        Assert.Equal(1, closed);
        Assert.Equal(FakeLibrary.EpisodeOne, player.Item?.Id);
    }

    [Fact]
    public async Task TheSleepTimerEndsPlaybackAndTellsTheServer()
    {
        var player = Controller();
        await player.StartAsync(Item(Movie), resume: false);
        player.SetSleepTimer(new SleepTimer(15, false));
        // The title plays on while the clock runs, so the player sees steady playback.
        for (var second = 0; second < 15 * 60 && closed == 0; second++)
        {
            engines.Last.Advance(1_000);
            time.Advance(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
        }
        await Settle();
        Assert.Contains("POST /api/v1/playback/sleep-timer-ended", server.Requests);
        Assert.Equal(1, closed);
    }

    private static ScreenTimeStatus ScreenTime(ScreenTimeState state) => new(state, state == ScreenTimeState.Open ? ScreenTimeReason.None : ScreenTimeReason.Bedtime,
        40, null, null, DateTimeOffset.UtcNow.AddMinutes(3), DateTimeOffset.UtcNow.AddMinutes(33),
        state == ScreenTimeState.Open ? null : DateTimeOffset.UtcNow.AddHours(10), ScreenTimeLockScope.WholeProfile, ScreenTimeEnding.FinishTitle, false);

    private void AddScreenTimeTicket(Guid media, string ticket, ScreenTimeStatus status) =>
        server.Replace("POST", $"/api/v1/media/{media}/playback", JsonSerializer.Serialize(new PlaybackSourceResponse(Guid.NewGuid(), media,
            $"/api/v1/streams/{ticket}", "video/x-matroska", 1000, DateTimeOffset.UtcNow.AddHours(4),
            new PlaybackProgressResponse(media, 0, 3_600_000, false, null, null, 1), null, status), AureliaJson.Options));

    [Fact]
    public async Task ScreenTimeEndsWithTheGoodNightScreenInsteadOfTheNextEpisode()
    {
        AddScreenTimeTicket(FakeLibrary.EpisodeOne, "ticket-episode-1", ScreenTime(ScreenTimeState.Open));
        server.Replace("GET", "/api/v1/profile/screen-time", JsonSerializer.Serialize(new OwnScreenTimeResponse(ScreenTime(ScreenTimeState.Closed)), AureliaJson.Options));
        var player = Controller();
        await player.StartAsync(FakeLibrary.Item(FakeLibrary.SeriesId, MediaKind.Series, "Cobalt Station", 2024, []), resume: false);
        engines.Last.Advance(3_600_000);
        engines.Last.End();
        await Settle();
        Assert.True(player.ShowsGoodNight);
        Assert.True(player.GoodNightEndsProfile);
        Assert.Null(player.Error);
        Assert.Equal(FakeLibrary.EpisodeOne, player.Item?.Id);
        Assert.DoesNotContain($"POST /api/v1/media/{FakeLibrary.EpisodeTwo}/playback", server.Requests);
        Assert.Equal(0, closed);
    }

    [Fact]
    public async Task TheLastTitleOfTheDayHasNoUpNext()
    {
        AddScreenTimeTicket(FakeLibrary.EpisodeOne, "ticket-episode-1", ScreenTime(ScreenTimeState.LastTitle));
        var player = Controller();
        await player.StartAsync(FakeLibrary.Item(FakeLibrary.SeriesId, MediaKind.Series, "Cobalt Station", 2024, []), resume: false);
        engines.Last.Advance(3_595_000);
        time.Advance(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
        Assert.Null(player.UpNext);
        Assert.Equal("This is the last episode before bedtime.", player.LastTitleNote);
    }

    [Fact]
    public async Task AScreenTimeRefusalShowsTheGoodNightScreenNotAnError()
    {
        server.Replace("POST", $"/api/v1/media/{Movie}/playback",
            """{"code":"screen_time_bedtime","message":"It's bedtime. Aurelia opens again at 07:00."}""", HttpStatusCode.Forbidden);
        server.Replace("GET", "/api/v1/profile/screen-time", JsonSerializer.Serialize(new OwnScreenTimeResponse(ScreenTime(ScreenTimeState.Closed)), AureliaJson.Options));
        var player = Controller();
        await player.StartAsync(Item(Movie), resume: false);
        await Settle();
        Assert.True(player.ShowsGoodNight);
        Assert.Null(player.Error);
        Assert.NotEqual(PlayerState.Failed, player.State);
    }

    [Fact]
    public async Task EndOfEpisodeSleepsInsteadOfPlayingOn()
    {
        var player = Controller();
        await player.StartAsync(FakeLibrary.Item(FakeLibrary.SeriesId, MediaKind.Series, "Cobalt Station", 2024, []), resume: false);
        player.SetSleepTimer(SleepTimer.AtEndOfEpisode);
        engines.Last.Advance(3_600_000);
        Assert.Null(player.UpNext);
        engines.Last.End();
        await Settle();
        Assert.Contains("POST /api/v1/playback/sleep-timer-ended", server.Requests);
        Assert.Equal(1, closed);
        Assert.Equal(FakeLibrary.EpisodeOne, player.Item?.Id);
    }

    [Fact]
    public async Task RecoversWithANewTicketAtTheLastPosition()
    {
        var player = Controller();
        await player.StartAsync(Item(Movie), resume: false);
        engines.Last.Advance(42_000);
        var tickets = server.Requests.Count(r => r == $"POST /api/v1/media/{Movie}/playback");
        engines.Last.Fail();
        await Settle();
        Assert.Equal(PlayerState.Recovering, player.State);
        time.Advance(TimeSpan.FromSeconds(1.5));
        await Settle();
        Assert.Equal(tickets + 1, server.Requests.Count(r => r == $"POST /api/v1/media/{Movie}/playback"));
        Assert.Equal(42_000, engines.Last.OpenedAt);
        Assert.Equal(PlayerState.Playing, player.State);
    }

    [Fact]
    public async Task GivesUpAfterTheRecoveryBudgetAndOffersTryAgain()
    {
        var player = Controller();
        await player.StartAsync(Item(Movie), resume: false);
        for (var attempt = 0; attempt < 8 && player.State != PlayerState.Failed; attempt++)
        {
            engines.Last.Fail();
            await Settle();
            time.Advance(TimeSpan.FromSeconds(31), TimeSpan.FromSeconds(1));
            await Settle();
        }
        Assert.Equal(PlayerState.Failed, player.State);
        Assert.NotNull(player.Error);
        await player.RetryAsync();
        Assert.Equal(PlayerState.Playing, player.State);
    }

    [Fact]
    public async Task AudioChangesPreservePositionPauseRateAndTracks()
    {
        var player = Controller();
        await player.StartAsync(Item(Movie), resume: false);
        engines.Last.Advance(90_000);
        player.SelectAudio(engines.Last.AudioTracks[1]);
        player.SelectSubtitle(engines.Last.SubtitleTracks[1]);
        player.Rate = 1.25;
        player.PlayPause();
        var original = engines.Last;
        player.SetDialogueBoost(DialogueBoost.Strong);
        Assert.Same(original, engines.Last);
        Assert.Equal(DialogueBoost.Strong, original.DialogueBoost);
        await player.SetVolumeLevelingAsync(VolumeLeveling.Sleep);
        Assert.NotSame(original, engines.Last);
        Assert.Equal(90_000, engines.Last.OpenedAt);
        Assert.Equal(PlayerState.Paused, player.State);
        Assert.False(engines.Last.IsPlaying);
        Assert.Equal(1.25, engines.Last.Rate);
        Assert.Equal(2, engines.Last.AudioTrack);
        Assert.Equal(4, engines.Last.SubtitleTrack);
        var saved = PlaybackPreferences.Load(settings);
        Assert.Equal(VolumeLeveling.Sleep, saved.EffectiveLeveling);
        Assert.Equal(DialogueBoost.Strong, saved.DialogueBoost);
        Assert.Equal(DialogueBoost.Strong, engines.Last.DialogueBoost);
        var compressed = engines.Last;
        player.SetDialogueBoost(DialogueBoost.Standard);
        await Settle();
        Assert.NotSame(compressed, engines.Last);
        Assert.Equal(DialogueBoost.Standard, engines.Last.DialogueBoost);
        Assert.Equal(90_000, engines.Last.OpenedAt);
        Assert.Equal(PlayerState.Paused, player.State);
        Assert.Equal(1.25, engines.Last.Rate);
        Assert.Equal(2, engines.Last.AudioTrack);
        Assert.Equal(4, engines.Last.SubtitleTrack);
        player.PlayPause();
        Assert.Equal(PlayerState.Playing, player.State);
        Assert.True(engines.Last.IsPlaying);
    }

    [Fact]
    public async Task MissingDialogueSupportIsVisibleAndDoesNotSaveAnActivePreset()
    {
        var player = Controller();
        await player.StartAsync(Item(Movie), resume: false);
        engines.Last.SupportsDialogue = false;
        player.SetDialogueBoost(DialogueBoost.Standard);
        Assert.Contains("unavailable", player.Error, StringComparison.Ordinal);
        Assert.Equal(DialogueBoost.Off, PlaybackPreferences.Load(settings).DialogueBoost);
    }

    [Fact]
    public async Task NightModeReopensTheTitleAtTheSamePosition()
    {
        var player = Controller();
        await player.StartAsync(Item(Movie), resume: false);
        engines.Last.Advance(90_000);
        await player.SetNightModeAsync(true);
        Assert.True(engines.Last.NightMode);
        Assert.Equal(90_000, engines.Last.OpenedAt);
        Assert.True(PlaybackPreferences.Load(settings).NightMode);
    }

    [Fact]
    public async Task AConflictOffersToKeepThisComputersPosition()
    {
        server.Replace("PUT", $"/api/v1/media/{Movie}/progress", """{"code":"playback_progress_conflict","message":"Another device saved progress."}""", HttpStatusCode.Conflict);
        server.Replace("GET", $"/api/v1/media/{Movie}/progress", Progress(Movie, 9));
        var player = Controller();
        await player.StartAsync(Item(Movie), resume: false);
        engines.Last.Advance(10_000);
        player.PlayPause();
        await Settle();
        Assert.True(player.HasConflict);

        server.Replace("PUT", $"/api/v1/media/{Movie}/progress", Progress(Movie, 10));
        await player.KeepThisPositionAsync();
        Assert.False(player.HasConflict);
        Assert.Contains("\"expectedRevision\":9", server.Bodies[$"PUT /api/v1/media/{Movie}/progress"], StringComparison.Ordinal);
    }

    [Fact]
    public void SuggestionsFollowAMovieOrALastEpisodeWithoutACountdown()
    {
        Assert.False(PlayerPolicy.WantsSuggestions(2_000_000, 6_000_000, hasNext: false));
        Assert.True(PlayerPolicy.WantsSuggestions(3_000_000, 6_000_000, hasNext: false));
        Assert.False(PlayerPolicy.WantsSuggestions(5_000_000, 6_000_000, hasNext: true));
        Assert.False(PlayerPolicy.WantsSuggestions(400_000, 500_000, hasNext: false));
        Assert.True(PlayerPolicy.ShowsSuggestion(5_500_000, 6_000_000, false, true, false, 5_400_000));
        Assert.False(PlayerPolicy.ShowsSuggestion(5_300_000, 6_000_000, false, true, false, 5_400_000));
        Assert.True(PlayerPolicy.ShowsSuggestion(5_985_000, 6_000_000, false, true, false, null));
        Assert.False(PlayerPolicy.ShowsSuggestion(5_500_000, 6_000_000, true, true, false, 5_400_000));
        Assert.False(PlayerPolicy.ShowsSuggestion(5_500_000, 6_000_000, false, false, false, 5_400_000));
        Assert.False(PlayerPolicy.ShowsSuggestion(5_500_000, 6_000_000, false, true, true, 5_400_000));
        var item = new CatalogItemSummary(Guid.NewGuid(), MediaKind.Movie, "Toy Tale 2", null, 1999, null, [], null, null,
            MediaAvailability.Available, false, null, DateTimeOffset.UnixEpoch);
        Assert.Equal("Next in Toy Tale Collection · 1999",
            PlayerPolicy.SuggestionCaption(new MediaSuggestion(item, MediaSuggestionKind.NextPart, "Next in Toy Tale Collection")));
        Assert.False(new PlaybackPreferences().PlaySuggestionsAutomatically);
    }

    [Fact]
    public void ThePlayerRulesMatchTheMac()
    {
        Assert.True(PlayerPolicy.IsNaturalCompletion(3_598_000, 3_600_000, observedPlayback: true));
        Assert.False(PlayerPolicy.IsNaturalCompletion(3_500_000, 3_600_000, observedPlayback: true));
        Assert.False(PlayerPolicy.IsNaturalCompletion(3_600_000, 3_600_000, observedPlayback: false));
        Assert.False(PlayerPolicy.ShowsUpNext(3_590_000, 200_000, true, true, false, false), "Titles under five minutes get no card.");
        Assert.True(PlayerPolicy.ShowsUpNext(3_590_000, 3_600_000, true, true, false, false, 20));
        Assert.False(PlayerPolicy.ShowsUpNext(3_590_000, 3_600_000, true, true, true, false, 20), "End of episode sleep timer wins.");
        Assert.True(PlayerPolicy.ShowsUpNext(3_300_000, 3_600_000, true, true, false, false, 20, creditsStart: 3_300_000));
        Assert.False(PlayerPolicy.ShowsUpNext(3_300_000, 3_600_000, true, true, false, false, 20, creditsStart: 600_000), "Credits in the first half are not trusted.");
        Assert.Equal(15, PlayerPolicy.UpNextSeconds(3_305_000, 3_600_000, creditsAnchor: 3_300_000, countdownSeconds: 20));
        Assert.True(PlayerPolicy.ShowsSkipIntro(59_000, 60_000, 90_000));
        Assert.False(PlayerPolicy.ShowsSkipIntro(88_000, 60_000, 90_000));
        Assert.False(PlayerPolicy.SkipsIntroAutomatically(IntroSkipping.Automatic, alreadySkipped: false, movedIntoIntro: true, buttonShown: true));
        Assert.True(PlayerPolicy.NextFinishesCurrent(3_300_000, 3_600_000, upNextShown: false, creditsStart: 3_300_000));
        Assert.False(PlayerPolicy.NextFinishesCurrent(1_000_000, 3_600_000, upNextShown: false, creditsStart: 3_300_000));
        Assert.Null(PlayerPolicy.Intro(new MediaSegmentsDto(90_000, 60_000, null)));
        Assert.Equal("1:02:03", PlayerPolicy.TimeLabel(3_723_000));
        Assert.Equal("4:05", PlayerPolicy.TimeLabel(245_000));
    }

    [Fact]
    public void PlaybackPreferencesKeepToTheAllowedValues()
    {
        var odd = new PlaybackPreferences(UpNextCountdownSeconds: 7, DefaultRate: 3, SeekIntervalSeconds: 63, DefaultAudioLanguage: "xx", ControlsHideDelaySeconds: 4).Normalized();
        Assert.Equal(20, odd.UpNextCountdownSeconds);
        Assert.Equal(1, odd.DefaultRate);
        Assert.Equal(60, odd.SeekIntervalSeconds);
        Assert.Equal("original", odd.DefaultAudioLanguage);
        Assert.Equal(2, odd.ControlsHideDelaySeconds);
    }

    [Fact]
    public void TrackChoicesMatchLanguageCodesFromVlcAndSettings()
    {
        Assert.True(TrackMemory.Same("ger", "de"));
        Assert.True(TrackMemory.Same("English", "eng"));
        var tracks = new[] { new MediaTrack(1, "English", "eng"), new MediaTrack(2, "German forced", "ger", IsForced: true), new MediaTrack(3, "German", "ger") };
        Assert.Equal(3, TrackMemory.Pick(tracks, null, "de")?.Id);
        Assert.Null(TrackMemory.Pick(tracks, null, "original"));
        Assert.Null(TrackMemory.Pick(tracks, new TrackChoice(null, null, Off: true), "de"));
        Assert.Equal(1, TrackMemory.Pick(tracks, new TrackChoice("eng", "Other", false), "de")?.Id);
    }

    [Fact]
    public void SceneNotesShowOnceForSixSecondsAndNotAfterAJump()
    {
        var cues = new SceneNoteCues();
        var media = Guid.NewGuid();
        cues.Replace([new SceneNoteSummary(Guid.NewGuid(), media, 10_000, null, "First", 1), new SceneNoteSummary(Guid.NewGuid(), media, 60_000, null, "Later", 1)]);
        var now = DateTimeOffset.UtcNow;
        Assert.Empty(cues.Advance(9_000, now));
        Assert.Equal(["First"], cues.Advance(10_500, now).Select(n => n.Text));
        Assert.Equal(["First"], cues.Advance(12_000, now.AddSeconds(2)).Select(n => n.Text));
        Assert.Empty(cues.Advance(14_000, now.AddSeconds(7)));
        Assert.Empty(cues.Advance(70_000, now.AddSeconds(8)));
    }

    [Fact]
    public async Task BoxSetQueuePlaysInOrderAndSupportsNextAndPrevious()
    {
        controller = Controller();
        var first = FakeLibrary.Item(FakeLibrary.EpisodeOne, MediaKind.Episode, "Arrival", 2024, ["Science Fiction"], parent: FakeLibrary.SeriesId, season: 1, episode: 1);
        var second = FakeLibrary.Item(FakeLibrary.EpisodeTwo, MediaKind.Episode, "Signal", 2024, ["Science Fiction"], parent: FakeLibrary.SeriesId, season: 1, episode: 2);
        await controller.StartQueueAsync([first, second], first, resume: false);

        Assert.Equal(FakeLibrary.EpisodeOne, controller.Item?.Id);
        Assert.Equal(FakeLibrary.EpisodeTwo, controller.NextItem?.Id);

        await controller.NextAsync();
        Assert.Equal(FakeLibrary.EpisodeTwo, controller.Item?.Id);
        Assert.Null(controller.NextItem);

        await controller.PreviousAsync();
        Assert.Equal(FakeLibrary.EpisodeOne, controller.Item?.Id);
    }
}
