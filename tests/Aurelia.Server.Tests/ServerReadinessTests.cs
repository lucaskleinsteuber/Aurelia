using System.Net;
using System.Net.Http.Json;
using System.Data.Common;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.AspNetCore.Http;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerReadinessTests
{
    private static readonly string[] ReadinessStates = ["starting", "ready", "degraded", "unavailable", "recovering"];
    [Fact]
    public async Task LivenessNeverOpensDatabaseWhenReadinessDatabaseFails()
    {
        using var factory = new AureliaServerFactory(configureServices: services =>
        {
            services.AddHttpContextAccessor();
            services.AddSingleton<HealthDatabaseFailure>();
            services.AddDbContext<AureliaDbContext>((provider, options) =>
                options.AddInterceptors(provider.GetRequiredService<HealthDatabaseFailure>()));
        });
        using var client = factory.CreateClient();
        var interceptor = factory.Services.GetRequiredService<HealthDatabaseFailure>();
        var readiness = factory.Services.GetRequiredService<ServerReadinessService>();
        interceptor.FailConnections = true;
        try
        {
            await readiness.RefreshAsync(CancellationToken.None);
            Assert.Equal("unavailable", readiness.Current.State);
            using var live = await client.GetAsync("/api/v1/health/live");
            Assert.Equal(HttpStatusCode.OK, live.StatusCode);
            using var head = await client.SendAsync(new HttpRequestMessage(HttpMethod.Head, "/api/v1/health/live"));
            Assert.Equal(HttpStatusCode.OK, head.StatusCode);
            using var ready = await client.GetAsync("/api/v1/health/ready");
            Assert.Equal(HttpStatusCode.ServiceUnavailable, ready.StatusCode);
            Assert.Equal(0, interceptor.RequestConnections);
        }
        finally { interceptor.FailConnections = false; }
    }

    [Theory]
    [InlineData("ready", "ready", "ready")]
    [InlineData("ready", "degraded", "degraded")]
    [InlineData("unavailable", "ready", "unavailable")]
    [InlineData("unavailable", "recovering", "recovering")]
    public void ComponentReadinessNeverConfusesDegradationWithTransportFailure(string database, string media, string expected)
    {
        ServerComponentStatus[] components = [new("database", database), new("media", media)];
        Assert.Equal(expected, ServerReadinessService.DeriveState(components));
    }

    [Fact]
    public void StorageProbeReportsFullAndUnwritableStorageWithoutLeavingFiles()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        try
        {
            Assert.Equal("server_disk_full", ServerReadinessService.ProbeStorage(root, 0).Reason);
            Assert.Equal("server_disk_low", ServerReadinessService.ProbeStorage(root, 64 * 1024 * 1024).Reason);
            Assert.Equal("ready", ServerReadinessService.ProbeStorage(root, 1024L * 1024 * 1024).State);
            Assert.Empty(Directory.GetFiles(root));
            Assert.Equal("server_storage_unwritable", ServerReadinessService.ProbeStorage(Path.Combine(root, "missing"), null).Reason);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task BackupFailuresRemainVisibleUntilAnActualSuccessfulAttempt()
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        var runtime = new ServerRuntimeOptions(root, Path.Combine(root, "synthetic.db"),
            "http://127.0.0.1:43110", "Synthetic", false, 43111,
            Path.Combine(root, "unused.pem"), Path.Combine(root, "unused-key.pem"), null);
        var backups = new DatabaseBackupService(runtime);
        try
        {
            await Assert.ThrowsAsync<InvalidOperationException>(() => backups.CreateBackupAsync(DatabaseBackupKind.Manual, CancellationToken.None));
            Assert.True(backups.Health.LastAttemptFailed);
            Assert.Null(backups.Health.LastSucceededAt);
            await using (var database = new SqliteConnection($"Data Source={runtime.DatabasePath};Pooling=False"))
            {
                await database.OpenAsync();
                await using var command = database.CreateCommand();
                command.CommandText = "CREATE TABLE Synthetic(Value INTEGER); DROP TABLE Synthetic;";
                await command.ExecuteNonQueryAsync();
            }
            var path = await backups.CreateBackupAsync(DatabaseBackupKind.Manual, CancellationToken.None);
            Assert.True(File.Exists(path));
            Assert.False(backups.Health.LastAttemptFailed);
            Assert.NotNull(backups.Health.LastSucceededAt);
            using var cancelled = new CancellationTokenSource();
            await cancelled.CancelAsync();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => backups.CreateBackupAsync(DatabaseBackupKind.Manual, cancelled.Token));
            Assert.False(backups.Health.LastAttemptFailed);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task PublicReadinessIsCoarseAndLivenessSupportsHeadWithoutAuthentication()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var live = await client.GetFromJsonAsync<ServerLivenessResponse>("/api/v1/health/live");
        Assert.Equal("alive", live?.Status);
        using var head = await client.SendAsync(new HttpRequestMessage(HttpMethod.Head, "/api/v1/health/live"));
        Assert.Equal(HttpStatusCode.OK, head.StatusCode);
        Assert.Empty(await head.Content.ReadAsByteArrayAsync());
        using var response = await client.GetAsync("/api/v1/health/ready");
        using var json = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync());
        Assert.Single(json.RootElement.EnumerateObject());
        Assert.Contains(json.RootElement.GetProperty("state").GetString(), ReadinessStates);
        using var protectedStatus = await client.GetAsync("/api/v1/server/status");
        Assert.Equal(HttpStatusCode.Unauthorized, protectedStatus.StatusCode);
    }

    [Fact]
    public async Task CachedSampleSeparatesDatabaseMediaProviderAndRecoveryWithoutPaths()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        await ApiTestClient.SetupOwnerAsync(client);
        await using (var scope = factory.Services.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            database.LibraryRoots.Add(new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Synthetic",
                Path = "/synthetic/offline",
                NormalizedPath = "/synthetic/offline",
                Kind = LibraryKind.Movies,
                Availability = LibraryAvailability.Unavailable,
                MonitoringEnabled = false,
                CreatedAt = DateTimeOffset.UtcNow,
            });
            database.MetadataProviderCooldowns.Add(new MetadataProviderCooldown { NotBefore = DateTimeOffset.UtcNow.AddHours(1), WaitReason = "tmdb" });
            await database.SaveChangesAsync();
        }
        var readiness = factory.Services.GetRequiredService<ServerReadinessService>();
        await readiness.RefreshAsync(CancellationToken.None);
        Assert.Equal("degraded", readiness.Current.State);
        Assert.Contains(readiness.Current.Components, value => value.Id == "database" && value.State == "ready");
        Assert.Contains(readiness.Current.Components, value => value.Reason == "media_drive_disconnected");
        Assert.Contains(readiness.Current.Components, value => value.Reason == "provider_retry_pending");
        Assert.DoesNotContain("/synthetic", JsonSerializer.Serialize(readiness.Current));

        var journal = new HostOperationJournal(1, Guid.NewGuid(), "restore", "restarting", Guid.NewGuid(), null, null);
        await File.WriteAllTextAsync(Path.Combine(factory.DataDirectory, "host-operation.json"), JsonSerializer.Serialize(journal, ApiTestClient.JsonOptions));
        await readiness.RefreshAsync(CancellationToken.None);
        Assert.Equal("recovering", readiness.Current.State);
        using var ready = await client.GetAsync("/api/v1/health/ready");
        Assert.Equal(HttpStatusCode.ServiceUnavailable, ready.StatusCode);
        using var live = await client.GetAsync("/api/v1/health/live");
        Assert.Equal(HttpStatusCode.OK, live.StatusCode);
    }

    [Fact]
    public async Task RecoveryHistoryIsBoundedSanitizedAndNeverExposesHostPaths()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var readiness = factory.Services.GetRequiredService<ServerReadinessService>();
        var events = Enumerable.Range(0, 25).Select(index => new ServerRecoveryEvent(
            DateTimeOffset.UtcNow.AddSeconds(-index), "host_process_restart"))
            .Append(new(DateTimeOffset.UtcNow, "/synthetic/private-path"));
        var path = Path.Combine(factory.DataDirectory, "host-recovery.json");
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(events, ApiTestClient.JsonOptions));
        var status = readiness.Status(factory.Services.GetRequiredService<ServerTlsIdentity>(), factory.Services.GetRequiredService<ActiveStreamRegistry>());
        Assert.Equal(20, status.RecentRecoveryEvents.Count);
        Assert.All(status.RecentRecoveryEvents, value => Assert.Equal("host_process_restart", value.Code));
        Assert.DoesNotContain("/synthetic", JsonSerializer.Serialize(status));
        await File.WriteAllTextAsync(path, new string('x', 65_537));
        Assert.Empty(readiness.Status(factory.Services.GetRequiredService<ServerTlsIdentity>(), factory.Services.GetRequiredService<ActiveStreamRegistry>()).RecentRecoveryEvents);
    }

    private sealed class HealthDatabaseFailure(IHttpContextAccessor context) : DbConnectionInterceptor
    {
        private int requestConnections;
        public int RequestConnections => requestConnections;
        public bool FailConnections { get; set; }
        public override ValueTask<InterceptionResult> ConnectionOpeningAsync(DbConnection connection,
            ConnectionEventData eventData, InterceptionResult result, CancellationToken cancellationToken = default)
        {
            if (context.HttpContext?.Request.Path.StartsWithSegments("/api/v1/health") == true)
            {
                Interlocked.Increment(ref requestConnections);
            }
            if (FailConnections) throw new IOException("Synthetic database failure.");
            return ValueTask.FromResult(result);
        }
    }
}
