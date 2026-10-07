using System.Data.Common;
using System.Net;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class StorageReliabilityTests
{
    [Theory]
    [InlineData(5, true)]
    [InlineData(6, true)]
    [InlineData(8, true)]
    [InlineData(10, true)]
    [InlineData(13, true)]
    [InlineData(14, true)]
    [InlineData(11, false)]
    [InlineData(26, false)]
    [InlineData(19, false)]
    public void StorageClassificationDoesNotHideCorruptionOrConstraints(int code, bool recoverable)
    {
        var error = new SqliteException("synthetic storage failure", code);
        Assert.Equal(recoverable, StorageRecovery.IsRecoverableDatabase(error));
        Assert.Equal(recoverable, StorageRecovery.IsRecoverableDatabase(new DbUpdateException("synthetic", error)));
        Assert.Equal(code is 11 or 26, StorageRecovery.IsCorruptDatabase(error));
        Assert.False(StorageRecovery.IsRecoverable(new InvalidDataException("invalid persisted state")));
        Assert.False(StorageRecovery.IsRecoverable(new InvalidOperationException("programming error")));
    }

    [Fact]
    public async Task WorkerBoundaryRetriesUnavailableStorageWithoutDiscardingState()
    {
        var attempts = 0;
        var waits = 0;
        var recovery = new StorageRecovery(NullLogger.Instance, "synthetic worker", _ =>
        {
            waits++;
            return Task.CompletedTask;
        });
        var state = await recovery.RunAsync(() =>
        {
            if (++attempts < 4) throw new SqliteException("synthetic full disk", 13);
            return Task.FromResult("same queued job");
        }, CancellationToken.None);
        Assert.Equal("same queued job", state);
        Assert.Equal(4, attempts);
        Assert.Equal(3, waits);
        await Assert.ThrowsAsync<SqliteException>(() => recovery.RunAsync(
            () => Task.FromException(new SqliteException("corrupt database", 11)), CancellationToken.None));
    }

    [Fact]
    public async Task OneContinuousStorageOutageLogsOnceRatherThanEveryRetry()
    {
        var logger = new CaptureLogger();
        var attempts = 0;
        var recovery = new StorageRecovery(logger, "synthetic worker", _ => Task.CompletedTask);
        await recovery.RunAsync(() => ++attempts < 100
            ? Task.FromException(new SqliteException("synthetic full disk", 13))
            : Task.CompletedTask, CancellationToken.None);
        Assert.Equal(100, attempts);
        Assert.Single(logger.Levels, level => level == LogLevel.Warning);
        Assert.Single(logger.Levels, level => level == LogLevel.Information);
        Assert.DoesNotContain(LogLevel.Error, logger.Levels);
    }

    [Fact]
    public async Task StorageWaitStopsPromptlyWhenTheHostStops()
    {
        using var stop = new CancellationTokenSource();
        var waits = 0;
        var recovery = new StorageRecovery(NullLogger.Instance, "synthetic worker", token =>
        {
            waits++;
            stop.Cancel();
            return Task.FromCanceled(token);
        });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => recovery.RunAsync(
            () => Task.FromException(new SqliteException("locked database", 6)), stop.Token));
        Assert.Equal(1, waits);
    }

    [Fact]
    public async Task MaintenanceContinuesOtherPhasesAndRetriesOnTheNextPass()
    {
        var phases = new MaintenancePhaseRunner(NullLogger.Instance);
        var cleaned = 0;
        await phases.RunAsync("backup", () => Task.FromException(new IOException("backup destination unavailable")), CancellationToken.None);
        await phases.RunAsync("cleanup", () => { cleaned++; return Task.CompletedTask; }, CancellationToken.None);
        await phases.RunAsync("backup", () => { cleaned++; return Task.CompletedTask; }, CancellationToken.None);
        Assert.Equal(2, cleaned);
        await Assert.ThrowsAsync<SqliteException>(() => phases.RunAsync("cleanup",
            () => Task.FromException(new SqliteException("corruption", 11)), CancellationToken.None));
    }

    [Fact]
    public async Task ActivityWritesAreOptionalThrottledAndResumeAfterStorageRecovers()
    {
        var directory = TestPaths.CreateDataDirectory();
        try
        {
            var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["run", "--data-dir", directory]);
            using var diagnostics = new ServerDiagnosticsStore(runtime, new ServerConfigurationStore(runtime));
            var clock = new MutableClock();
            var activity = new SessionActivityRecorder(clock, diagnostics);
            var id = Guid.NewGuid();
            var attempts = 0;
            for (var index = 0; index < 20; index++)
                await activity.TryRecordAsync(id, () => { attempts++; throw new SqliteException("full disk", 13); });
            Assert.Equal(1, attempts);
            clock.Advance(TimeSpan.FromMinutes(1));
            await activity.TryRecordAsync(id, () => { attempts++; return Task.CompletedTask; });
            Assert.Equal(2, attempts);
            await Assert.ThrowsAsync<SqliteException>(() => activity.TryRecordAsync(Guid.NewGuid(),
                () => Task.FromException(new SqliteException("corruption", 11))));
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => activity.TryRecordAsync(Guid.NewGuid(),
                () => Task.FromCanceled(new CancellationToken(canceled: true))));
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task ValidAuthorizationSurvivesOnlyActivityWriteFailureAndRevocationStillWins()
    {
        var failures = new ActivityWriteFailure();
        using var factory = new AureliaServerFactory(configureServices: services =>
            services.ConfigureDbContext<AureliaDbContext>((_, options) => options.AddInterceptors(failures)));
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await using (var scope = factory.Services.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            await database.DeviceSessions.Where(session => session.Id == owner.SessionId)
                .ExecuteUpdateAsync(set => set.SetProperty(session => session.LastSeenAt, DateTimeOffset.UtcNow.AddMinutes(-2)));
        }
        failures.Enabled = true;
        using (var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/auth/me", owner.Token))
        using (var response = await client.SendAsync(request)) Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(1, failures.Writes);
        // Administrative revocation is not optional bookkeeping and still changes
        // the live authorization read, even when the activity write was skipped.
        failures.Enabled = false;
        await using (var scope = factory.Services.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            await database.DeviceSessions.Where(session => session.Id == owner.SessionId)
                .ExecuteUpdateAsync(set => set.SetProperty(session => session.RevokedAt, DateTimeOffset.UtcNow));
        }
        using var revokedRequest = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/auth/me", owner.Token);
        using var revoked = await client.SendAsync(revokedRequest);
        Assert.Equal(HttpStatusCode.Unauthorized, revoked.StatusCode);
    }

    [Fact]
    public async Task WorkerRecoveryAndMonitoringResumeAfterInjectedSqliteFailuresWithoutStoppingTheHost()
    {
        var failures = new WorkerStorageFailure();
        using var factory = new AureliaServerFactory(configureServices: services =>
            services.ConfigureDbContext<AureliaDbContext>((_, options) => options.AddInterceptors(failures)));
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var deadline = DateTimeOffset.UtcNow.AddSeconds(12);
        while (!failures.Recovered && DateTimeOffset.UtcNow < deadline)
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/auth/me", owner.Token);
            using var response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            await Task.Delay(100);
        }
        Assert.True(failures.Recovered, "All three background workers must retry their authoritative queries after storage becomes available.");
    }

    [Fact]
    public async Task RegistrationCannotDisposeDuringAnInFlightCancellationCallback()
    {
        using var registration = new JobCancellationRegistration(CancellationToken.None);
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        using var callback = registration.Token.Register(() => { entered.Set(); Assert.True(release.Wait(TimeSpan.FromSeconds(5))); });
        var cancel = Task.Run(registration.Cancel);
        try
        {
            Assert.True(entered.Wait(TimeSpan.FromSeconds(5)));
            registration.Dispose();
            Assert.False(registration.Cancel());
        }
        finally { release.Set(); }
        Assert.True(await cancel);
    }

    [Fact]
    public async Task CompletingAndCancellingBothSchedulersNeverThrowsOrLeaksRegistrations()
    {
        var directory = TestPaths.CreateDataDirectory();
        try
        {
            var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["run", "--data-dir", directory]);
            var scans = new LibraryScanScheduler(new ServerConfigurationStore(runtime));
            var metadata = new MetadataJobScheduler();
            for (var index = 0; index < 250; index++)
            {
                var id = Guid.NewGuid();
                _ = scans.Register(id, CancellationToken.None);
                _ = metadata.Register(id, CancellationToken.None);
                using var start = new ManualResetEventSlim();
                var cancel = Task.Run(() => { start.Wait(); scans.RequestCancellation(id); metadata.RequestCancellation(id); });
                var finish = Task.Run(() => { start.Wait(); scans.Unregister(id); metadata.Unregister(id); });
                start.Set();
                await Task.WhenAll(cancel, finish);
                _ = scans.Register(id, CancellationToken.None);
                _ = metadata.Register(id, CancellationToken.None);
                scans.Unregister(id);
                metadata.Unregister(id);
            }
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    private sealed class MutableClock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan value) => now += value;
    }

    private sealed class CaptureLogger : ILogger
    {
        public List<LogLevel> Levels { get; } = [];
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
            => Levels.Add(logLevel);
    }

    private sealed class ActivityWriteFailure : DbCommandInterceptor
    {
        public bool Enabled { get; set; }
        public int Writes { get; private set; }
        public override ValueTask<InterceptionResult<int>> NonQueryExecutingAsync(DbCommand command,
            CommandEventData eventData, InterceptionResult<int> result, CancellationToken cancellationToken = default)
        {
            if (Enabled && command.CommandText.StartsWith("UPDATE \"DeviceSessions\"", StringComparison.Ordinal)
                && command.CommandText.Contains("LastSeenAt", StringComparison.Ordinal))
            {
                Writes++;
                throw new SqliteException("synthetic activity write failure", 13);
            }
            return base.NonQueryExecutingAsync(command, eventData, result, cancellationToken);
        }
    }

    private sealed class WorkerStorageFailure : DbCommandInterceptor
    {
        private readonly object gate = new();
        private readonly Dictionary<string, int> queries = [];
        public bool Recovered { get { lock (gate) return queries.Count == 3 && queries.Values.All(count => count >= 2); } }

        public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(DbCommand command,
            CommandEventData eventData, InterceptionResult<DbDataReader> result, CancellationToken cancellationToken = default)
        {
            var sql = command.CommandText;
            var operation = sql.Contains("FROM \"LibraryScans\"", StringComparison.Ordinal) && sql.Contains("'Running'", StringComparison.Ordinal)
                ? "scan recovery" : sql.Contains("FROM \"MetadataJobs\"", StringComparison.Ordinal) && sql.Contains("'Running'", StringComparison.Ordinal)
                ? "metadata recovery" : sql.Contains("FROM \"LibraryRoots\"", StringComparison.Ordinal) && sql.Contains("ORDER BY \"l\".\"Id\"", StringComparison.Ordinal)
                ? "library monitoring" : null;
            if (operation is not null)
            {
                lock (gate)
                {
                    queries[operation] = queries.GetValueOrDefault(operation) + 1;
                    if (queries[operation] == 1) throw new SqliteException("synthetic worker storage failure", 5);
                }
            }
            return base.ReaderExecutingAsync(command, eventData, result, cancellationToken);
        }
    }
}
