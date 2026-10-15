using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class MetadataJobPersistenceTests
{
    [Fact]
    public async Task WorklistIsFrozenAndRestartResumesOnlyUnfinishedTitles()
    {
        await using var fixture = await Fixture.CreateAsync(2);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Provider.BeforeSearch = async (title, token) =>
        {
            if (title == "Title 2") { entered.TrySetResult(); await Task.Delay(Timeout.InfiniteTimeSpan, token); }
        };
        var job = await fixture.Start();
        await fixture.Run();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(1, (await fixture.Job(job.Id)).ItemsMatched);
        await fixture.Stop();
        Assert.Equal(MetadataJobState.Queued, (await fixture.Job(job.Id)).State);
        await fixture.AddTitle(3);
        fixture.Provider.BeforeSearch = null;
        await fixture.Run();
        var completed = await fixture.Wait(job.Id, value => value.State == MetadataJobState.Completed);
        Assert.Equal(2, completed.ItemsTotal);
        Assert.Equal(2, completed.ItemsProcessed);
        Assert.Equal(1, fixture.Provider.Searches["Title 1"]);
        Assert.Equal(2, fixture.Provider.Searches["Title 2"]);
        Assert.False(fixture.Provider.Searches.ContainsKey("Title 3"));
    }

    [Fact]
    public async Task ACrashProcessingMarkerResumesWithoutRepeatingCompletedItems()
    {
        await using var fixture = await Fixture.CreateAsync(2);
        var job = await fixture.Start();
        await fixture.Write(async database =>
        {
            var stored = await database.MetadataJobs.SingleAsync(value => value.Id == job.Id);
            stored.State = MetadataJobState.Running;
            stored.ItemsProcessed = stored.ItemsMatched = 1;
            var work = await database.MetadataJobItems.OrderBy(value => value.Ordinal).ToListAsync();
            work[0].State = MetadataWorkState.Matched;
            work[1].State = MetadataWorkState.Processing;
            work[1].Attempt = 2;
            await database.SaveChangesAsync();
        });
        await fixture.Run();
        var completed = await fixture.Wait(job.Id, value => value.State == MetadataJobState.Completed);
        Assert.Equal(2, completed.ItemsMatched);
        Assert.False(fixture.Provider.Searches.ContainsKey("Title 1"));
        Assert.Equal(1, fixture.Provider.Searches["Title 2"]);
        Assert.Equal(2, await fixture.Read(database => database.MetadataJobItems.Where(value => value.MediaItemId == Fixture.Id(2)).Select(value => value.Attempt).SingleAsync()));
    }

    [Fact]
    public async Task ConcurrentHostRecoveryKeepsEachWorklistIsolated()
    {
        await Task.WhenAll(Enumerable.Range(0, 6).Select(_ => ACrashProcessingMarkerResumesWithoutRepeatingCompletedItems()));
    }

    [Fact]
    public async Task BackoffHasFourAttemptsAndRetryCopiesOnlyUnfinishedTitles()
    {
        await using var fixture = await Fixture.CreateAsync(2);
        fixture.Provider.BeforeSearch = (title, _) => title == "Title 2"
            ? throw new MetadataProviderException("Synthetic temporary failure", transient: true) : Task.CompletedTask;
        var job = await fixture.Start();
        await fixture.Run();
        var expectedDelays = new[] { 30, 120, 600 };
        for (var attempt = 0; attempt < expectedDelays.Length; attempt++)
        {
            var waiting = await fixture.Wait(job.Id, value => value.NextAttemptAt.HasValue);
            Assert.Equal(fixture.Clock.GetUtcNow().AddSeconds(expectedDelays[attempt]), waiting.NextAttemptAt);
            Assert.Equal("tmdb", waiting.WaitReason);
            Assert.Equal(attempt + 1, fixture.Provider.Searches["Title 2"]);
            Assert.Equal(1, waiting.ItemsProcessed);
            fixture.Advance(expectedDelays[attempt]);
            await fixture.Wait(job.Id, value => value.NextAttemptAt != waiting.NextAttemptAt);
        }
        var failed = await fixture.Wait(job.Id, value => value.State == MetadataJobState.Failed);
        Assert.Equal(4, fixture.Provider.Searches["Title 2"]);
        Assert.Equal(2, failed.ItemsProcessed);
        Assert.Equal(1, failed.ItemsFailed);
        Assert.Equal(0, await fixture.Read(database => database.MetadataReviews.CountAsync()));
        fixture.Provider.BeforeSearch = null;
        await using var scope = fixture.Factory.Services.CreateAsyncScope();
        var retry = await scope.ServiceProvider.GetRequiredService<MetadataService>().RetryJobAsync(job.Id, default);
        Assert.Equal(1, retry.ItemsTotal);
        var completed = await fixture.Wait(retry.Id, value => value.State == MetadataJobState.Completed);
        Assert.Equal(1, completed.ItemsMatched);
        Assert.Equal(1, fixture.Provider.Searches["Title 1"]);
    }

    [Fact]
    public async Task LongerRetryAfterDelaysOtherAutomaticJobsAndSurvivesWorkerRestart()
    {
        await using var fixture = await Fixture.CreateAsync(2);
        fixture.Provider.BeforeSearch = (_, _) => throw new MetadataProviderException("Synthetic rate limit", transient: true, retryAfter: TimeSpan.FromMinutes(20));
        var job = await fixture.Start(Fixture.Id(1));
        await fixture.Run();
        var waiting = await fixture.Wait(job.Id, value => value.NextAttemptAt.HasValue);
        Assert.Equal(fixture.Clock.GetUtcNow().AddMinutes(20), waiting.NextAttemptAt);
        var other = await fixture.Start(Fixture.Id(2));
        Assert.Equal(waiting.NextAttemptAt, other.NextAttemptAt);
        await fixture.Stop();
        fixture.Provider.BeforeSearch = null;
        await fixture.Run();
        fixture.Advance(1199);
        await Task.Delay(100);
        Assert.False(fixture.Provider.Searches.ContainsKey("Title 2"));
        fixture.Advance(1);
        await fixture.Wait(job.Id, value => value.State == MetadataJobState.Completed);
        await fixture.Wait(other.Id, value => value.State == MetadataJobState.Completed);
    }

    [Fact]
    public async Task UnexpectedItemFailureAlsoRetainsAnIndividualFailedResult()
    {
        await using var fixture = await Fixture.CreateAsync(1);
        fixture.Provider.BeforeSearch = (_, _) => throw new FormatException("Synthetic malformed provider data");
        var job = await fixture.Start();
        await fixture.Run();
        var failed = await fixture.Wait(job.Id, value => value.State == MetadataJobState.Failed);
        Assert.Equal(1, failed.ItemsFailed);
        Assert.Equal(1, failed.ItemsProcessed);
        Assert.Equal(MetadataWorkState.Failed, await fixture.Read(database => database.MetadataJobItems.Select(value => value.State).SingleAsync()));
        Assert.Equal(0, await fixture.Read(database => database.MetadataReviews.CountAsync()));
    }

    [Fact]
    public async Task AuthenticationFailureStopsImmediatelyWithoutCreatingAReview()
    {
        await using var fixture = await Fixture.CreateAsync(2);
        fixture.Provider.BeforeSearch = (_, _) => throw new MetadataProviderException("Synthetic rejected token", transient: false, authenticationFailure: true);
        var job = await fixture.Start();
        await fixture.Run();
        var failed = await fixture.Wait(job.Id, value => value.State == MetadataJobState.Failed);
        Assert.Equal(1, failed.ItemsFailed);
        Assert.Null(failed.NextAttemptAt);
        Assert.Single(fixture.Provider.Searches);
        Assert.Equal(0, await fixture.Read(database => database.MetadataReviews.CountAsync()));
    }

    [Fact]
    public async Task PartiallyAppliedIncrementalTitleCanRetryIdempotently()
    {
        await using var fixture = await Fixture.CreateAsync(1);
        fixture.Provider.WithArtwork = true;
        fixture.Provider.BeforeImage = () => fixture.Provider.ImageRequests == 1
            ? throw new MetadataProviderException("Synthetic artwork timeout", transient: true) : Task.CompletedTask;
        var job = await fixture.Start(mode: MetadataJobMode.Incremental);
        await fixture.Run();
        await fixture.Wait(job.Id, value => value.NextAttemptAt.HasValue);
        Assert.Equal("Title 1", await fixture.Read(database => database.MediaMetadata.Select(value => value.ProviderMediaId).SingleAsync()));
        fixture.Advance(30);
        var completed = await fixture.Wait(job.Id, value => value.State == MetadataJobState.Completed);
        Assert.Equal(1, completed.ItemsMatched);
        Assert.Equal(1, await fixture.Read(database => database.MediaCredits.CountAsync()));
        Assert.Equal(1, await fixture.Read(database => database.ArtworkAssets.CountAsync()));
        Assert.Equal(2, fixture.Provider.Searches["Title 1"]);
    }

    [Fact]
    public async Task RemovedTitlesAndRevokedTitleGrantsAreSkippedAtExecutionTime()
    {
        await using var fixture = await Fixture.CreateAsync(3);
        var admin = new ServerUser { Id = Guid.NewGuid(), Username = "Scoped", NormalizedUsername = "SCOPED", PasswordHash = "synthetic", Role = UserRole.Admin, AccessMode = ProfileAccessMode.SelectedTitles };
        await fixture.Write(async database =>
        {
            database.Users.Add(admin);
            database.UserTitleGrants.Add(new UserTitleGrant { UserId = admin.Id, MediaItemId = Fixture.Id(1) });
            await database.SaveChangesAsync();
        });
        MetadataJobSummary scoped;
        await using (var scope = fixture.Factory.Services.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            database.AccessUserId = admin.Id; database.AccessMode = admin.AccessMode;
            scoped = await scope.ServiceProvider.GetRequiredService<MetadataService>().StartAsync(new StartMetadataJobRequest(MetadataJobMode.SingleItem, MediaId: Fixture.Id(1)), default);
        }
        var all = await fixture.Start();
        await fixture.Write(async database =>
        {
            await database.UserTitleGrants.ExecuteDeleteAsync();
            await database.MediaItems.Where(value => value.Id == Fixture.Id(2)).ExecuteDeleteAsync();
        });
        await fixture.Run();
        var skipped = await fixture.Wait(scoped.Id, value => value.State == MetadataJobState.Completed);
        Assert.Equal(1, skipped.ItemsSkipped);
        var completed = await fixture.Wait(all.Id, value => value.State == MetadataJobState.Completed);
        Assert.Equal(3, completed.ItemsTotal);
        Assert.Equal(1, completed.ItemsSkipped);
        Assert.Equal(2, completed.ItemsMatched);
    }

    [Fact]
    public async Task CancellationAndConcurrentManualCorrectionAreObservedAfterProviderAwait()
    {
        await using var fixture = await Fixture.CreateAsync(1);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Provider.BeforeSearch = async (_, token) => { entered.TrySetResult(); await release.Task.WaitAsync(token); };
        var job = await fixture.Start();
        await fixture.Run();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await fixture.Write(async database =>
        {
            database.MediaMetadata.Add(new MediaMetadata { MediaItemId = Fixture.Id(1), ManualTitle = "My corrected title" });
            await database.SaveChangesAsync();
        });
        release.TrySetResult();
        var completed = await fixture.Wait(job.Id, value => value.State == MetadataJobState.Completed);
        Assert.Equal(1, completed.ItemsSkipped);
        Assert.Null(await fixture.Read(database => database.MediaMetadata.Select(value => value.ProviderMediaId).SingleAsync()));
        await fixture.Stop();
        entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Provider.BeforeSearch = async (_, token) => { entered.TrySetResult(); await Task.Delay(Timeout.InfiniteTimeSpan, token); };
        var cancel = await fixture.Start();
        await fixture.Run();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await using var scope = fixture.Factory.Services.CreateAsyncScope();
        await scope.ServiceProvider.GetRequiredService<MetadataService>().CancelJobAsync(cancel.Id, default);
        var cancelled = await fixture.Wait(cancel.Id, value => value.State == MetadataJobState.Cancelled);
        Assert.Equal(0, cancelled.ItemsProcessed);
    }

    [Fact]
    public async Task StorageFailureRetainsResultsAndDoesNotConsumeProviderRetryBudget()
    {
        await using var fixture = await Fixture.CreateAsync(2);
        fixture.Provider.BeforeSearch = (title, _) => title == "Title 2" && fixture.Provider.Searches[title] == 1
            ? throw new SqliteException("Synthetic full disk", 13) : Task.CompletedTask;
        var job = await fixture.Start();
        await fixture.Run();
        var waiting = await fixture.Wait(job.Id, value => value.WaitReason == "storage");
        Assert.Equal(1, waiting.ItemsMatched);
        Assert.Equal(0, await fixture.Read(database => database.MetadataJobItems.Where(value => value.JobId == job.Id && value.MediaItemId == Fixture.Id(2)).Select(value => value.Attempt).SingleAsync()));
        fixture.Advance(5);
        var completed = await fixture.Wait(job.Id, value => value.State == MetadataJobState.Completed);
        Assert.Equal(2, completed.ItemsMatched);
        Assert.Equal(1, fixture.Provider.Searches["Title 1"]);
    }

    [Fact]
    public async Task DuplicateStartsReturnOneDurableWorklistAcrossMultipleCreationBatches()
    {
        await using var fixture = await Fixture.CreateAsync(513);
        var starts = await Task.WhenAll(fixture.Start(), fixture.Start());
        Assert.Equal(starts[0].Id, starts[1].Id);
        Assert.Equal(513, starts[0].ItemsTotal);
        Assert.Equal(513, await fixture.Read(database => database.MetadataJobItems.CountAsync()));
        Assert.Equal(1, await fixture.Read(database => database.MetadataJobs.CountAsync()));
    }

    [Fact]
    public async Task EmptyWorklistsCompleteWithoutWaitingForProviderCooldown()
    {
        await using var fixture = await Fixture.CreateAsync(0);
        await fixture.Write(async database =>
        {
            database.MetadataProviderCooldowns.Add(new MetadataProviderCooldown { NotBefore = fixture.Clock.GetUtcNow().AddHours(1), WaitReason = "tmdb" });
            await database.SaveChangesAsync();
        });
        var job = await fixture.Start();
        Assert.Equal(MetadataJobState.Completed, job.State);
        Assert.Equal(0, job.ItemsTotal);
        Assert.Null(job.NextAttemptAt);
    }

    [Fact]
    public async Task ProviderDeadlineAlsoCoversAnUnresponsiveResponseBody()
    {
        using var handler = new StalledBodyHandler();
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromMilliseconds(50) };
        var error = await Assert.ThrowsAsync<MetadataProviderException>(() => new TmdbClient(client).ValidateAsync("synthetic-secret", default));
        Assert.True(error.Transient);
        Assert.Contains("time", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AbsoluteRetryAfterUsesTheInjectedClock()
    {
        var clock = new MutableClock();
        var date = DateTimeOffset.FromUnixTimeSeconds(clock.GetUtcNow().AddMinutes(25).ToUnixTimeSeconds());
        using var handler = new ResponseHandler(429, date);
        using var client = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<MetadataProviderException>(() => new TmdbClient(client, clock).ValidateAsync("synthetic-secret", default));
        Assert.Equal(date - clock.GetUtcNow(), error.RetryAfter);
    }

    [Theory]
    [InlineData(429, false, true)]
    [InlineData(503, false, true)]
    [InlineData(401, true, false)]
    public async Task ProviderReportsRetryAfterWithoutSleepingOrLeakingCredentials(int status, bool auth, bool transient)
    {
        using var handler = new ResponseHandler(status);
        using var client = new HttpClient(handler);
        var provider = new TmdbClient(client);
        var error = await Assert.ThrowsAsync<MetadataProviderException>(() => provider.ValidateAsync("synthetic-secret", default));
        Assert.Equal(auth, error.AuthenticationFailure);
        Assert.Equal(transient, error.Transient);
        Assert.Equal(TimeSpan.FromMinutes(25), error.RetryAfter);
        Assert.DoesNotContain("synthetic-secret", error.ToString(), StringComparison.Ordinal);
        Assert.Equal(1, handler.Requests);
    }

    private sealed class ResponseHandler(int status, DateTimeOffset? date = null) : HttpMessageHandler
    {
        public int Requests { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            var response = new HttpResponseMessage((HttpStatusCode)status);
            response.Headers.RetryAfter = date.HasValue ? new RetryConditionHeaderValue(date.Value) : new RetryConditionHeaderValue(TimeSpan.FromMinutes(25));
            return Task.FromResult(response);
        }
    }

    private sealed class StalledBodyHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StalledContent() });
    }
    private sealed class StalledContent : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => Task.Delay(Timeout.InfiniteTimeSpan);
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken cancellationToken) => Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
    }

    private sealed class Fixture : IAsyncDisposable
    {
        public AureliaServerFactory Factory { get; private set; } = null!;
        public MutableClock Clock { get; } = new();
        public Provider Provider { get; } = new();
        private MetadataJobWorker? worker;
        private Guid libraryId;
        public static Guid Id(int value) => new(value, 0, 0, new byte[8]);

        public static async Task<Fixture> CreateAsync(int titles)
        {
            var fixture = new Fixture();
            fixture.Factory = new AureliaServerFactory(configureServices: services =>
            {
                var registration = services.Single(value => value.ServiceType == typeof(IHostedService) && value.ImplementationType == typeof(MetadataJobWorker));
                services.Remove(registration);
                services.RemoveAll<ITmdbClient>();
                services.AddSingleton<ITmdbClient>(fixture.Provider);
                services.RemoveAll<TimeProvider>();
                services.AddSingleton<TimeProvider>(fixture.Clock);
            });
            using var client = fixture.Factory.CreateClient();
            _ = await ApiTestClient.SetupOwnerAsync(client);
            fixture.Factory.Services.GetRequiredService<MetadataProviderSettingsStore>().Save(new UpdateMetadataProviderRequest(true, "en", "synthetic-provider-token-with-no-network"));
            fixture.libraryId = Guid.NewGuid();
            await fixture.Write(async database =>
            {
                database.LibraryRoots.Add(new LibraryRoot { Id = fixture.libraryId, Name = "Synthetic", Path = "", NormalizedPath = "", MonitoringEnabled = false, Kind = LibraryKind.Movies });
                await database.SaveChangesAsync();
            });
            for (var index = 1; index <= titles; index++) await fixture.AddTitle(index);
            return fixture;
        }
        public async Task AddTitle(int index) => await Write(async database =>
        {
            database.MediaItems.Add(new MediaItem { Id = Id(index), LibraryRootId = libraryId, Kind = MediaKind.Movie, DetectedTitle = $"Title {index}", SourcePath = $"synthetic/{index}", NormalizedSourcePath = $"SYNTHETIC/{index}" });
            await database.SaveChangesAsync();
        });
        public async Task<MetadataJobSummary> Start(Guid? id = null, MetadataJobMode mode = MetadataJobMode.FullRefresh)
        {
            await using var scope = Factory.Services.CreateAsyncScope();
            return await scope.ServiceProvider.GetRequiredService<MetadataService>().StartAsync(new StartMetadataJobRequest(id.HasValue ? MetadataJobMode.SingleItem : mode, MediaId: id), default);
        }
        public async Task Run()
        {
            worker = new MetadataJobWorker(Factory.Services.GetRequiredService<MetadataJobScheduler>(), Factory.Services.GetRequiredService<IServiceScopeFactory>(), Factory.Services.GetRequiredService<ILogger<MetadataJobWorker>>(), Clock);
            await worker.StartAsync(default);
        }
        public async Task Stop()
        {
            if (worker is null) return;
            await worker.StopAsync(default);
            worker.Dispose(); worker = null;
        }
        public void Advance(int seconds) { Clock.Advance(seconds); Factory.Services.GetRequiredService<MetadataJobScheduler>().Pulse(); }
        public async Task<MetadataJobSummary> Job(Guid id) => await Read(async database => MetadataService.ToSummary(await database.MetadataJobs.IgnoreQueryFilters().AsNoTracking().SingleAsync(value => value.Id == id)));
        public async Task<MetadataJobSummary> Wait(Guid id, Func<MetadataJobSummary, bool> predicate)
        {
            var timeout = DateTime.UtcNow.AddSeconds(15);
            while (DateTime.UtcNow < timeout)
            {
                var value = await Job(id);
                Assert.InRange(value.ItemsProcessed, 0, value.ItemsTotal);
                if (predicate(value)) return value;
                await Task.Delay(20);
            }
            var last = await Job(id);
            throw new TimeoutException($"Job remained {last.State}: {last.Error}; next={last.NextAttemptAt} count={last.ItemsProcessed}/{last.ItemsTotal}");
        }
        public async Task<T> Read<T>(Func<AureliaDbContext, Task<T>> action)
        {
            await using var scope = Factory.Services.CreateAsyncScope();
            return await action(scope.ServiceProvider.GetRequiredService<AureliaDbContext>());
        }
        public async Task Write(Func<AureliaDbContext, Task> action)
        {
            await using var scope = Factory.Services.CreateAsyncScope();
            await action(scope.ServiceProvider.GetRequiredService<AureliaDbContext>());
        }
        public async ValueTask DisposeAsync() { await Stop(); Factory.Dispose(); }
    }

    private sealed class MutableClock : TimeProvider
    {
        private long ticks = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()).UtcTicks;
        public override DateTimeOffset GetUtcNow() => new(Interlocked.Read(ref ticks), TimeSpan.Zero);
        public void Advance(int seconds) => Interlocked.Add(ref ticks, TimeSpan.FromSeconds(seconds).Ticks);
    }

    private sealed class Provider : ITmdbClient
    {
        public ConcurrentDictionary<string, int> Searches { get; } = new();
        public Func<string, CancellationToken, Task>? BeforeSearch { get; set; }
        public Func<Task>? BeforeImage { get; set; }
        public bool WithArtwork { get; set; }
        public int ImageRequests;
        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;
        public async Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(string token, string language, MediaKind kind, string title, int? year, CancellationToken cancellationToken)
        {
            Searches.AddOrUpdate(title, 1, (_, count) => count + 1);
            if (BeforeSearch is not null) await BeforeSearch(title, cancellationToken);
            return [new MetadataCandidateSummary("tmdb", title, "movie", title, null, null, null, null, 1)];
        }
        public Task<TmdbMetadata> GetAsync(string token, string language, string mediaType, string providerId, CancellationToken cancellationToken) =>
            Task.FromResult(new TmdbMetadata(providerId, mediaType, providerId, null, null, null, null, null, null, [], [], [], WithArtwork ? "/poster.jpg" : null, null,
                [new TmdbCredit("1", "Synthetic Actor", "Acting", null, null, 0, null)], null));
        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(string token, string language, string seriesProviderId, int seasonNumber, CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>([]);
        public async Task<byte[]> DownloadImageAsync(string token, string providerPath, string size, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref ImageRequests);
            if (BeforeImage is not null) await BeforeImage();
            return [0xff, 0xd8, 1, 2, 3, 4, 0xff, 0xd9, 0, 0, 0, 0, 0xff, 0xd9];
        }
    }
}
