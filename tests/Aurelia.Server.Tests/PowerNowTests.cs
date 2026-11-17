using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>Sleep, Turn Off or Stop Now in Settings › Power, and Smart Home gone for good.</summary>
public sealed class PowerNowTests
{
    [Fact]
    public async Task AServerThatCannotTurnOffSaysSo()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using (var options = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/power/now", owner.Token))
        using (var listed = await ApiTestClient.SendAsync(client, options))
        {
            Assert.Equal(HttpStatusCode.OK, listed.StatusCode);
            Assert.Empty((await ApiTestClient.ReadAsync<PowerNowOptions>(listed)).Actions);
        }
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/power/now", owner.Token, new PowerNowRequest("shutdown"));
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal("power_action_unavailable", (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
        Assert.False(File.Exists(Path.Combine(factory.DataDirectory, PowerNowService.FileName)));
    }

    [Fact]
    public async Task ServersOfferPowerNowAndNoLongerSmartHome()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using (var capabilities = await client.GetAsync("/api/v1/capabilities"))
        {
            var offered = (await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities)).Capabilities;
            Assert.Contains(ServerFeatures.PowerNow, offered);
            Assert.DoesNotContain("automation-v1", offered);
        }
        // Webhooks, integration keys, Siri's calls and the players' state reports are gone.
        foreach (var (method, path) in new[]
        {
            (HttpMethod.Get, "/api/v1/server/automation"),
            (HttpMethod.Post, "/api/v1/server/automation/tokens"),
            (HttpMethod.Get, "/api/v1/integration/status"),
            (HttpMethod.Post, $"/api/v1/playback/{Guid.NewGuid()}/state"),
        })
        {
            using var gone = ApiTestClient.Authorized(method, path, owner.Token, method == HttpMethod.Post ? new { } : null);
            using var answer = await ApiTestClient.SendAsync(client, gone);
            Assert.True(answer.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed, $"{method} {path}: {answer.StatusCode}");
        }
    }
}
