using System.Net;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerPerformanceTests
{
    [Fact]
    public void StatementsKeepTheirShapeButNoValues()
    {
        var sanitized = ServerPerformanceStore.Sanitize(
            "SELECT \"m\".\"Title\"\n  FROM \"MediaItems\" AS \"m\"\r\n WHERE \"m\".\"Title\" = 'Synthetic Secret Title' AND \"m\".\"Year\" > 2020 AND \"m\".\"Id\" = @__id_0 AND x'0A0B' IS NOT NULL LIMIT 50 OFFSET @p1");
        Assert.DoesNotContain("Synthetic Secret Title", sanitized);
        Assert.DoesNotContain("2020", sanitized);
        Assert.DoesNotContain("0A0B", sanitized);
        Assert.Contains("@__id_0", sanitized);
        Assert.Contains("@p1", sanitized);
        Assert.Contains("LIMIT ?", sanitized);
        Assert.DoesNotContain("\n", sanitized);
        Assert.Equal("SELECT", ServerPerformanceStore.Kind(sanitized));
        Assert.Equal("UPDATE", ServerPerformanceStore.Kind("update \"Users\" set \"Name\" = ?"));
        Assert.Equal("SELECT", ServerPerformanceStore.Kind("WITH RECURSIVE x AS (SELECT ?) SELECT * FROM x"));
        Assert.Equal("OTHER", ServerPerformanceStore.Kind("PRAGMA wal_checkpoint"));
        Assert.Equal(ServerPerformanceStore.MaximumStatementLength + 1,
            ServerPerformanceStore.Sanitize("SELECT " + new string('a', 2000)).Length);
        Assert.Equal(string.Empty, ServerPerformanceStore.Sanitize(null));
    }

    [Fact]
    public void PercentilesComeFromTheBucketsAndNeverExceedTheMaximum()
    {
        var histogram = new long[ServerPerformanceStore.Edges.Length + 1];
        Assert.Equal(0, ServerPerformanceStore.Percentile(histogram, 0.95, 0));
        // 90 requests up to 10 ms, 10 requests between 200 and 500 ms.
        histogram[ServerPerformanceStore.BucketIndex(8)] = 90;
        histogram[ServerPerformanceStore.BucketIndex(300)] = 10;
        var median = ServerPerformanceStore.Percentile(histogram, 0.5, 320);
        var p95 = ServerPerformanceStore.Percentile(histogram, 0.95, 320);
        Assert.InRange(median, 5, 10);
        Assert.InRange(p95, 200, 320);
        Assert.Equal(13, ServerPerformanceStore.BucketIndex(25_000));
        Assert.Equal(14, ServerPerformanceStore.BucketIndex(60_000));
    }

    [Fact]
    public async Task MeasurementsAddUpPersistAndExpire()
    {
        using var fixture = new Fixture();
        for (var index = 0; index < 19; index++)
            fixture.Store.RecordRequest("GET /api/v1/home", 12, 200, 6);
        fixture.Store.RecordRequest("GET /api/v1/home", 900, 500, 6);
        fixture.Store.RecordQuery(40, "SELECT 1", null);
        fixture.Store.RecordQuery(250, "SELECT * FROM \"MediaItems\" WHERE \"Title\" = 'Synthetic'", "GET /api/v1/home");

        var read = fixture.Store.Read();
        var home = Assert.Single(read.Endpoints);
        Assert.Equal(("GET", "/api/v1/home"), (home.Method, home.Route));
        Assert.Equal(20, home.Count);
        Assert.Equal(1, home.Errors);
        Assert.Equal(1, home.SlowCount);
        Assert.Equal(900, home.MaxMilliseconds);
        Assert.Equal(6, home.QueriesPerRequest);
        Assert.Equal(20, read.Requests);
        var slow = Assert.Single(read.SlowQueries);
        Assert.Equal("GET /api/v1/home", slow.Endpoint);
        Assert.DoesNotContain("Synthetic", slow.Statement);

        await fixture.Store.FlushAsync(CancellationToken.None);
        var saved = await File.ReadAllTextAsync(fixture.SavedPath);
        Assert.DoesNotContain("Synthetic", saved);

        using (var reopened = new ServerPerformanceStore(fixture.Runtime, fixture.Clock))
        {
            await reopened.LoadAsync(CancellationToken.None);
            Assert.Equal(20, Assert.Single(reopened.Read().Endpoints).Count);
            Assert.Single(reopened.Read().SlowQueries);
        }

        fixture.Clock.Advance(TimeSpan.FromDays(8));
        await fixture.Store.FlushAsync(CancellationToken.None);
        Assert.Empty(fixture.Store.Read().Endpoints);
        Assert.Empty(fixture.Store.Read().SlowQueries);
    }

    [Fact]
    public void EndpointsAndSlowQueriesStayBounded()
    {
        using var fixture = new Fixture();
        for (var index = 0; index < ServerPerformanceStore.MaximumEndpoints + 50; index++)
            fixture.Store.RecordRequest($"GET /api/v1/synthetic/{index}", 1, 200, 0);
        for (var index = 0; index < ServerPerformanceStore.MaximumSlowQueries + 50; index++)
            fixture.Store.RecordQuery(150, "SELECT ?", null);
        var read = fixture.Store.Read();
        Assert.Equal(ServerPerformanceStore.MaximumEndpoints, read.Endpoints.Count);
        Assert.Equal(ServerPerformanceStore.MaximumSlowQueries, read.SlowQueries.Count);
        fixture.Store.Reset();
        Assert.Empty(fixture.Store.Read().Endpoints);
        Assert.Empty(fixture.Store.Read().SlowQueries);
    }

    [Theory]
    [InlineData("/api/v1/home", "", true)]
    [InlineData("/api/v1/streams/abc/live", "", false)]
    [InlineData("/api/v1/sync/changes", "?after=1&waitSeconds=25", false)]
    [InlineData("/api/v1/watch-together/abc", "?after=1&waitMs=20000", false)]
    [InlineData("/api/v1/watch-together/abc", "?after=1&waitMs=0", true)]
    [InlineData("/api/v1/devices/player/commands", "?deviceId=x", false)]
    [InlineData("/api/v1/server/backups/uploads/abc", "", false)]
    [InlineData("/web/app.js", "", false)]
    public void LongRunningRequestsAreNotTimed(string path, string query, bool measured)
    {
        var context = new DefaultHttpContext();
        context.Request.Path = path;
        context.Request.QueryString = new QueryString(query);
        Assert.Equal(measured, ServerPerformanceStore.Measures(context.Request));
    }

    [Fact]
    public async Task OwnersAndAdministratorsReadMeasurementsAndOnlyTheOwnerResetsThem()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using (var homeRequest = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/home", owner.Token))
        using (var response = await client.SendAsync(homeRequest))
            response.EnsureSuccessStatusCode();
        using (var sync = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/sync/changes?after=0&waitSeconds=1", owner.Token))
        using (var response = await client.SendAsync(sync))
            response.EnsureSuccessStatusCode();

        ServerPerformanceResponse performance;
        using (var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/health/performance", owner.Token))
        using (var response = await client.SendAsync(request))
        {
            response.EnsureSuccessStatusCode();
            performance = await ApiTestClient.ReadAsync<ServerPerformanceResponse>(response);
        }
        var home = Assert.Single(performance.Endpoints, value => value.Route == "/api/v1/home");
        Assert.Equal("GET", home.Method);
        Assert.True(home.QueriesPerRequest > 0);
        Assert.DoesNotContain(performance.Endpoints, value => value.Route.StartsWith("/api/v1/sync", StringComparison.Ordinal));
        Assert.Equal(ServerPerformanceStore.SlowQueryMilliseconds, performance.SlowQueryMilliseconds);

        using (var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                   new CreateUserRequest("performance-viewer", "synthetic viewer password", UserRole.User, ApiTestClient.TestPin)))
        using (var response = await ApiTestClient.SendAsync(client, create))
            response.EnsureSuccessStatusCode();
        AuthenticationResponse viewer;
        using (var login = await ApiTestClient.LoginAsync(client, new LoginRequest("performance-viewer", "synthetic viewer password", "Synthetic Viewer")))
        {
            login.EnsureSuccessStatusCode();
            viewer = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
        }
        using (var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/health/performance", viewer.Token))
        using (var response = await client.SendAsync(request))
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        using (var request = ApiTestClient.Authorized(HttpMethod.Delete, "/api/v1/server/health/performance", viewer.Token))
        using (var response = await client.SendAsync(request))
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        using (var request = ApiTestClient.Authorized(HttpMethod.Delete, "/api/v1/server/health/performance", owner.Token))
        using (var response = await client.SendAsync(request))
            Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.DoesNotContain(factory.Services.GetRequiredService<ServerPerformanceStore>().Read().Endpoints,
            value => value.Route == "/api/v1/home");

        using (var export = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/diagnostics/export", owner.Token))
        using (var response = await client.SendAsync(export))
        {
            response.EnsureSuccessStatusCode();
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            Assert.True(document.RootElement.TryGetProperty("performance", out _));
        }
    }

    private sealed class Fixture : IDisposable
    {
        public Fixture()
        {
            Directory.CreateDirectory(Root);
            Runtime = new ServerRuntimeOptions(Root, Path.Combine(Root, "unused.db"),
                "http://127.0.0.1:43110", "Synthetic Performance", false, 43111,
                Path.Combine(Root, "unused.pem"), Path.Combine(Root, "unused-key.pem"), null);
            Store = new ServerPerformanceStore(Runtime, Clock);
        }

        public string Root { get; } = TestPaths.CreateDataDirectory();
        public string SavedPath => Path.Combine(Root, "server-performance.json");
        public ServerRuntimeOptions Runtime { get; }
        public MutableClock Clock { get; } = new();
        public ServerPerformanceStore Store { get; }

        public void Dispose()
        {
            Store.Dispose();
            if (Directory.Exists(Root)) Directory.Delete(Root, recursive: true);
        }
    }

    private sealed class MutableClock : TimeProvider
    {
        private DateTimeOffset current = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => current;
        public void Advance(TimeSpan duration) => current += duration;
    }
}
