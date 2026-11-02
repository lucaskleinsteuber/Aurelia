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

    private PlaybackController Controller(PlaybackPreferences? preferences = null)
    {
        (preferences ?? new PlaybackPreferences()).Save(settings);
        var stored = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
            "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));
        var profile = new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
            "profile-token-synthetic-0000000000000000001", DateTimeOffset.UtcNow.AddHours(12));
        var library = new LibraryClient(api, stored, profile, ["library-state-v1"]);
        controller = new PlaybackController(new PlaybackClient(api, library), engines, settings, new ProgressOutbox(null), time, action => action());
        controller.Closed += () => closed++;
        return controller;
    }

    private static CatalogItemSummary Item(Guid id, MediaKind kind = MediaKind.Movie) =>
        FakeLibrary.Item(id, kind, "Title", 2024, [], parent: kind == MediaKind.Episode ? FakeLibrary.SeriesId : null, season: kind == MediaKind.Episode ? 1 : null, episode: kind == MediaKind.Episode ? 1 : null);

    private void AddTicket(Guid media, string ticket, long position, long revision) =>
        server.Replace("POST", $"/api/v1/media/{media}/playback", JsonSerializer.Serialize(new PlaybackSourceResponse(Guid.NewGuid(), media,
            $"/api/v1/streams/{ticket}", "video/x-matroska", 1000, DateTimeOffset.UtcNow.AddHours(4),
            new PlaybackProgressResponse(media, position, 3_600_000, false, null, null, revision)), AureliaJson.Options));

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
    public void ThePlayerRulesMatchTheMac()
    {
        Assert.True(PlayerPolicy.IsNaturalCompletion(3_598_000, 3_600_000, observedPlayback: true));
        Assert.False(PlayerPolicy.IsNaturalCompletion(3_500_000, 3_600_000, observedPlayback: true));
        Assert.False(PlayerPolicy.IsNaturalCompletion(3_600_000, 3_600_000, observedPlayback: false));
        Assert.False(PlayerPolicy.ShowsUpNext(3_590_000, 200_000, true, true, false, false), "Titles under five minutes get no card.");
        Assert.True(PlayerPolicy.ShowsUpNext(3_590_000, 3_600_000, true, true, false, false, 20));
        Assert.False(PlayerPolicy.ShowsUpNext(3_590_000, 3_600_000, true, true, true, false, 20), "End of episode sleep timer wins.");
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
}
