using System.Data.Common;
using Microsoft.EntityFrameworkCore.Diagnostics;
using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class LibraryStateTests
{
    [Fact]
    public async Task PlansFollowLatestRealViewingSkipOlderGapsAndKeepSpecialsSeparate()
    {
        using var fixture = await Fixture.CreateAsync();
        var episodes = fixture.Episodes;
        var plan = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(episodes[0].Id, plan.Target!.Id);
        Assert.Equal(episodes.Skip(1).Select(item => item.Id), plan.Queue.Select(item => item.Id));
        await fixture.Progress(episodes[2], 45_000);
        await fixture.Progress(episodes[3], 65_000);
        plan = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(episodes[3].Id, plan.Target!.Id);
        Assert.Equal(PlaybackPlanAction.Resume, plan.Action);
        Assert.Equal(episodes.Skip(4).Select(item => item.Id), plan.Queue.Select(item => item.Id));
        Assert.Equal(episodes[3].Id, Assert.Single((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching).Id);
        await fixture.Progress(episodes[3], 300_000, true);
        plan = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(episodes[4].Id, plan.Target!.Id);
        Assert.True(plan.ContinueWatchingEligible);
        Assert.Equal(episodes[4].Id, Assert.Single((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching).Id);
        await fixture.Progress(episodes[4], 300_000, true);
        plan = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(PlaybackPlanAction.PlayAgain, plan.Action);
        Assert.Equal(episodes[0].Id, plan.Target!.Id);
        Assert.False(plan.ContinueWatchingEligible);
        Assert.Empty((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);
        var special = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Special.Id}/playback-plan");
        Assert.Equal(fixture.Special.Id, special.Target!.Id);
        Assert.Empty(special.Queue);
        var explicitOld = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{episodes[0].Id}/playback-plan");
        Assert.Equal(episodes[0].Id, explicitOld.Target!.Id);
        Assert.Equal(episodes.Skip(1).Select(item => item.Id), explicitOld.Queue.Select(item => item.Id));
        var lastStamp = (await fixture.Get<PlaybackProgressResponse>($"/api/v1/media/{episodes[4].Id}/progress")).LastPlayedAt;
        var lastState = await fixture.State(episodes[4].Id);
        await fixture.Put<WatchStateResponse>($"/api/v1/media/{episodes[4].Id}/watch-state", new SetWatchStateRequest(false, WatchStateScope.Title, null, lastState.StateToken, Guid.NewGuid()));
        var manuallyReset = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(episodes[4].Id, manuallyReset.Target!.Id);
        Assert.Equal(PlaybackPlanAction.Play, manuallyReset.Action);
        Assert.False(manuallyReset.ContinueWatchingEligible);
        var seriesState = await fixture.State(fixture.Series.Id, WatchStateScope.Series);
        await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/watch-state", new SetWatchStateRequest(false, WatchStateScope.Series, null, seriesState.StateToken, Guid.NewGuid()));
        var allReset = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(episodes[4].Id, allReset.Target!.Id);
        Assert.Equal(lastStamp, allReset.Target.Progress!.LastPlayedAt);
        Assert.False(allReset.ContinueWatchingEligible);
    }

    [Fact]
    public async Task ResumeTargetReturnsToTheEpisodeActuallyRevisitedInsteadOfTheLaterEpisode()
    {
        using var fixture = await Fixture.CreateAsync();
        var earlier = fixture.Episodes[2];
        var later = fixture.Episodes[3];
        await fixture.Progress(earlier, 42_000);
        await fixture.Progress(later, 39_000);
        var plan = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(later.Id, plan.Target!.Id);
        // Going back and watching the earlier episode makes it the new real viewing target.
        await fixture.Progress(earlier, 45_000);
        plan = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(earlier.Id, plan.Target!.Id);
        Assert.Equal(PlaybackPlanAction.Resume, plan.Action);
        Assert.Equal(45_000, plan.Target.Progress!.PositionMilliseconds);
        Assert.Equal(earlier.Id, Assert.Single((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching).Id);
        // A real end, in contrast to manual navigation, deliberately advances the series target.
        await fixture.Progress(earlier, 300_000, true);
        plan = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(later.Id, plan.Target!.Id);
    }

    [Fact]
    public async Task AtomicMarksPreserveDurationAndLastPlayUseDurableReceiptsAndRejectStaleOutbox()
    {
        using var fixture = await Fixture.CreateAsync();
        var before = await fixture.Progress(fixture.Episodes[0], 45_000);
        var state = await fixture.State(fixture.Series.Id, WatchStateScope.Series);
        var command = new SetWatchStateRequest(true, WatchStateScope.Series, null, state.StateToken, Guid.NewGuid());
        var changed = await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/watch-state", command);
        Assert.Equal(5, changed.AffectedCount);
        Assert.Equal(CatalogWatchState.Completed, changed.WatchState);
        var preserved = await fixture.Get<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[0].Id}/progress");
        Assert.Equal(before.LastPlayedAt, preserved.LastPlayedAt);
        Assert.Equal(before.DurationMilliseconds, preserved.DurationMilliseconds);
        Assert.Equal(0, preserved.PositionMilliseconds);
        Assert.Equal(before.Revision + 1, preserved.Revision);
        var unknown = await fixture.Get<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[1].Id}/progress");
        Assert.True(unknown.IsCompleted);
        Assert.Null(unknown.LastPlayedAt);
        Assert.Equal(0, unknown.DurationMilliseconds);
        Assert.False((await fixture.Get<PlaybackProgressResponse>($"/api/v1/media/{fixture.Special.Id}/progress")).IsCompleted);
        var replay = await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/watch-state", command);
        Assert.Equal(changed, replay);
        await using (var scope = fixture.Factory.Services.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.Single(await database.LibraryStateMutations.Where(value => value.ClientMutationId == command.ClientMutationId).ToListAsync());
            // A fresh request-scoped service models a retry after the original process/request is gone.
            Assert.Equal(changed, await scope.ServiceProvider.GetRequiredService<LibraryStateService>().SetAsync(fixture.Owner.User.Id, fixture.Series.Id, command, default));
        }
        await fixture.RestartAsync();
        Assert.Equal(changed, await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/watch-state", command));
        using var stale = await fixture.Send(HttpMethod.Put, $"/api/v1/media/{fixture.Episodes[0].Id}/progress",
            new UpdatePlaybackProgressRequest(55_000, 300_000, false, Guid.NewGuid(), true, before.Revision));
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        using var changedMutation = await fixture.Send(HttpMethod.Put, $"/api/v1/media/{fixture.Series.Id}/watch-state", command with { IsWatched = false });
        Assert.Equal(HttpStatusCode.Conflict, changedMutation.StatusCode);
        using var staleState = await fixture.Send(HttpMethod.Put, $"/api/v1/media/{fixture.Series.Id}/watch-state", command with { ClientMutationId = Guid.NewGuid(), IsWatched = false });
        Assert.Equal(HttpStatusCode.Conflict, staleState.StatusCode);
        var detail = await fixture.Get<CatalogDetailPresentation>($"/api/v1/catalog/items/{fixture.Series.Id}");
        Assert.Equal(CatalogWatchState.Completed, detail.Item.WatchState);
        Assert.All(detail.Seasons.Where(season => season.Number > 0).SelectMany(season => season.Episodes), episode => Assert.Equal(CatalogWatchState.Completed, episode.Item.WatchState));
        var resetState = await fixture.State(fixture.Series.Id, WatchStateScope.Series);
        await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/watch-state", new SetWatchStateRequest(false, WatchStateScope.Series, null, resetState.StateToken, Guid.NewGuid()));
        var resetPlan = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(fixture.Episodes[0].Id, resetPlan.Target!.Id);
        Assert.False(resetPlan.ContinueWatchingEligible);
        Assert.Equal(before.LastPlayedAt, (await fixture.Get<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[0].Id}/progress")).LastPlayedAt);
    }

    [Fact]
    public async Task ConcurrentCommandsApplyOnceAndNeverPartiallyOverwriteASeason()
    {
        using var fixture = await Fixture.CreateAsync();
        var state = await fixture.State(fixture.Series.Id, WatchStateScope.Season, 1);
        var commands = new[]
        {
            fixture.Send(HttpMethod.Put, $"/api/v1/media/{fixture.Series.Id}/watch-state", new SetWatchStateRequest(true, WatchStateScope.Season, 1, state.StateToken, Guid.NewGuid())),
            fixture.Send(HttpMethod.Put, $"/api/v1/media/{fixture.Series.Id}/watch-state", new SetWatchStateRequest(false, WatchStateScope.Season, 1, state.StateToken, Guid.NewGuid()))
        };
        var responses = await Task.WhenAll(commands);
        try
        {
            Assert.Single(responses, response => response.IsSuccessStatusCode);
            Assert.Single(responses, response => response.StatusCode == HttpStatusCode.Conflict);
            var final = await fixture.State(fixture.Series.Id, WatchStateScope.Season, 1);
            Assert.Equal(3, final.AffectedCount);
            Assert.NotEqual(CatalogWatchState.InProgress, final.WatchState);
        }
        finally { foreach (var response in responses) response.Dispose(); }
    }

    [Fact]
    public async Task HidingAnEpisodeHidesItsSeriesAndChecksTheEpisodeToken()
    {
        using var fixture = await Fixture.CreateAsync();
        await fixture.Progress(fixture.Episodes[2], 45_000);
        Assert.Single((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);
        var episodeState = await fixture.State(fixture.Episodes[2].Id);
        using (var stale = await fixture.Send(HttpMethod.Put, $"/api/v1/media/{fixture.Episodes[2].Id}/continue-watching",
            new SetContinueWatchingRequest(true, new string('0', 64), Guid.NewGuid())))
            Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        var hidden = await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Episodes[2].Id}/continue-watching",
            new SetContinueWatchingRequest(true, episodeState.StateToken, Guid.NewGuid()));
        Assert.Equal(fixture.Series.Id, hidden.MediaId);
        Assert.True(hidden.ContinueWatchingHidden);
        Assert.Empty((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);
    }

    /// The Mac and Apple TV send the scope in lower case, as the server writes it in its answers.
    [Fact]
    public async Task WatchStateAcceptsTheScopeInAnyCaseAndRejectsUnknownScopes()
    {
        using var fixture = await Fixture.CreateAsync();
        await fixture.Progress(fixture.Episodes[2], 45_000);
        foreach (var scope in new[] { "title", "Title", "SERIES" })
        {
            using var response = await fixture.Send(HttpMethod.Get, $"/api/v1/media/{fixture.Series.Id}/watch-state?scope={scope}");
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        }
        using (var season = await fixture.Send(HttpMethod.Get, $"/api/v1/media/{fixture.Series.Id}/watch-state?scope=season&seasonNumber=1"))
            Assert.Equal(HttpStatusCode.OK, season.StatusCode);
        foreach (var scope in new[] { "episode", "1" })
        {
            using var unknown = await fixture.Send(HttpMethod.Get, $"/api/v1/media/{fixture.Series.Id}/watch-state?scope={scope}");
            Assert.Equal(HttpStatusCode.BadRequest, unknown.StatusCode);
            Assert.Equal("invalid_watch_scope", (await ApiTestClient.ReadAsync<ApiProblem>(unknown)).Code);
        }

        // The whole Continue Watching removal as the clients perform it.
        var state = await fixture.Get<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/watch-state?scope=title");
        var hidden = await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/continue-watching",
            new SetContinueWatchingRequest(true, state.StateToken, Guid.NewGuid()));
        Assert.True(hidden.ContinueWatchingHidden);
        Assert.Empty((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);
    }

    [Fact]
    public async Task HidePreservesProgressGuardsOldWritesAndOnlyRealProgressUnhides()
    {
        using var fixture = await Fixture.CreateAsync();
        var before = await fixture.Progress(fixture.Episodes[2], 45_000);
        var specialBefore = await fixture.Get<PlaybackProgressResponse>($"/api/v1/media/{fixture.Special.Id}/progress");
        var queuedSpecial = new UpdatePlaybackProgressRequest(60_000, 300_000, false, Guid.NewGuid(), true, specialBefore.Revision);
        var state = await fixture.State(fixture.Series.Id);
        var hidden = await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/continue-watching", new SetContinueWatchingRequest(true, state.StateToken, Guid.NewGuid()));
        Assert.True(hidden.ContinueWatchingHidden);
        Assert.Empty((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);
        var savedSpecial = await fixture.Put<PlaybackProgressResponse>($"/api/v1/media/{fixture.Special.Id}/progress", queuedSpecial);
        Assert.Equal(60_000, savedSpecial.PositionMilliseconds);
        Assert.True((await fixture.State(fixture.Series.Id)).ContinueWatchingHidden);
        Assert.Empty((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);
        var after = await fixture.Get<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[2].Id}/progress");
        Assert.Equal(before.PositionMilliseconds, after.PositionMilliseconds);
        Assert.Equal(before.LastPlayedAt, after.LastPlayedAt);
        using var stale = await fixture.Send(HttpMethod.Put, $"/api/v1/media/{fixture.Episodes[2].Id}/progress", new UpdatePlaybackProgressRequest(55_000, 300_000, false, Guid.NewGuid(), true, before.Revision));
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        var same = await fixture.Put<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[2].Id}/progress", new UpdatePlaybackProgressRequest(45_000, 300_000, false, Guid.NewGuid(), true, after.Revision));
        Assert.True((await fixture.State(fixture.Series.Id)).ContinueWatchingHidden);
        Assert.Equal(after.LastPlayedAt, same.LastPlayedAt);
        var openedWithoutMovement = await fixture.Put<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[2].Id}/progress", new UpdatePlaybackProgressRequest(0, 300_000, false, Guid.NewGuid(), true, same.Revision));
        Assert.Equal(0, openedWithoutMovement.PositionMilliseconds);
        Assert.Equal(before.LastPlayedAt, openedWithoutMovement.LastPlayedAt);
        Assert.True((await fixture.State(fixture.Series.Id)).ContinueWatchingHidden);
        Assert.Empty((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);
        await fixture.Put<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[2].Id}/progress", new UpdatePlaybackProgressRequest(60_000, 300_000, false, Guid.NewGuid(), true, openedWithoutMovement.Revision));
        Assert.False((await fixture.State(fixture.Series.Id)).ContinueWatchingHidden);
        Assert.Single((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);

        var episodeState = await fixture.State(fixture.Episodes[2].Id);
        await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Episodes[2].Id}/watch-state", new SetWatchStateRequest(true, WatchStateScope.Title, null, episodeState.StateToken, Guid.NewGuid()));
        var seriesState = await fixture.State(fixture.Series.Id);
        await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/continue-watching", new SetContinueWatchingRequest(true, seriesState.StateToken, Guid.NewGuid()));
        var completedBeforeOpen = await fixture.Get<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[2].Id}/progress");
        Assert.True(completedBeforeOpen.IsCompleted);
        var replayWithoutMovement = await fixture.Put<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[2].Id}/progress", new UpdatePlaybackProgressRequest(0, 300_000, false, Guid.NewGuid(), true, completedBeforeOpen.Revision));
        Assert.False(replayWithoutMovement.IsCompleted);
        Assert.Equal(completedBeforeOpen.LastPlayedAt, replayWithoutMovement.LastPlayedAt);
        Assert.True((await fixture.State(fixture.Series.Id)).ContinueWatchingHidden);
        Assert.Empty((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);
        await fixture.Put<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[2].Id}/progress", new UpdatePlaybackProgressRequest(70_000, 300_000, false, Guid.NewGuid(), true, replayWithoutMovement.Revision));
        Assert.False((await fixture.State(fixture.Series.Id)).ContinueWatchingHidden);
        Assert.Equal(fixture.Episodes[2].Id, Assert.Single((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching).Id);
        var changes = await fixture.Get<SyncChangesResponse>("/api/v1/sync/changes?after=0&waitSeconds=0");
        Assert.Contains(fixture.Series.Id, changes.ChangedMediaIds);
    }

    [Fact]
    public async Task CompletedZeroPositionDoesNotMatchUnplayedAndSearchHonorsExplicitSort()
    {
        using var fixture = await Fixture.CreateAsync();
        var state = await fixture.State(fixture.Movie.Id);
        await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Movie.Id}/watch-state", new SetWatchStateRequest(true, WatchStateScope.Title, null, state.StateToken, Guid.NewGuid()));
        var completed = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/items?watchState=completed");
        Assert.Equal(fixture.Movie.Id, Assert.Single(completed.Items).Id);
        var unplayed = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/items?watchState=unplayed");
        Assert.DoesNotContain(unplayed.Items, item => item.Id == fixture.Movie.Id);
        var series = await fixture.State(fixture.Series.Id, WatchStateScope.Series);
        await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/watch-state", new SetWatchStateRequest(true, WatchStateScope.Series, null, series.StateToken, Guid.NewGuid()));
        Assert.Equal(2, (await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/items?watchState=completed")).Total);
        var search = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/search?query=Synthetic&sort=releaseYear&direction=descending&kind=movie");
        Assert.Equal(fixture.Movie.Id, Assert.Single(search.Items).Id);
        var asc = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/search?query=Synthetic&sort=title&direction=ascending");
        var desc = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/search?query=Synthetic&sort=title&direction=descending");
        Assert.Equal(asc.Items.Select(item => item.Id).Reverse(), desc.Items.Select(item => item.Id));
        var capability = await fixture.Get<ServerInfoResponse>("/api/v1/server/info");
        Assert.Contains("library-state-v1", capability.Capabilities!);
    }

    [Fact]
    public async Task EpisodeSearchCombinesParentGenreYearFavoriteAndExplicitOrdering()
    {
        using var fixture = await Fixture.CreateAsync();
        await using (var scope = fixture.Factory.Services.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            database.MediaMetadata.Add(new MediaMetadata { MediaItemId = fixture.Series.Id, ProviderGenresJson = "[\"Drama\"]" });
            database.UserFavorites.Add(new UserFavorite { Id = Guid.NewGuid(), UserId = fixture.Owner.User.Id, MediaItemId = fixture.Series.Id, CreatedAt = DateTimeOffset.UtcNow });
            await database.SaveChangesAsync();
        }
        var combined = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/search?query=Season%202&favorite=true&genre=Drama&yearFrom=2024&yearTo=2024&sort=lastPlayed&direction=descending");
        // FTS combines word prefixes: "2" also matches episode 2 in season 1.
        Assert.Equal(3, combined.Total);
        Assert.Equal(fixture.Episodes.Where(item => item.SeasonNumber == 2 || item.EpisodeNumber == 2).Select(item => item.Id).Order(), combined.Items.Select(item => item.Id).Order());
        var unfiltered = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/search?query=Season%202");
        Assert.Equal(unfiltered.Items.Select(item => item.Id).Order(), combined.Items.Select(item => item.Id).Order());
        await fixture.Progress(fixture.Episodes[4], 45_000);
        var ordered = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/items?sort=lastPlayed&direction=descending");
        Assert.Equal(fixture.Series.Id, ordered.Items[0].Id);
        var page1 = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/search?query=Synthetic&sort=title&direction=ascending&limit=2");
        var page2 = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/search?query=Synthetic&sort=title&direction=ascending&limit=2&offset=2");
        Assert.Empty(page1.Items.Select(item => item.Id).Intersect(page2.Items.Select(item => item.Id)));
        var specialState = await fixture.State(fixture.Series.Id, WatchStateScope.Season, 0);
        var special = await fixture.Put<WatchStateResponse>($"/api/v1/media/{fixture.Series.Id}/watch-state", new SetWatchStateRequest(true, WatchStateScope.Season, 0, specialState.StateToken, Guid.NewGuid()));
        Assert.Equal(1, special.AffectedCount);
        Assert.Equal(CatalogWatchState.InProgress, (await fixture.State(fixture.Series.Id)).WatchState);
    }

    [Fact]
    public async Task SeriesSelectionAndQueueShareASnapshotWhileTheCatalogChanges()
    {
        var interceptor = new PlanSnapshotInterceptor();
        using var fixture = await Fixture.CreateAsync(interceptor);
        var addedId = Guid.NewGuid();
        interceptor.Mutate = async token =>
        {
            await using var scope = fixture.Factory.Services.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            database.MediaItems.Add(new MediaItem { Id = addedId, LibraryRootId = fixture.Series.LibraryRootId, ParentId = fixture.Series.Id, Kind = MediaKind.Episode, SeasonNumber = 3, EpisodeNumber = 1, DetectedTitle = "Added concurrently", SourcePath = "synthetic/concurrent", NormalizedSourcePath = "SYNTHETIC/CONCURRENT" });
            foreach (var episode in fixture.Episodes)
                database.PlaybackProgress.Add(new PlaybackProgress { Id = Guid.NewGuid(), UserId = fixture.Owner.User.Id, User = null!, MediaItemId = episode.Id, MediaItem = null!, IsCompleted = true });
            await database.SaveChangesAsync(token);
        };
        var original = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.True(interceptor.SnapshotObserved);
        Assert.Equal(fixture.Episodes[0].Id, original.Target!.Id);
        Assert.Equal(fixture.Episodes.Skip(1).Select(item => item.Id), original.Queue.Select(item => item.Id));
        var changed = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
        Assert.Equal(addedId, changed.Target!.Id);
        Assert.Empty(changed.Queue);
    }

    private sealed class PlanSnapshotInterceptor : DbCommandInterceptor
    {
        public Func<CancellationToken, Task>? Mutate { get; set; }
        public bool SnapshotObserved { get; private set; }
        public override async ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(DbCommand command,
            CommandEventData eventData, InterceptionResult<DbDataReader> result, CancellationToken cancellationToken = default)
        {
            if (command.CommandText.Contains("WITH eligible AS", StringComparison.Ordinal) && Mutate is { } mutate)
            {
                Mutate = null;
                SnapshotObserved = command.Transaction is not null;
                await mutate(cancellationToken);
            }
            return result;
        }
    }

    [Fact]
    public async Task CompactContinueWatchingKeepsAnOfflineSeriesAndItsExactTarget()
    {
        using var fixture = await Fixture.CreateAsync();
        await fixture.Progress(fixture.Episodes[3], 45_000);
        await using var scope = fixture.Factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        await database.MediaItems.Where(item => item.Id == fixture.Series.Id || item.Id == fixture.Episodes[3].Id)
            .ExecuteUpdateAsync(set => set.SetProperty(item => item.Availability, MediaAvailability.Missing));
        File.Delete(fixture.Episodes[3].SourcePath); // Isolated synthetic fixture, no personal media.
        var card = Assert.Single((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);
        Assert.Equal(fixture.Episodes[3].Id, card.Id);
        Assert.Equal(MediaAvailability.Missing, card.Availability);
    }

    [Fact]
    public async Task CatalogLocationMemoEndsAtEachRequestAndEveryFileIsStillChecked()
    {
        using var fixture = await Fixture.CreateAsync();
        await fixture.Progress(fixture.Episodes[3], 45_000);
        var first = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/items?limit=500");
        Assert.All(first.Items, item => Assert.Equal(LibraryAvailability.Available, item.LibraryAvailability));
        File.Delete(fixture.Movie.SourcePath); // Invented fixture only.
        var missing = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/items?limit=500");
        Assert.Equal(MediaAvailability.Missing, Assert.Single(missing.Items, item => item.Id == fixture.Movie.Id).Availability);
        Assert.Equal(LibraryAvailability.Available, Assert.Single(missing.Items, item => item.Id == fixture.Series.Id).LibraryAvailability);
        var detached = fixture.MediaRoot + "-detached";
        Directory.Move(fixture.MediaRoot, detached); // Invented fixture only, restored immediately below.
        try
        {
            var offline = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/items?limit=500");
            Assert.Equal(first.Items.Select(item => item.Id), offline.Items.Select(item => item.Id));
            Assert.All(offline.Items, item => Assert.Equal(LibraryAvailability.Unavailable, item.LibraryAvailability));
        }
        finally { Directory.Move(detached, fixture.MediaRoot); }
        var restored = await fixture.Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/items?limit=500");
        Assert.All(restored.Items, item => Assert.Equal(LibraryAvailability.Available, item.LibraryAvailability));
        Assert.Equal(45_000, (await fixture.Get<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[3].Id}/progress")).PositionMilliseconds);
    }

    [Fact]
    public async Task ReachabilityWorksWithoutScansAndTitleChecksAreBoundedToRequestedFiles()
    {
        using var fixture = await Fixture.CreateAsync();
        await fixture.Progress(fixture.Episodes[3], 45_000);
        await using var scope = fixture.Factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var root = await database.LibraryRoots.SingleAsync();
        root.MonitoringEnabled = false;
        await database.SaveChangesAsync();
        var probe = scope.ServiceProvider.GetRequiredService<LibraryReachabilityService>();
        await probe.RefreshAsync(default);
        Assert.Equal(LibraryAvailability.Available, root.Availability);
        var detached = fixture.MediaRoot + "-detached";
        Directory.Move(fixture.MediaRoot, detached);
        try
        {
            await probe.RefreshAsync(default);
            Assert.Equal(LibraryAvailability.Unavailable, root.Availability);
            var plan = await fixture.Get<PlaybackPlanResponse>($"/api/v1/media/{fixture.Series.Id}/playback-plan");
            Assert.Equal(fixture.Episodes[3].Id, plan.Target!.Id);
            Assert.Equal(LibraryAvailability.Unavailable, plan.Target.LibraryAvailability);
            Assert.Single((await fixture.Get<HomeResponse>("/api/v1/home")).ContinueWatching);
        }
        finally { Directory.Move(detached, fixture.MediaRoot); }
        await probe.RefreshAsync(default);
        Assert.Equal(LibraryAvailability.Available, root.Availability);
        File.Delete(fixture.Episodes[3].SourcePath);
        var missing = await fixture.Get<CatalogItemSummary>($"/api/v1/catalog/items/{fixture.Episodes[3].Id}/summary");
        Assert.Equal(MediaAvailability.Missing, missing.Availability);
        Assert.Equal(LibraryAvailability.Available, missing.LibraryAvailability);
        Assert.Empty(await database.LibraryScans.ToListAsync());
        Assert.Equal(45_000, (await fixture.Get<PlaybackProgressResponse>($"/api/v1/media/{fixture.Episodes[3].Id}/progress")).PositionMilliseconds);
        Assert.DoesNotContain(fixture.MediaRoot, System.Text.Json.JsonSerializer.Serialize(missing), StringComparison.Ordinal);
    }

    [Fact]
    public async Task ViewingProfileCanMarkOnlyItsGrantedTitlesAndAccessChangesInvalidateCommands()
    {
        using var fixture = await Fixture.CreateAsync();
        var viewerId = Guid.NewGuid();
        await using (var seedScope = fixture.Factory.Services.CreateAsyncScope())
        {
            var database = seedScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var viewer = new ServerUser
            {
                Id = viewerId,
                Username = "synthetic viewer",
                NormalizedUsername = "SYNTHETIC VIEWER",
                Role = UserRole.User,
                PasswordHash = "synthetic",
                AccessMode = ProfileAccessMode.SelectedTitles,
                CreatedAt = DateTimeOffset.UtcNow
            };
            database.Users.Add(viewer);
            database.UserTitleGrants.Add(new UserTitleGrant { User = viewer, UserId = viewerId, MediaItemId = fixture.Series.Id, MediaItem = null! });
            await database.SaveChangesAsync();
        }
        await using var scope = fixture.Factory.Services.CreateAsyncScope();
        var scoped = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        scoped.AccessUserId = viewerId; scoped.AccessMode = ProfileAccessMode.SelectedTitles;
        var service = scope.ServiceProvider.GetRequiredService<LibraryStateService>();
        var before = await service.GetAsync(viewerId, fixture.Series.Id, WatchStateScope.Series, null, default);
        var command = new SetWatchStateRequest(true, WatchStateScope.Series, null, before.StateToken, Guid.NewGuid());
        Assert.Equal(CatalogWatchState.Completed, (await service.SetAsync(viewerId, fixture.Series.Id, command, default)).WatchState);
        Assert.Equal(CatalogWatchState.Unplayed, (await fixture.State(fixture.Series.Id)).WatchState);
        var denied = await Assert.ThrowsAsync<AccountException>(() => service.GetAsync(viewerId, fixture.Movie.Id, WatchStateScope.Title, null, default));
        Assert.Equal(404, denied.StatusCode);
        var presentation = scope.ServiceProvider.GetRequiredService<PresentationService>();
        var catalog = await presentation.CatalogAsync(viewerId, new CatalogQuery(WatchState: CatalogWatchState.Completed), default);
        Assert.Equal(fixture.Series.Id, Assert.Single(catalog.Items).Id);
        await using (var editScope = fixture.Factory.Services.CreateAsyncScope())
        {
            var database = editScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var user = await database.Users.SingleAsync(value => value.Id == viewerId);
            user.AccessRevision++;
            await database.SaveChangesAsync();
        }
        scoped.ChangeTracker.Clear();
        var replay = await Assert.ThrowsAsync<AccountException>(() => service.SetAsync(viewerId, fixture.Series.Id, command, default));
        Assert.Equal(409, replay.StatusCode);
    }

    [Fact]
    public async Task HistoryOfARestrictedProfileCountsOnlyTitlesItMaySeeAndClearsAll()
    {
        using var fixture = await Fixture.CreateAsync();
        var viewerId = Guid.NewGuid();
        await using (var seedScope = fixture.Factory.Services.CreateAsyncScope())
        {
            var database = seedScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var viewer = new ServerUser
            {
                Id = viewerId,
                Username = "synthetic viewer",
                NormalizedUsername = "SYNTHETIC VIEWER",
                Role = UserRole.User,
                PasswordHash = "synthetic",
                AccessMode = ProfileAccessMode.SelectedTitles,
                CreatedAt = DateTimeOffset.UtcNow
            };
            database.Users.Add(viewer);
            database.UserTitleGrants.Add(new UserTitleGrant { User = viewer, UserId = viewerId, MediaItemId = fixture.Movie.Id, MediaItem = null! });
            foreach (var mediaId in new[] { fixture.Movie.Id, fixture.Episodes[0].Id })
            {
                database.WatchEvents.Add(new WatchEvent
                {
                    Id = Guid.NewGuid(),
                    UserId = viewerId,
                    MediaItemId = mediaId,
                    Timestamp = DateTimeOffset.UtcNow,
                    PositionMilliseconds = 30_000,
                    DurationMilliseconds = 60_000,
                    SecondsWatched = 30,
                });
            }
            await database.SaveChangesAsync();
        }
        await using var scope = fixture.Factory.Services.CreateAsyncScope();
        var scoped = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        scoped.AccessUserId = viewerId; scoped.AccessMode = ProfileAccessMode.SelectedTitles;
        var history = scope.ServiceProvider.GetRequiredService<WatchHistoryService>();
        var page = await history.GetHistoryAsync(viewerId, 0, 50, default);
        Assert.Equal(fixture.Movie.Id, Assert.Single(page.Items).MediaId);
        Assert.Equal(1, page.Total);

        await history.ClearHistoryAsync(viewerId, default);
        await using var verify = fixture.Factory.Services.CreateAsyncScope();
        Assert.False(await verify.ServiceProvider.GetRequiredService<AureliaDbContext>().WatchEvents
            .AnyAsync(watch => watch.UserId == viewerId));
    }

    [Fact]
    public async Task HiddenChildInAnotherRootCannotAffectSeriesWatchFiltersOrLastPlayedOrder()
    {
        using var fixture = await Fixture.CreateAsync();
        var viewerId = Guid.NewGuid();
        await using (var seedScope = fixture.Factory.Services.CreateAsyncScope())
        {
            var database = seedScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var viewer = new ServerUser
            {
                Id = viewerId,
                Username = "root-scoped",
                NormalizedUsername = "ROOT-SCOPED",
                PasswordHash = "synthetic",
                Role = UserRole.User,
                AccessMode = ProfileAccessMode.LegacyLibraries,
                CreatedAt = DateTimeOffset.UtcNow
            };
            var privatePath = Path.Combine(fixture.Factory.DataDirectory, "Private Media");
            Directory.CreateDirectory(privatePath);
            var root = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Private synthetic",
                Path = privatePath,
                NormalizedPath = MediaPath.Normalize(privatePath),
                Kind = LibraryKind.TvShows,
                MonitoringEnabled = false,
                CreatedAt = DateTimeOffset.UtcNow
            };
            var hidden = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRoot = root,
                LibraryRootId = root.Id,
                ParentId = fixture.Series.Id,
                Kind = MediaKind.Episode,
                SeasonNumber = 3,
                EpisodeNumber = 1,
                DetectedTitle = "Private historical child",
                SourcePath = Path.Combine(privatePath, "Synthetic.mkv"),
                NormalizedSourcePath = MediaPath.Normalize(Path.Combine(privatePath, "Synthetic.mkv")),
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow
            };
            database.Users.Add(viewer);
            database.UserLibraryGrants.Add(new UserLibraryGrant { UserId = viewerId, User = viewer, LibraryRootId = fixture.Series.LibraryRootId, LibraryRoot = null! });
            database.MediaItems.Add(hidden);
            database.PlaybackProgress.Add(new PlaybackProgress
            {
                Id = Guid.NewGuid(),
                User = viewer,
                UserId = viewerId,
                MediaItem = hidden,
                MediaItemId = hidden.Id,
                PositionMilliseconds = 45_000,
                DurationMilliseconds = 300_000,
                LastPlayedAt = DateTimeOffset.UtcNow.AddDays(1),
                UpdatedAt = DateTimeOffset.UtcNow
            });
            database.PlaybackProgress.Add(new PlaybackProgress
            {
                Id = Guid.NewGuid(),
                User = viewer,
                UserId = viewerId,
                MediaItem = null!,
                MediaItemId = fixture.Movie.Id,
                PositionMilliseconds = 45_000,
                DurationMilliseconds = 300_000,
                LastPlayedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow
            });
            await database.SaveChangesAsync();
        }
        await using var scope = fixture.Factory.Services.CreateAsyncScope();
        var databaseScoped = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        databaseScoped.AccessUserId = viewerId; databaseScoped.AccessMode = ProfileAccessMode.LegacyLibraries;
        var states = scope.ServiceProvider.GetRequiredService<LibraryStateService>();
        var state = await states.GetAsync(viewerId, fixture.Series.Id, WatchStateScope.Series, null, default);
        Assert.Equal(5, state.AffectedCount);
        var marked = await states.SetAsync(viewerId, fixture.Series.Id, new SetWatchStateRequest(true, WatchStateScope.Series, null, state.StateToken, Guid.NewGuid()), default);
        Assert.Equal(CatalogWatchState.Completed, marked.WatchState);
        var presentation = scope.ServiceProvider.GetRequiredService<PresentationService>();
        var completed = await presentation.CatalogAsync(viewerId, new CatalogQuery(WatchState: CatalogWatchState.Completed), default);
        Assert.Equal(fixture.Series.Id, Assert.Single(completed.Items).Id);
        Assert.Equal(CatalogWatchState.Completed, completed.Items[0].WatchState);
        var playing = await presentation.CatalogAsync(viewerId, new CatalogQuery(WatchState: CatalogWatchState.InProgress), default);
        Assert.Equal(fixture.Movie.Id, Assert.Single(playing.Items).Id);
        var ordered = await presentation.CatalogAsync(viewerId, new CatalogQuery(Sort: CatalogSort.LastPlayed, Direction: SortDirection.Descending), default);
        Assert.Equal(fixture.Movie.Id, ordered.Items[0].Id);
        Assert.Equal(fixture.Series.Id, ordered.Items[1].Id);
    }

    [Fact]
    public async Task LastPlayedMigrationPreservesExistingValuesAndAllowsManualUnknownDurationStates()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={Path.Combine(root, "aurelia.db")};Pooling=False").Options;
        var userId = Guid.NewGuid(); var libraryId = Guid.NewGuid(); var mediaId = Guid.NewGuid(); var progressId = Guid.NewGuid();
        const long stamp = 1_750_000_000_000;
        try
        {
            await using var database = new AureliaDbContext(options);
            await database.Database.GetService<IMigrator>().MigrateAsync("20261013155809_OptionalProfilePins");
            await database.Database.ExecuteSqlInterpolatedAsync($"""
                INSERT INTO Users (Id, Username, NormalizedUsername, PasswordHash, Role, CreatedAt, IsEnabled, AccessMode, AccessRevision, ProfileRevision, PinProtectionEnabled)
                VALUES ({userId}, 'Synthetic', 'SYNTHETIC', 'unchanged', 'User', {stamp}, 1, 'EntireLibrary', 7, 3, 0);
                INSERT INTO LibraryRoots (Id, Name, Path, NormalizedPath, Kind, Availability, CreatedAt, MonitoringEnabled, ImportPreviewRequired, ImportAssignmentRevision)
                VALUES ({libraryId}, 'Synthetic', {root}, {root}, 'Movies', 'Unavailable', {stamp}, 0, 0, 0);
                INSERT INTO MediaItems (Id, LibraryRootId, Kind, SourcePath, NormalizedSourcePath, DetectedTitle, Availability, CreatedAt, UpdatedAt, Category, ManualSourceBinding)
                VALUES ({mediaId}, {libraryId}, 'Movie', 'synthetic', 'synthetic', 'Synthetic', 'Missing', {stamp}, {stamp}, '', 0);
                INSERT INTO PlaybackProgress (Id, MediaItemId, UserId, PositionMilliseconds, DurationMilliseconds, IsCompleted, LastPlayedAt, UpdatedAt, Revision)
                VALUES ({progressId}, {mediaId}, {userId}, 45000, 300000, 0, {stamp}, {stamp}, 9);
                """);
            await database.Database.MigrateAsync();
            var progress = await database.PlaybackProgress.SingleAsync();
            Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(stamp), progress.LastPlayedAt);
            Assert.Equal(45_000, progress.PositionMilliseconds); Assert.Equal(300_000, progress.DurationMilliseconds); Assert.Equal(9, progress.Revision);
            progress.LastPlayedAt = null; progress.PositionMilliseconds = 0; progress.DurationMilliseconds = 0; progress.IsCompleted = true;
            await database.SaveChangesAsync(); database.ChangeTracker.Clear();
            var manual = await database.PlaybackProgress.SingleAsync();
            Assert.Null(manual.LastPlayedAt); Assert.True(manual.IsCompleted); Assert.Equal(0, manual.DurationMilliseconds);
        }
        finally { SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
    }

    private sealed class Fixture : IDisposable
    {
        public required AureliaServerFactory Factory { get; set; }
        public required HttpClient Client { get; set; }
        public required AuthenticationResponse Owner { get; set; }
        public required string MediaRoot { get; init; }
        public required MediaItem Movie { get; init; }
        public required MediaItem Series { get; init; }
        public required List<MediaItem> Episodes { get; init; }
        public required MediaItem Special { get; init; }

        public static async Task<Fixture> CreateAsync(DbCommandInterceptor? interceptor = null)
        {
            var factory = new AureliaServerFactory(TestPaths.CreateDataDirectory(), configureServices: services =>
            {
                if (interceptor is not null) services.AddDbContext<AureliaDbContext>(options => options.AddInterceptors(interceptor));
            });
            var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var root = Path.Combine(factory.DataDirectory, "Synthetic Media");
            Directory.CreateDirectory(root);
            await using var scope = factory.Services.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var now = DateTimeOffset.UtcNow;
            var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", Path = root, NormalizedPath = MediaPath.Normalize(root), Kind = LibraryKind.Movies, MonitoringEnabled = false, CreatedAt = now, Availability = LibraryAvailability.Available };
            var movie = Item("Synthetic Movie", MediaKind.Movie, null, null, null);
            movie.Year = 2025;
            var series = Item("Synthetic Series", MediaKind.Series, null, null, null);
            series.Year = 2024;
            var episodes = Enumerable.Range(1, 5).Select(index => Item($"Synthetic Episode {index}", MediaKind.Episode, series, index < 4 ? 1 : 2, index < 4 ? index : index - 3)).ToList();
            var special = Item("Synthetic Special", MediaKind.Episode, series, 0, 1);
            database.MediaItems.AddRange([movie, series, special, .. episodes]);
            await database.SaveChangesAsync();
            // Watch actions must remain available after management is locked.
            using var locked = await client.SendAsync(ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/lock", owner.Token));
            locked.EnsureSuccessStatusCode();
            return new Fixture { Factory = factory, Client = client, Owner = owner, MediaRoot = root, Movie = movie, Series = series, Episodes = episodes, Special = special };

            MediaItem Item(string title, MediaKind kind, MediaItem? parent, int? season, int? episode)
            {
                var path = Path.Combine(root, title + ".mkv");
                if (kind != MediaKind.Series) File.WriteAllBytes(path, [1]);
                return new MediaItem
                {
                    Id = Guid.NewGuid(),
                    LibraryRoot = library,
                    LibraryRootId = library.Id,
                    Kind = kind,
                    Parent = parent,
                    ParentId = parent?.Id,
                    DetectedTitle = title,
                    SourcePath = path,
                    NormalizedSourcePath = MediaPath.Normalize(path),
                    SeasonNumber = season,
                    EpisodeNumber = episode,
                    Extension = kind == MediaKind.Series ? null : ".mkv",
                    Availability = MediaAvailability.Available,
                    CreatedAt = now,
                    UpdatedAt = now
                };
            }
        }

        public async Task<HttpResponseMessage> Send(HttpMethod method, string path, object? body = null) =>
            await Client.SendAsync(ApiTestClient.Authorized(method, path, Owner.Token, body));
        public async Task<T> Get<T>(string path)
        { using var response = await Send(HttpMethod.Get, path); response.EnsureSuccessStatusCode(); return await ApiTestClient.ReadAsync<T>(response); }
        public async Task<T> Put<T>(string path, object body)
        { using var response = await Send(HttpMethod.Put, path, body); response.EnsureSuccessStatusCode(); return await ApiTestClient.ReadAsync<T>(response); }
        public Task<WatchStateResponse> State(Guid id, WatchStateScope scope = WatchStateScope.Title, int? season = null) =>
            Get<WatchStateResponse>($"/api/v1/media/{id}/watch-state?scope={scope}" + (season.HasValue ? $"&seasonNumber={season}" : ""));
        public Task<PlaybackProgressResponse> Progress(MediaItem item, long position, bool finished = false) =>
            Put<PlaybackProgressResponse>($"/api/v1/media/{item.Id}/progress", new UpdatePlaybackProgressRequest(position, 300_000, finished));
        public async Task RestartAsync()
        {
            var directory = Factory.DataDirectory;
            Client.Dispose(); Factory.Dispose();
            Factory = new AureliaServerFactory(directory); Client = Factory.CreateClient();
            using var login = await ApiTestClient.LoginAsync(Client, new LoginRequest("lucas", "unused", "Restarted synthetic device"));
            Owner = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
            using var locked = await Send(HttpMethod.Post, "/api/v1/management/lock");
            locked.EnsureSuccessStatusCode();
        }
        public void Dispose()
        {
            Client.Dispose(); Factory.Dispose();
            if (Directory.Exists(Factory.DataDirectory)) Directory.Delete(Factory.DataDirectory, true);
        }
    }
}
