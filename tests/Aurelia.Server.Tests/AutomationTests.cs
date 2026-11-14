using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Aurelia.Server.Services.Automation;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>Smart Home: players' state, signed webhooks with retries, integration keys and power.</summary>
public sealed class AutomationTests
{
    // MARK: What a change of state sends

    [Theory]
    [InlineData("opened", "playing", false, AutomationEvents.PlaybackStarted)]
    [InlineData("opened", "buffering", false, null)]
    [InlineData("buffering", "playing", false, AutomationEvents.PlaybackStarted)]
    [InlineData("buffering", "playing", true, null)]
    [InlineData("playing", "paused", true, AutomationEvents.PlaybackPaused)]
    [InlineData("paused", "playing", true, AutomationEvents.PlaybackResumed)]
    [InlineData("playing", "playing", true, null)]
    [InlineData("opened", "paused", false, null)]
    [InlineData("playing", "finished", true, AutomationEvents.PlaybackFinished)]
    [InlineData("finished", "stopped", true, null)]
    [InlineData("paused", "stopped", true, AutomationEvents.PlaybackStopped)]
    [InlineData("opened", "stopped", false, null)]
    public void OnlyRealChangesSendAnEvent(string previous, string next, bool started, string? expected) =>
        Assert.Equal(expected, PlaybackActivityTracker.Transition(previous, next, started));

    [Fact]
    public void TheSignatureIsAnHmacOfTheTimeAndTheBody()
    {
        var header = WebhookSigner.Sign("whsec_synthetic", 1_700_000_000, """{"event":"test"}""");
        var expected = Convert.ToHexStringLower(HMACSHA256.HashData(Encoding.UTF8.GetBytes("whsec_synthetic"),
            Encoding.UTF8.GetBytes("""1700000000.{"event":"test"}""")));
        Assert.Equal($"t=1700000000,v1={expected}", header);
        Assert.StartsWith("whsec_", WebhookSigner.CreateSecret(), StringComparison.Ordinal);
        Assert.NotEqual(WebhookSigner.CreateSecret(), WebhookSigner.CreateSecret());
    }

    [Theory]
    [InlineData("http://homeassistant.local:8123/api/webhook/abc", true)]
    [InlineData("http://10.0.0.20:8123/api/webhook/abc", true)]
    [InlineData("http://127.0.0.1:8123/api/webhook/abc", true)]
    [InlineData("http://homeassistant:8123/api/webhook/abc", true)]
    [InlineData("https://hooks.example.com/aurelia", true)]
    [InlineData("http://hooks.example.com/aurelia", false)]
    [InlineData("http://203.0.113.5/hook", false)]
    [InlineData("https://169.254.169.254/latest/meta-data", false)]
    [InlineData("https://[fe80::1]/hook", false)]
    [InlineData("https://user:secret@hooks.example.com/aurelia", false)]
    [InlineData("ftp://hooks.example.com/aurelia", false)]
    [InlineData("not a url", false)]
    public void WebhooksGoOverHttpsOrStayAtHome(string url, bool allowed) =>
        Assert.Equal(allowed, WebhookTargetPolicy.Problem(url) is null);

    // MARK: End to end

    [Fact]
    public async Task APlayerReportsAndTheWebhookGetsSignedEventsInOrder()
    {
        var root = Directory.CreateDirectory(Path.Combine(TestPaths.CreateDataDirectory(), "Automation")).FullName;
        var receiver = new Receiver();
        try
        {
            using var factory = Factory(receiver);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var media = await AddMovieAsync(factory, root);
            var created = await CreateWebhookAsync(client, owner.Token,
                [AutomationEvents.PlaybackStarted, AutomationEvents.PlaybackPaused, AutomationEvents.PlaybackResumed, AutomationEvents.PlaybackStopped]);

            var ticket = await OpenAsync(client, owner.Token, media);
            await ReportAsync(client, owner.Token, ticket, "buffering");
            await ReportAsync(client, owner.Token, ticket, "playing", 3);
            await ReportAsync(client, owner.Token, ticket, "playing", 4);
            await ReportAsync(client, owner.Token, ticket, "paused", 60);
            await ReportAsync(client, owner.Token, ticket, "playing", 60);
            using (var close = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/playback/{ticket}", owner.Token))
            using (var closed = await client.SendAsync(close)) closed.EnsureSuccessStatusCode();

            var received = await receiver.WaitAsync(4);
            Assert.Equal([AutomationEvents.PlaybackStarted, AutomationEvents.PlaybackPaused, AutomationEvents.PlaybackResumed, AutomationEvents.PlaybackStopped],
                received.Select(value => value.Event));
            foreach (var request in received)
            {
                Assert.True(Verify(created.Secret, request), "every delivery is signed with the webhook's secret");
                Assert.Equal(request.Event, request.Headers["X-Aurelia-Event"]);
            }
            using var paused = JsonDocument.Parse(received[1].Body);
            var mediaJson = paused.RootElement.GetProperty("media");
            Assert.Equal("Synthetic Movie", mediaJson.GetProperty("title").GetString());
            Assert.Equal(60, mediaJson.GetProperty("positionSeconds").GetDouble());
            Assert.Equal("Test Mac", paused.RootElement.GetProperty("device").GetProperty("name").GetString());

            // The log keeps outcomes, never the body.
            await WaitForAsync(async () => (await DeliveriesAsync(factory)).Count >= 4);
            Assert.All(await DeliveriesAsync(factory), value =>
            {
                Assert.Equal(AutomationDeliveryStates.Succeeded, value.State);
                Assert.Null(value.Payload);
            });
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task APlayerThatNeverReportsStillStartsAndStops()
    {
        var root = Directory.CreateDirectory(Path.Combine(TestPaths.CreateDataDirectory(), "Automation")).FullName;
        var receiver = new Receiver();
        try
        {
            using var factory = Factory(receiver);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var media = await AddMovieAsync(factory, root);
            await CreateWebhookAsync(client, owner.Token, [AutomationEvents.PlaybackStarted, AutomationEvents.PlaybackStopped]);
            var ticket = await OpenAsync(client, owner.Token, media);
            Assert.Equal(AutomationEvents.PlaybackStarted, Assert.Single(await receiver.WaitAsync(1, TimeSpan.FromSeconds(15))).Event);
            using (var close = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/playback/{ticket}", owner.Token))
            using (var closed = await client.SendAsync(close)) closed.EnsureSuccessStatusCode();
            Assert.Equal(AutomationEvents.PlaybackStopped, (await receiver.WaitAsync(2))[1].Event);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task AFailingReceiverIsTriedAgainThenTheWebhookPauses()
    {
        var root = Directory.CreateDirectory(Path.Combine(TestPaths.CreateDataDirectory(), "Automation")).FullName;
        var receiver = new Receiver(HttpStatusCode.ServiceUnavailable, HttpStatusCode.ServiceUnavailable);
        try
        {
            using var factory = Factory(receiver);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var media = await AddMovieAsync(factory, root);
            var created = await CreateWebhookAsync(client, owner.Token, [AutomationEvents.PlaybackStarted, AutomationEvents.PlaybackPaused]);
            var ticket = await OpenAsync(client, owner.Token, media);
            await ReportAsync(client, owner.Token, ticket, "playing");

            // Two refusals, then delivered on the third attempt.
            var attempts = await receiver.WaitAsync(3);
            Assert.All(attempts, value => Assert.Equal(AutomationEvents.PlaybackStarted, value.Event));
            await WaitForAsync(async () => (await DeliveriesAsync(factory)).Any(value => value.Attempt == 3));
            Assert.Equal(AutomationDeliveryStates.Succeeded, Assert.Single(await DeliveriesAsync(factory)).State);

            // Every attempt fails from now on: after three failed deliveries (the test's limit) it pauses.
            receiver.FailAlways = true;
            for (var round = 0; round < 3; round++)
            {
                await ReportAsync(client, owner.Token, ticket, "paused");
                await ReportAsync(client, owner.Token, ticket, "playing");
            }
            await WaitForAsync(async () => (await OverviewAsync(client, owner.Token)).Webhooks.Single().PausedReason is not null);
            var hook = (await OverviewAsync(client, owner.Token)).Webhooks.Single();
            Assert.Equal(WebhookDispatcher.PausedReason, hook.PausedReason);

            // Saving it again resumes it.
            using var save = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/server/automation/webhooks/{created.Webhook.Id}", owner.Token,
                Request([AutomationEvents.PlaybackStarted]));
            using var saved = await ApiTestClient.SendAsync(client, save);
            saved.EnsureSuccessStatusCode();
            Assert.Null((await OverviewAsync(client, owner.Token)).Webhooks.Single().PausedReason);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task FiltersLeaveOutOtherDevicesChildrenAndTitles()
    {
        var root = Directory.CreateDirectory(Path.Combine(TestPaths.CreateDataDirectory(), "Automation")).FullName;
        var receiver = new Receiver();
        try
        {
            using var factory = Factory(receiver);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var media = await AddMovieAsync(factory, root);
            await CreateWebhookAsync(client, owner.Token, [AutomationEvents.PlaybackStarted],
                Request([AutomationEvents.PlaybackStarted]) with { DeviceIds = [Guid.NewGuid()] });
            await CreateWebhookAsync(client, owner.Token, [AutomationEvents.PlaybackStarted],
                Request([AutomationEvents.PlaybackStarted]) with { Name = "No Titles", IncludeTitles = false });
            var ticket = await OpenAsync(client, owner.Token, media);
            await ReportAsync(client, owner.Token, ticket, "playing");
            var only = Assert.Single(await receiver.WaitAsync(1));
            await Task.Delay(300);
            Assert.Single(receiver.Received);
            using var body = JsonDocument.Parse(only.Body);
            Assert.Equal(string.Empty, body.RootElement.GetProperty("media").GetProperty("title").GetString());
            Assert.False(body.RootElement.TryGetProperty("profile", out _));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task OnlyTheOwnerManagesWebhooksWithApprovalAndItIsLogged()
    {
        var receiver = new Receiver();
        using var factory = Factory(receiver);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // Without the one-time approval nothing is created.
        using var bare = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/automation/webhooks", owner.Token,
            Request([AutomationEvents.PlaybackStarted]));
        using var refused = await client.SendAsync(bare);
        Assert.Equal(HttpStatusCode.Forbidden, refused.StatusCode);

        var created = await CreateWebhookAsync(client, owner.Token, [AutomationEvents.TitleAdded]);
        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var stored = await database.AutomationWebhooks.SingleAsync();
            Assert.DoesNotContain(created.Secret, stored.ProtectedSecret, StringComparison.Ordinal);
        }
        await WaitForAsync(async () =>
        {
            using var scope = factory.Services.CreateScope();
            return await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().SecurityEvents.AnyAsync(value => value.Kind == "webhook_added");
        });

        // A test event arrives at once and reports how long it took.
        using var test = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/server/automation/webhooks/{created.Webhook.Id}/test", owner.Token);
        using var tested = await ApiTestClient.SendAsync(client, test);
        var delivery = await ApiTestClient.ReadAsync<AutomationDeliverySummary>(tested);
        Assert.Equal(AutomationDeliveryStates.Succeeded, delivery.State);
        Assert.NotNull(delivery.DurationMilliseconds);
        Assert.Equal(AutomationEvents.Test, Assert.Single(await receiver.WaitAsync(1)).Event);

        // A new secret replaces the old one.
        using var rotate = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/server/automation/webhooks/{created.Webhook.Id}/secret", owner.Token);
        using var rotated = await ApiTestClient.SendAsync(client, rotate);
        Assert.NotEqual(created.Secret, (await ApiTestClient.ReadAsync<AutomationSecretResponse>(rotated)).Secret);

        // Invalid addresses are refused with a reason.
        using var bad = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/automation/webhooks", owner.Token,
            Request([AutomationEvents.PlaybackStarted]) with { Url = "http://hooks.example.com/aurelia" });
        using var badResponse = await ApiTestClient.SendAsync(client, bad);
        Assert.Equal(HttpStatusCode.BadRequest, badResponse.StatusCode);
        Assert.Equal("invalid_webhook_url", (await ApiTestClient.ReadAsync<ApiProblem>(badResponse)).Code);
    }

    [Fact]
    public async Task AnIntegrationKeyDoesOnlyWhatItsScopesAllow()
    {
        using var factory = Factory(new Receiver());
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/automation/tokens", owner.Token,
            new CreateIntegrationTokenRequest("Home Assistant", [IntegrationScopes.Status]));
        using var createdResponse = await ApiTestClient.SendAsync(client, create);
        var created = await ApiTestClient.ReadAsync<IntegrationTokenCreated>(createdResponse);
        Assert.StartsWith(AutomationStore.TokenPrefix, created.Value, StringComparison.Ordinal);

        using (var status = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/integration/status", created.Value))
        using (var statusResponse = await client.SendAsync(status))
        {
            statusResponse.EnsureSuccessStatusCode();
            Assert.Empty((await ApiTestClient.ReadAsync<IntegrationStatusResponse>(statusResponse)).Playing);
        }
        using (var power = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/integration/power", created.Value, new PowerNowRequest("shutdown")))
        using (var powerResponse = await client.SendAsync(power))
            Assert.Equal(HttpStatusCode.Unauthorized, powerResponse.StatusCode);
        using (var anonymous = await client.GetAsync("/api/v1/integration/status"))
            Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
        // The key is no profile: it opens nothing else.
        using (var library = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/catalog/items", created.Value))
        using (var libraryResponse = await client.SendAsync(library))
            Assert.Equal(HttpStatusCode.Unauthorized, libraryResponse.StatusCode);

        using (var scope = factory.Services.CreateScope())
        {
            var stored = await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().IntegrationTokens.SingleAsync();
            Assert.NotEqual(created.Value, stored.TokenHash);
            Assert.NotNull(stored.LastUsedAt);
        }

        using (var revoke = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/server/automation/tokens/{created.Token.Id}", owner.Token))
        using (var revoked = await ApiTestClient.SendAsync(client, revoke)) revoked.EnsureSuccessStatusCode();
        using (var after = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/integration/status", created.Value))
        using (var afterResponse = await client.SendAsync(after))
            Assert.Equal(HttpStatusCode.Unauthorized, afterResponse.StatusCode);
    }

    [Fact]
    public async Task AServerThatCannotTurnOffSaysSo()
    {
        using var factory = Factory(new Receiver());
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/power/now", owner.Token, new PowerNowRequest("shutdown"));
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal("power_action_unavailable", (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
        Assert.False(File.Exists(Path.Combine(factory.DataDirectory, PowerNowService.FileName)));
        Assert.Empty((await OverviewAsync(client, owner.Token)).PowerActions);
    }

    [Fact]
    public async Task NewTitlesAreAnnouncedOnceAndABigScanOnlyCounts()
    {
        var bus = new AutomationEventBus();
        var services = new ServiceCollection().BuildServiceProvider();
        var announcer = new NewTitleAnnouncer(bus, services.GetRequiredService<IServiceScopeFactory>(), TimeProvider.System);
        announcer.Added(Enumerable.Range(0, NewTitleAnnouncer.MaximumSingle + 1).Select(_ => Guid.NewGuid()).ToList());
        Assert.True(bus.Reader.TryRead(out var summary));
        Assert.Equal(AutomationEvents.TitleAdded, summary!.Kind);
        Assert.Equal(NewTitleAnnouncer.MaximumSingle + 1, summary.Count);
        Assert.Null(summary.Media);
        Assert.False(bus.Reader.TryRead(out _));
    }

    // MARK: Helpers

    private static AureliaServerFactory Factory(Receiver receiver) => new(configureServices: services =>
    {
        services.RemoveAll<AutomationOptions>();
        services.AddSingleton(new AutomationOptions
        {
            PlaybackRetries = [TimeSpan.FromMilliseconds(20), TimeSpan.FromMilliseconds(20), TimeSpan.FromMilliseconds(20)],
            DurableRetries = [TimeSpan.FromMilliseconds(50)],
            DurablePoll = TimeSpan.FromMilliseconds(50),
            PauseAfterFailures = 3,
        });
        services.AddHttpClient(WebhookDispatcher.ClientName).ConfigurePrimaryHttpMessageHandler(() => receiver);
    });

    private static SaveAutomationWebhookRequest Request(IReadOnlyList<string> events) =>
        new("Living Room Lights", "http://homeassistant.local:8123/api/webhook/synthetic", AutomationPresets.HomeAssistant, events);

    private static async Task<AutomationWebhookCreated> CreateWebhookAsync(HttpClient client, string token, IReadOnlyList<string> events,
        SaveAutomationWebhookRequest? request = null)
    {
        using var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/automation/webhooks", token, request ?? Request(events));
        using var response = await ApiTestClient.SendAsync(client, create);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AutomationWebhookCreated>(response);
    }

    private static async Task<AutomationOverview> OverviewAsync(HttpClient client, string token)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/automation", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AutomationOverview>(response);
    }

    private static async Task<Guid> OpenAsync(HttpClient client, string token, Guid media)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{media}/playback", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return (await ApiTestClient.ReadAsync<PlaybackSourceResponse>(response)).Id;
    }

    private static async Task ReportAsync(HttpClient client, string token, Guid ticket, string state, double? position = null)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/playback/{ticket}/state", token,
            new PlaybackStateRequest(state, position));
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
    }

    private static async Task<List<AutomationDelivery>> DeliveriesAsync(AureliaServerFactory factory)
    {
        using var scope = factory.Services.CreateScope();
        return await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().AutomationDeliveries.AsNoTracking().ToListAsync();
    }

    private static async Task WaitForAsync(Func<Task<bool>> condition)
    {
        var until = DateTime.UtcNow.AddSeconds(10);
        while (!await condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("The expected state never came.");
            await Task.Delay(25);
        }
    }

    private static async Task<Guid> AddMovieAsync(AureliaServerFactory factory, string root)
    {
        var path = Path.Combine(root, "Synthetic Movie (2026).mkv");
        await File.WriteAllBytesAsync(path, new byte[4096]);
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Synthetic Movies",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = "Synthetic Movie",
            Category = string.Empty,
            Extension = ".mkv",
            FileSize = 4096,
            FileModifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero),
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
            Year = 2026,
        };
        database.LibraryRoots.Add(library);
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        return media.Id;
    }

    private static bool Verify(string secret, Delivered request)
    {
        var parts = request.Headers["X-Aurelia-Signature"].Split(',');
        var timestamp = long.Parse(parts[0]["t=".Length..], System.Globalization.CultureInfo.InvariantCulture);
        return WebhookSigner.Sign(secret, timestamp, request.Body) == request.Headers["X-Aurelia-Signature"];
    }

    private sealed record Delivered(string Event, string Body, Dictionary<string, string> Headers);

    /// <summary>A stand-in Home Assistant: records what arrives and answers with the given statuses.</summary>
    private sealed class Receiver(params HttpStatusCode[] first) : HttpMessageHandler
    {
        private readonly ConcurrentQueue<HttpStatusCode> answers = new(first);
        private readonly SemaphoreSlim arrived = new(0);
        public ConcurrentQueue<Delivered> Received { get; } = new();
        public bool FailAlways { get; set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = await request.Content!.ReadAsStringAsync(cancellationToken);
            var headers = request.Headers.ToDictionary(header => header.Key, header => string.Join(",", header.Value));
            Received.Enqueue(new Delivered(headers["X-Aurelia-Event"], body, headers));
            arrived.Release();
            var status = FailAlways ? HttpStatusCode.BadGateway : answers.TryDequeue(out var next) ? next : HttpStatusCode.OK;
            return new HttpResponseMessage(status);
        }

        public async Task<IReadOnlyList<Delivered>> WaitAsync(int count, TimeSpan? timeout = null)
        {
            var until = DateTime.UtcNow + (timeout ?? TimeSpan.FromSeconds(10));
            while (Received.Count < count)
            {
                var left = until - DateTime.UtcNow;
                if (left <= TimeSpan.Zero) throw new TimeoutException($"Only {Received.Count} of {count} deliveries arrived.");
                await arrived.WaitAsync(left);
            }
            return Received.ToList();
        }
    }
}
