using Aurelia.Desktop.Core;
using Xunit;

namespace Aurelia.Desktop.Tests;

public sealed class PlayerModelTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "aurelia-desktop-player-" + Guid.NewGuid().ToString("N"));
    private readonly FakeLibraryApi api = new();
    private readonly FakeEngineFactory engines = new();
    private readonly List<FakeRelay> relays = [];
    private DateTimeOffset now = new(2026, 10, 19, 20, 0, 0, TimeSpan.Zero);

    public void Dispose()
    {
        if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
    }

    private PlaybackSettingsStore Settings => new(Path.Combine(directory, "playback.json"));

    private PlayerModel Create(PlaybackRequest request) =>
        new(api, engines, Settings, request, action => action(), () => now, (_, purpose) =>
        {
            var relay = new FakeRelay(purpose);
            relays.Add(relay);
            return relay;
        });

    private static PlaybackRequest EpisodeOne => new(FakeLibraryApi.Episode(1), [FakeLibraryApi.Episode(2)], FakeLibraryApi.SeriesId);

    private FakeVideoEngine Engine => engines.Created[^1];

    [Fact]
    public async Task OpensAtTheResumePositionAndShowsTheRingUntilThePictureMoves()
    {
        api.ResumePositions[FakeLibraryApi.EpisodeOneId] = 600_000;
        await using var player = Create(EpisodeOne);
        await player.StartAsync();
        Assert.Equal("Pilot", player.Title);
        Assert.Equal("Synthetic Series · S1 E1", player.Subtitle);
        Assert.Equal((new Uri("http://127.0.0.1:9/stream"), 600_000L), Engine.Opened.Single());
        Assert.Equal(["preview", null], relays.Select(relay => relay.Purpose).OrderBy(purpose => purpose is null));
        Assert.Equal(new Uri("http://127.0.0.1:9/preview"), player.PreviewSource);
        Assert.True(player.PreviewsParallel);
        Assert.True(player.IsStarting);

        Engine.Advance(600_040);
        Assert.True(player.IsStarting);
        Assert.Empty(Engine.Seeks);
        Engine.Advance(600_600);
        Assert.False(player.IsStarting);
        Assert.Equal(600_600, player.Position);
        Assert.Equal("10:00", player.PositionLabel);
        Assert.Equal("45:00", player.DurationLabel);
    }

    [Fact]
    public async Task AContainerThatIgnoresTheStartPositionStillResumes()
    {
        api.ResumePositions[FakeLibraryApi.EpisodeOneId] = 600_000;
        await using var player = Create(EpisodeOne);
        await player.StartAsync();
        Engine.Advance(400);
        Assert.Equal([600_000L], Engine.Seeks);
    }

    [Fact]
    public async Task ProgressIsSavedRegularlyOnPauseAndOnClose()
    {
        await using var player = Create(EpisodeOne);
        await player.StartAsync();
        Engine.Advance(1_000);
        Engine.Advance(5_000);
        Assert.Empty(api.Saves);
        now = now.AddSeconds(16);
        Engine.Advance(20_000);
        Assert.Equal((FakeLibraryApi.EpisodeOneId, 20_000L, 2_700_000L, false, 3L), api.Saves.Single());

        player.Pause();
        await Task.Yield();
        Assert.Equal(2, api.Saves.Count);
        Assert.Equal(4L, api.Saves[1].Revision);
        await player.CloseAsync();
        Assert.Equal(3, api.Saves.Count);
        Assert.Single(api.Revoked);
        Assert.All(relays, relay => Assert.True(relay.Disposed));
    }

    [Fact]
    public async Task NewerProgressFromAnotherDeviceIsKept()
    {
        api.FailSaveWithConflict = true;
        await using var player = Create(EpisodeOne);
        await player.StartAsync();
        Engine.Advance(1_000);
        Engine.Advance(9_000);
        player.Pause();
        await Task.Delay(20, TestContext.Current.CancellationToken);
        Assert.Equal("Progress changed on another device. Its newer position has been kept.", player.Message);
    }

    [Fact]
    public async Task UpNextCountsDownAndPlayNowContinuesWithTheNextEpisode()
    {
        await using var player = Create(EpisodeOne);
        await player.StartAsync();
        Engine.Advance(1_000);
        Engine.Advance(2_600_000);
        Assert.Null(player.UpNext);
        Engine.Advance(2_685_000);
        Assert.Equal(new UpNextCard("The Second One", "Synthetic Series · S1 E2", 15), player.UpNext);

        await player.PlayNextNowAsync();
        Assert.Contains(api.Saves, save => save.Media == FakeLibraryApi.EpisodeOneId && save.Finished);
        Assert.Equal("The Second One", player.Title);
        Assert.Equal(FakeLibraryApi.EpisodeTwoId, player.MediaId);
        Assert.Equal(2, api.TicketCount);
        Assert.Single(api.Revoked);
        Assert.True(player.IsStarting);
    }

    [Fact]
    public async Task TheNextEpisodeStartsAtTheEndUnlessUpNextWasCancelled()
    {
        await using (var player = Create(EpisodeOne))
        {
            await player.StartAsync();
            Engine.Advance(1_000);
            Engine.Advance(2_699_000);
            Engine.Raise(EngineEnd.Ended);
            await Task.Delay(20, TestContext.Current.CancellationToken);
            Assert.Equal(FakeLibraryApi.EpisodeTwoId, player.MediaId);
        }

        await using var cancelled = Create(EpisodeOne);
        var closed = false;
        cancelled.CloseRequested += () => closed = true;
        await cancelled.StartAsync();
        Engine.Advance(1_000);
        Engine.Advance(2_690_000);
        cancelled.DismissUpNext();
        Assert.Null(cancelled.UpNext);
        Engine.Advance(2_699_000);
        Engine.Raise(EngineEnd.Ended);
        await Task.Delay(20, TestContext.Current.CancellationToken);
        Assert.True(closed);
        Assert.Equal(FakeLibraryApi.EpisodeOneId, cancelled.MediaId);
    }

    [Fact]
    public async Task ABrokenStreamReconnectsOnceThenOffersTryAgain()
    {
        await using var player = Create(EpisodeOne);
        await player.StartAsync();
        Engine.Advance(1_000);
        Engine.Advance(90_000);
        relays.First(relay => relay.Purpose is null).Fail(503);
        await Task.Delay(20, TestContext.Current.CancellationToken);
        Assert.Equal(2, api.TicketCount);
        Assert.Equal(90_000, Engine.Opened[^1].Start);
        Assert.Null(player.Error);

        Engine.Raise(EngineEnd.Failed);
        await Task.Delay(20, TestContext.Current.CancellationToken);
        Assert.StartsWith("The stream was interrupted.", player.Error, StringComparison.Ordinal);
        await player.RetryAsync();
        Assert.Null(player.Error);
        Assert.Equal(3, api.TicketCount);
    }

    [Fact]
    public async Task TrackChoicesAreRememberedForTheSeries()
    {
        await using (var first = Create(EpisodeOne))
        {
            await first.StartAsync();
            Engine.AudioTracks = [new MediaTrack(1, "English - [English]"), new MediaTrack(2, "Deutsch - [German]")];
            Engine.SubtitleTracks = [new MediaTrack(5, "Deutsch - [German]")];
            Engine.Advance(1_000);
            first.SelectAudio(Engine.AudioTracks[1]);
            first.SelectSubtitle(null);
        }

        await using var second = Create(new PlaybackRequest(FakeLibraryApi.Episode(2), [], FakeLibraryApi.SeriesId));
        await second.StartAsync();
        Engine.AudioTracks = [new MediaTrack(7, "English - [English]"), new MediaTrack(8, "German 5.1 - [German]")];
        Engine.SubtitleTracks = [new MediaTrack(9, "Deutsch - [German]")];
        Engine.Advance(1_000);
        Assert.Equal(8, Engine.AudioTrack);
        Assert.Equal(-1, Engine.SubtitleTrack);
    }

    [Fact]
    public async Task NightModeReopensAtTheSamePositionWithANewDecoder()
    {
        await using var player = Create(EpisodeOne);
        await player.StartAsync();
        Engine.Advance(1_000);
        Engine.Advance(120_000);
        player.SetNightMode(true);
        Assert.Equal(2, engines.Created.Count);
        Assert.True(engines.Created[1].NightMode);
        Assert.True(engines.Created[0].Disposed);
        Assert.Equal(120_000, engines.Created[1].Opened.Single().Start);
        Assert.True(Settings.Load().NightMode);
    }

    [Fact]
    public async Task EndOfEpisodeSleepTimerStopsInsteadOfContinuing()
    {
        await using var player = Create(EpisodeOne);
        var closed = false;
        player.CloseRequested += () => closed = true;
        await player.StartAsync();
        player.SetSleepTimer(-1);
        Engine.Advance(1_000);
        Engine.Advance(2_690_000);
        Assert.Null(player.UpNext);
        Engine.Advance(2_699_500);
        Engine.Raise(EngineEnd.Ended);
        await Task.Delay(20, TestContext.Current.CancellationToken);
        Assert.True(closed);
    }

    [Fact]
    public void PlayerRulesMatchTheMacAndAppleTv()
    {
        Assert.Equal("1:02:03", PlayerPolicy.TimeLabel(3_723_000));
        Assert.Equal("Ends at 20:40",
            PlayerPolicy.EndTimeLabel(600_000, 3_000_000, 1, new DateTimeOffset(2026, 10, 19, 20, 0, 0, TimeZoneInfo.Local.GetUtcOffset(
                new DateTime(2026, 10, 19, 20, 0, 0))), System.Globalization.CultureInfo.GetCultureInfo("de-DE")));
        Assert.True(PlayerPolicy.IsNaturalCompletion(2_697_000, 2_700_000, true));
        Assert.False(PlayerPolicy.IsNaturalCompletion(2_697_000, 2_700_000, false));
        Assert.Equal(27, ScrubPreviewPlan.Order(265_000, 10_000).Count);
        Assert.Equal([0L, 80_000, 160_000, 240_000], ScrubPreviewPlan.Order(265_000, 10_000).Take(4));
        Assert.Equal(3_608_480, ScrubPreviewPlan.SnapshotPosition(3_610_000, 10_000, 3_611_480));
        Assert.Equal(1, ScrubPreviewPlan.Workers(parallel: false));
        Assert.InRange(ScrubPreviewPlan.Workers(parallel: true, cores: 64), 2, 6);
        Assert.Equal(new TrackChoice("German", "Deutsch - [German]"), TrackChoice.From("Deutsch - [German]"));
    }

    [Fact]
    public async Task SceneNotesMarkMomentsAndRangesAndJumpBack()
    {
        Assert.Equal(750_000, SceneNotesModel.ParseTime("12:30"));
        Assert.Equal(3_765_000, SceneNotesModel.ParseTime("1:02:45"));
        Assert.Null(SceneNotesModel.ParseTime("12:75"));
        Assert.Null(SceneNotesModel.ParseTime("soon"));
        var api = new FakeLibraryApi();
        long position = 754_000;
        var seeks = new List<long>();
        var notes = new SceneNotesModel(api, () => FakeLibraryApi.MovieId, () => position, seeks.Add);
        await notes.LoadAsync();
        Assert.False(notes.HasNotes);

        notes.Create();
        Assert.Equal("12:34", notes.Start);
        notes.Text = "The reveal";
        await notes.SaveAsync();
        Assert.Null(notes.Error);
        var moment = Assert.Single(notes.Notes);
        Assert.Equal("12:34", moment.TimeLabel);
        Assert.Equal("The reveal", moment.Text);

        position = 60_000;
        notes.Create();
        notes.IsRange = true;
        notes.End = "0:30";
        await notes.SaveAsync();
        Assert.Equal("The end must come after the start.", notes.Error);
        notes.End = "2:00";
        await notes.SaveAsync();
        Assert.Equal(["1:00 – 2:00", "12:34"], notes.Notes.Select(note => note.TimeLabel));
        Assert.Equal("Marked scene", notes.Notes[0].Text);

        notes.Edit(notes.Notes[1]);
        notes.Text = "The big reveal";
        await notes.SaveAsync();
        Assert.Equal("The big reveal", notes.Notes[1].Text);
        notes.Jump(notes.Notes[1]);
        Assert.Equal([754_000L], seeks);
        await notes.RemoveAsync(notes.Notes[0]);
        Assert.Single(notes.Notes);
    }
}
