using System.Diagnostics;
using System.Security.Claims;
using Tarven.Contracts;
using Tarven.Server.Data;
using Tarven.Server.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Tarven.Server.Tests;

/// <summary>
/// The server side of the browser audit of 16.11.2026: the change feed's start, a title's page
/// with a bounded cast, reads an open page makes by itself, and compressed playback plans.
/// </summary>
public sealed class WebAuditServerTests
{
    /// <summary>
    /// Every app started its feed at 0 and paged through the whole kept history (12 pages on the
    /// owner's server); the Mac reloaded its library once per page. Starting now skips that but
    /// still hears what changed in the last minute (audit W4).
    /// </summary>
    [Fact]
    public async Task AFeedThatStartsNowSkipsTheKeptHistoryButHearsTheLastMinute()
    {
        using var factory = new TarvenServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await using var scope = factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
        var longAgo = DateTimeOffset.UtcNow.AddMinutes(-10);
        for (var index = 0; index < 1_500; index++)
            database.SyncChanges.Add(new SyncChange { Area = SyncChangeArea.Catalog, CreatedAt = longAgo });
        database.SyncChanges.Add(new SyncChange { Area = SyncChangeArea.UserState, UserId = owner.User.Id, CreatedAt = DateTimeOffset.UtcNow });
        await database.SaveChangesAsync();
        var changes = scope.ServiceProvider.GetRequiredService<SyncChangeService>();
        var history = await changes.HistoryAsync(CancellationToken.None);

        var latest = await changes.LatestAsync(owner.User.Id, true, CancellationToken.None);
        Assert.Equal(history.HighWater, latest.Cursor);
        Assert.False(latest.ResetRequired);
        Assert.Equal([SyncChangeArea.UserState], latest.ChangedAreas);
        Assert.Equal(history.Generation, latest.Generation);

        // From 0 the feed still pages, as older apps expect.
        var paged = await changes.ChangesAsync(owner.User.Id, true, 0, 0, CancellationToken.None);
        Assert.True(paged.Cursor < history.HighWater);

        // The endpoint answers at once instead of waiting, and its cursor continues normally.
        var watch = Stopwatch.StartNew();
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/sync/changes?after=0&waitSeconds=25&latest=true", owner.Token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        var answer = await ApiTestClient.ReadAsync<SyncChangesResponse>(response);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10));
        Assert.Equal(history.HighWater, answer.Cursor);
        var next = await changes.ChangesAsync(owner.User.Id, true, answer.Cursor, 0, answer.Generation, CancellationToken.None);
        Assert.False(next.ResetRequired);
        Assert.Empty(next.ChangedAreas);
    }

    /// <summary>A long series' page lists 50 actors and the key crew; the editor keeps everyone (audit W5, M1).</summary>
    [Fact]
    public void ATitlesPageListsFiftyActorsAndTheKeyCrew()
    {
        List<CreditSummary> credits = [];
        for (var index = 0; index < 70; index++)
            credits.Add(new CreditSummary($"Actor {index}", "Acting", null, $"Role {index}", index, null, Guid.NewGuid(), $"tmdb:person:{index}"));
        credits.Add(new CreditSummary("Grip Person", "Crew", "Key Grip", null, 0, null, Guid.NewGuid(), "tmdb:person:grip"));
        for (var index = 0; index < 20; index++)
            credits.Add(new CreditSummary($"Producer {index}", "Production", "Executive Producer", null, index, null, Guid.NewGuid(), $"tmdb:person:producer-{index}"));
        credits.Add(new CreditSummary("The Creator", "Writing", "Creator", null, 5, null, Guid.NewGuid(), "tmdb:person:creator"));
        // An actor who also directs keeps both credits.
        credits.Add(new CreditSummary("Actor 3", "Directing", "Director", null, 1, null, Guid.NewGuid(), "tmdb:person:3"));
        var metadata = Metadata(credits);

        var page = MetadataPresentation.ForPage(metadata);

        var actors = page.Credits.Where(credit => credit.Department == "Acting").Select(credit => credit.PersonKey).Distinct().ToList();
        Assert.Equal(MetadataPresentation.ShownCast, actors.Count);
        Assert.Equal(Enumerable.Range(0, 50).Select(index => $"tmdb:person:{index}"), actors);
        var crew = page.Credits.Where(credit => credit.Department != "Acting").ToList();
        Assert.DoesNotContain(crew, credit => credit.Job == "Key Grip");
        Assert.Contains(page.Credits, credit => credit.Job == "Creator");
        Assert.Contains(page.Credits, credit => credit.PersonKey == "tmdb:person:3" && credit.Job == "Director");
        Assert.True(crew.Select(credit => credit.PersonKey).Distinct().Count() <= MetadataPresentation.ShownCrew);
        Assert.Equal(93, metadata.Credits.Count);

        var small = Metadata(credits.Take(10).ToList());
        Assert.Same(small, MetadataPresentation.ForPage(small));
    }

    /// <summary>Reads an open page makes by itself don't keep a server with power saving awake (audit W7, L6, S15).</summary>
    [Theory]
    [InlineData("GET", "/api/v1/server/file-checks", true, false)]
    [InlineData("GET", "/api/v1/home", true, false)]
    [InlineData("GET", "/api/v1/home", false, true)]
    [InlineData("PUT", "/api/v1/server/file-checks", true, true)]
    [InlineData("GET", "/api/v1/devices/players/00000000-0000-0000-0000-000000000001/status", false, false)]
    [InlineData("POST", "/api/v1/devices/players/00000000-0000-0000-0000-000000000001/commands", false, true)]
    public void ReadsAPageMakesByItselfDoNotCountAsUse(string method, string path, bool background, bool expected)
    {
        var context = new DefaultHttpContext();
        context.Request.Method = method;
        context.Request.Path = path;
        if (background) context.Request.Headers[ServerUseClock.BackgroundHeader] = "1";
        context.User = new ClaimsPrincipal(new ClaimsIdentity([new Claim("sub", "synthetic")], "Test"));
        Assert.Equal(expected, ServerUseClock.CountsAsUse(context));
    }

    /// <summary>A series' playback plan lists every episode (61 KB for Better Call Saul) and goes out compressed (audit W5).</summary>
    [Theory]
    [InlineData("GET", "/api/v1/media/00000000-0000-0000-0000-000000000001/playback-plan", true)]
    [InlineData("POST", "/api/v1/media/00000000-0000-0000-0000-000000000001/playback-plan", false)]
    [InlineData("GET", "/api/v1/media/00000000-0000-0000-0000-000000000001/editor", false)]
    [InlineData("GET", "/api/v1/catalog/items/00000000-0000-0000-0000-000000000001", true)]
    public void PlaybackPlansAreCompressed(string method, string path, bool expected)
    {
        var context = new DefaultHttpContext();
        context.Request.Method = method;
        context.Request.Path = path;
        Assert.Equal(expected, CatalogCompression.Applies(context));
    }

    private static MediaMetadataSummary Metadata(IReadOnlyList<CreditSummary> credits) => new(
        Guid.NewGuid(), "Invented Series", null, null, null, 2020, null, null, null, [], [], [], credits,
        null, null, null, "tmdb", "1", MetadataReviewState.Matched);
}
