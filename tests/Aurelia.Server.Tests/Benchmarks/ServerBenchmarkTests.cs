using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;
using Xunit.Abstractions;

namespace Aurelia.Server.Tests;

/// <summary>
/// Measuring instead of guessing: the paths people use most, over real HTTP with the whole
/// middleware, against a synthetic library of 400 series with 50 episodes each (20,000 episodes)
/// and 5,000 movies. Each path has two limits in <c>Benchmarks/limits.json</c>: the database
/// queries one request may run (exact, so a new query per item fails at once) and the median of
/// five runs after a warm-up (generous, about three times what a Mac measured, so a slower path
/// fails without the test flickering). Run with <c>scripts/test-server-benchmarks.sh</c>.
/// </summary>
public sealed class ServerBenchmarkTests(ITestOutputHelper output)
{
    private const int Series = 400;
    private const int EpisodesPerSeries = 50;
    private const int Movies = 5_000;
    private const int Runs = 5;

    private sealed record Limit(double MaxMilliseconds, double? MaxQueries);

    [BenchmarkFact]
    [Trait("Category", "Benchmark")]
    public async Task CommonPathsStayWithinTheirLimitsWithTwentyThousandEpisodes()
    {
        var limits = LoadLimits();
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var media = Path.Combine(factory.DataDirectory, "SyntheticMedia");
        Directory.CreateDirectory(media);
        var seed = Stopwatch.StartNew();
        await SeedAsync(factory, owner.User.Id, media);
        output.WriteLine($"SERVER_BENCHMARK_SEED {seed.Elapsed.TotalSeconds:F1} s");

        var series = Id(1);
        var episode = Id(Series + 1);
        Guid collection;
        using (var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/collections", owner.Token,
                   new SaveCollectionRequest("Synthetic Box Set", Members: Enumerable.Range(1, 20).Select(index => new CollectionMemberInput(Id(index))).ToArray())))
        using (var response = await client.SendAsync(create))
        {
            response.EnsureSuccessStatusCode();
            collection = (await ApiTestClient.ReadAsync<CollectionSummary>(response)).Id;
        }

        var paths = new (string Name, string Path)[]
        {
            ("home", "/api/v1/home"),
            ("series-page", "/api/v1/catalog/items?kind=series&limit=100"),
            ("movies-deep-page", "/api/v1/catalog/items?kind=movie&limit=100&offset=2000"),
            ("series-detail", $"/api/v1/catalog/items/{series}"),
            ("search", "/api/v1/catalog/search?query=Episode&limit=50"),
            ("history", "/api/v1/history?offset=0&limit=50"),
            ("sync-changes", "/api/v1/sync/changes?after=0"),
            ("playback-plan", $"/api/v1/media/{episode}/playback-plan"),
            ("collection", $"/api/v1/collections/{collection}"),
        };
        var store = factory.Services.GetRequiredService<ServerPerformanceStore>();
        var failures = new List<string>();
        var results = new List<object>();
        foreach (var (name, path) in paths)
        {
            await SendAsync(client, owner.Token, path);
            store.Reset();
            var times = new List<double>();
            for (var run = 0; run < Runs; run++)
            {
                var watch = Stopwatch.StartNew();
                await SendAsync(client, owner.Token, path);
                times.Add(watch.Elapsed.TotalMilliseconds);
            }
            times.Sort();
            var median = times[Runs / 2];
            // The server records a request just after it answered it.
            for (var wait = 0; wait < 25 && store.Read().Endpoints.Sum(value => value.Count) < Runs; wait++)
                await Task.Delay(20);
            // Long polls such as /sync/changes are not timed by the server, so only their time counts.
            var timing = store.Read().Endpoints.SingleOrDefault();
            results.Add(new { name, path, median = Math.Round(median, 1), queries = timing?.QueriesPerRequest, serverP95 = timing?.P95Milliseconds });
            if (!limits.TryGetValue(name, out var limit))
            {
                failures.Add($"{name}: no limit in Benchmarks/limits.json (measured {median:F1} ms, {timing?.QueriesPerRequest} queries).");
                continue;
            }
            if (median > limit.MaxMilliseconds)
                failures.Add($"{name}: {median:F1} ms is above the limit of {limit.MaxMilliseconds} ms.");
            if (timing is not null && limit.MaxQueries is { } maxQueries && timing.QueriesPerRequest > maxQueries)
                failures.Add($"{name}: {timing.QueriesPerRequest} database queries is above the limit of {maxQueries}.");
        }
        output.WriteLine("SERVER_BENCHMARK " + JsonSerializer.Serialize(new { series = Series, episodes = Series * EpisodesPerSeries, movies = Movies, results }));
        Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));
    }

    private static async Task SendAsync(HttpClient client, string token, string path)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, path, token);
        using var response = await client.SendAsync(request);
        Assert.True(response.IsSuccessStatusCode, $"{path} answered {(int)response.StatusCode}.");
        _ = await response.Content.ReadAsByteArrayAsync();
    }

    /// <summary>Series, their episodes and movies written straight into the database, with progress for Home.</summary>
    private static async Task SeedAsync(AureliaServerFactory factory, Guid ownerId, string media)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Synthetic",
            Path = media,
            NormalizedPath = media.ToUpperInvariant(),
            Kind = LibraryKind.Automatic,
            MonitoringEnabled = false,
            Availability = LibraryAvailability.Available,
            CreatedAt = DateTimeOffset.UtcNow,
        };
        database.LibraryRoots.Add(library);
        await database.SaveChangesAsync();
        foreach (var trigger in IncrementalSearchIndex.Triggers())
        {
            var drop = "DROP TRIGGER IF EXISTS " + trigger.Name + ";";
            await database.Database.ExecuteSqlRawAsync(drop);
        }
        var libraryId = library.Id.ToString().ToUpperInvariant();
        const int episodes = Series * EpisodesPerSeries;
        const int lastEpisode = episodes - 1;
        const int lastMovie = Movies - 1;
        const int firstEpisode = Series + 1;
        const int firstMovie = Series + episodes + 1;
        const string guid = "%08X-0000-0000-0000-000000000000";
        await database.Database.ExecuteSqlInterpolatedAsync($"""
            WITH RECURSIVE source(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM source WHERE n < {Series})
            INSERT INTO MediaItems(Id,LibraryRootId,ParentId,Kind,SourcePath,NormalizedSourcePath,DetectedTitle,Category,Availability,CreatedAt,UpdatedAt,ManualSourceBinding,SeasonNumber,EpisodeNumber)
            SELECT printf({guid}, n),{libraryId},NULL,'Series','synthetic/series/'||n,'SYNTHETIC/SERIES/'||n,'Synthetic Series '||n,'','Available',0,0,0,NULL,NULL FROM source;
            """);
        await database.Database.ExecuteSqlInterpolatedAsync($"""
            WITH RECURSIVE source(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM source WHERE n < {lastEpisode})
            INSERT INTO MediaItems(Id,LibraryRootId,ParentId,Kind,SourcePath,NormalizedSourcePath,DetectedTitle,Category,Availability,CreatedAt,UpdatedAt,ManualSourceBinding,SeasonNumber,EpisodeNumber)
            SELECT printf({guid}, {firstEpisode}+n),{libraryId},printf({guid}, 1+(n/{EpisodesPerSeries})),'Episode',
                   'synthetic/episode/'||n,'SYNTHETIC/EPISODE/'||n,'Episode '||(1+(n%{EpisodesPerSeries})),'','Available',0,0,0,1+((n%{EpisodesPerSeries})/10),1+(n%10) FROM source;
            """);
        await database.Database.ExecuteSqlInterpolatedAsync($"""
            WITH RECURSIVE source(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM source WHERE n < {lastMovie})
            INSERT INTO MediaItems(Id,LibraryRootId,ParentId,Kind,SourcePath,NormalizedSourcePath,DetectedTitle,Category,Availability,CreatedAt,UpdatedAt,ManualSourceBinding,SeasonNumber,EpisodeNumber)
            SELECT printf({guid}, {firstMovie}+n),{libraryId},NULL,'Movie','synthetic/movie/'||n,'SYNTHETIC/MOVIE/'||n,'Synthetic Movie '||n,'','Available',n,n,0,NULL,NULL FROM source;
            """);
        await new MediaSearchIndexService(database).RebuildAsync(default);
        foreach (var trigger in IncrementalSearchIndex.Triggers())
            await database.Database.ExecuteSqlRawAsync(trigger.Sql);
        var owner = await database.Users.SingleAsync(user => user.Id == ownerId);
        var now = DateTimeOffset.UtcNow;
        for (var index = 0; index < 300; index++)
        {
            var mediaId = Id(Series + 1 + index * 7);
            database.PlaybackProgress.Add(new PlaybackProgress
            {
                Id = Guid.NewGuid(),
                UserId = owner.Id,
                User = owner,
                MediaItemId = mediaId,
                MediaItem = await database.MediaItems.SingleAsync(item => item.Id == mediaId),
                PositionMilliseconds = 600_000,
                DurationMilliseconds = 2_400_000,
                LastPlayedAt = now.AddMinutes(-index),
                UpdatedAt = now.AddMinutes(-index),
                Revision = 1,
            });
        }
        await database.SaveChangesAsync();
    }

    private static Guid Id(int value) => Guid.Parse($"{value:X8}-0000-0000-0000-000000000000");

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private static Dictionary<string, Limit> LoadLimits([CallerFilePath] string source = "")
    {
        var path = Path.Combine(Path.GetDirectoryName(source)!, "limits.json");
        return JsonSerializer.Deserialize<Dictionary<string, Limit>>(File.ReadAllText(path), Json) ?? [];
    }
}
