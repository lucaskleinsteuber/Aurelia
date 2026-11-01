using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Settings;
using Avalonia.Headless.XUnit;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class HomeRefreshTests
{
    private static string Home(DateTimeOffset deadline) =>
        JsonSerializer.Serialize(new HomeResponse(null, [], [], [], [], deadline), AureliaJson.Options);

    private sealed class HeldHomeTransport(FakeServer server) : IServerTransport
    {
        public bool HoldNextHome { get; set; }
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public HttpClient CreateClient(Uri address, string? expectedFingerprint, CapturedFingerprint? captured, TimeSpan timeout) =>
            new(new Handler(this, server.CreateClient(address, expectedFingerprint, captured, timeout))) { BaseAddress = address, Timeout = timeout };

        private sealed class Handler(HeldHomeTransport owner, HttpClient inner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                var hold = request.RequestUri!.AbsolutePath == "/api/v1/home" && owner.HoldNextHome;
                if (hold) owner.HoldNextHome = false;
                using var forwarded = new HttpRequestMessage(request.Method, request.RequestUri);
                foreach (var header in request.Headers) forwarded.Headers.TryAddWithoutValidation(header.Key, header.Value);
                var response = await inner.SendAsync(forwarded, cancellationToken);
                if (hold)
                {
                    owner.Entered.TrySetResult();
                    await owner.Release.Task.WaitAsync(cancellationToken);
                }
                return response;
            }

            protected override void Dispose(bool disposing)
            {
                if (disposing) inner.Dispose();
                base.Dispose(disposing);
            }
        }
    }

    private static LibraryStore Store(AureliaApi api)
    {
        var server = new StoredServer(FakeServer.ServerId, "Synthetic Server", new Uri("https://192.0.2.10:43111"), FakeServer.Fingerprint,
            "synthetic-device-token-0000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(1));
        var profile = new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Owner", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
            "synthetic-profile-token-00000000000001", DateTimeOffset.UtcNow.AddHours(1));
        return new LibraryStore(new LibraryClient(api, server, profile, []), new ArtworkCache(null), new GeneralPreferences(new MemorySettingsStore()),
            _ => throw new InvalidOperationException("No session failure was expected."));
    }

    [Fact]
    public async Task AStaleHomeResponseCannotReplaceANewerFullSnapshot()
    {
        var server = FakeLibrary.Create(watchlist: false, pictures: false);
        var transport = new HeldHomeTransport(server);
        using var api = new AureliaApi(transport);
        var store = Store(api);
        await store.RefreshAsync();
        var earlier = DateTimeOffset.UtcNow.AddMinutes(10);
        var later = earlier.AddMinutes(10);
        server.Replace("GET", "/api/v1/home", Home(earlier));
        transport.HoldNextHome = true;
        var old = store.RefreshHomeAsync(TestContext.Current.CancellationToken);
        await transport.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        server.Replace("GET", "/api/v1/home", Home(later));
        await store.RefreshAsync();
        transport.Release.TrySetResult();
        await old;
        Assert.Equal(later, store.Home!.RecommendationChangesAt);
    }

    [Fact]
    public async Task AHomeRefreshDuringASnapshotIsDeferredUntilTheSnapshotFinishes()
    {
        var server = FakeLibrary.Create(watchlist: false, pictures: false);
        var transport = new HeldHomeTransport(server);
        using var api = new AureliaApi(transport);
        var store = Store(api);
        await store.RefreshAsync();
        var earlier = DateTimeOffset.UtcNow.AddMinutes(10);
        var later = earlier.AddMinutes(10);
        server.Replace("GET", "/api/v1/home", Home(earlier));
        transport.HoldNextHome = true;
        var full = store.RefreshAsync();
        await transport.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        server.Replace("GET", "/api/v1/home", Home(later));
        await store.RefreshHomeAsync(TestContext.Current.CancellationToken);
        transport.Release.TrySetResult();
        await full;
        Assert.Equal(later, store.Home!.RecommendationChangesAt);
        Assert.False(store.IsLoading);
    }

    [AvaloniaFact]
    public void RecommendationsRefreshAtTheirDeadlineWithoutASyncChangeAndStopAtRest()
    {
        var time = new ManualTime();
        var server = FakeLibrary.Create(pictures: false).Replace("GET", "/api/v1/home", Home(time.GetUtcNow().AddSeconds(10)));
        var window = FakeLibrary.ShowLibrary(server, time: time);
        var before = server.Requests.Count(r => r == "GET /api/v1/home");
        var next = time.GetUtcNow().AddHours(1);
        server.Replace("GET", "/api/v1/home", Home(next));
        time.Advance(TimeSpan.FromSeconds(9));
        FakeLibrary.Pump(() => false, rounds: 5);
        Assert.Equal(before, server.Requests.Count(r => r == "GET /api/v1/home"));
        time.Advance(TimeSpan.FromSeconds(2));
        FakeLibrary.Pump(() => window.Session.Library!.Home?.RecommendationChangesAt == next);
        Assert.Equal(next, window.Session.Library!.Home!.RecommendationChangesAt);
        Assert.Equal(before + 1, server.Requests.Count(r => r == "GET /api/v1/home"));
        window.Session.Rest();
        time.Advance(TimeSpan.FromHours(2), TimeSpan.FromMinutes(1));
        FakeLibrary.Pump(() => false, rounds: 5);
        Assert.Equal(before + 1, server.Requests.Count(r => r == "GET /api/v1/home"));
        window.Close();
    }

    [AvaloniaFact]
    public void AHomeChangeReschedulesAnEarlierRecommendationDeadline()
    {
        var time = new ManualTime();
        var server = FakeLibrary.Create(pictures: false).Replace("GET", "/api/v1/home", Home(time.GetUtcNow().AddHours(1)));
        var window = FakeLibrary.ShowLibrary(server, time: time);
        server.Replace("GET", "/api/v1/home", Home(time.GetUtcNow().AddSeconds(5)));
        var refresh = window.Session.Library!.RefreshHomeAsync(TestContext.Current.CancellationToken);
        FakeLibrary.Pump(() => refresh.IsCompleted);
        refresh.GetAwaiter().GetResult();
        FakeLibrary.Pump(() => false, rounds: 5);
        var before = server.Requests.Count(r => r == "GET /api/v1/home");
        var next = time.GetUtcNow().AddHours(2);
        server.Replace("GET", "/api/v1/home", Home(next));
        time.Advance(TimeSpan.FromSeconds(6));
        FakeLibrary.Pump(() => window.Session.Library!.Home?.RecommendationChangesAt == next);
        Assert.Equal(next, window.Session.Library!.Home!.RecommendationChangesAt);
        Assert.Equal(before + 1, server.Requests.Count(r => r == "GET /api/v1/home"));
        window.Session.Rest();
        window.Close();
    }
}
