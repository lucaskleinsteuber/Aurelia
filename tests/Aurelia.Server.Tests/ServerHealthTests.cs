using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerHealthTests
{
    [Fact]
    public void SanitizeCodeStripsDisallowedCharactersAndGuardsAgainstPaths()
    {
        Assert.Equal("valid_event_code_123", ServerHealthService.SanitizeCode("valid_event_code_123"));
        Assert.Equal("invalid_path_code_8080", ServerHealthService.SanitizeCode("invalid/path\\code:8080"));
        Assert.Equal("secret_token_abc", ServerHealthService.SanitizeCode("secret_token_abc$#@!"));
        Assert.Equal("diagnostic_event", ServerHealthService.SanitizeCode("///:::$$$"));
    }

    [Fact]
    public async Task HealthEndpointRequiresAdministratorAndReturnsExpectedMetrics()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();

        // Anonymous call is refused
        using var unauth = await client.GetAsync("/api/v1/server/health");
        Assert.Equal(HttpStatusCode.Unauthorized, unauth.StatusCode);

        // Administrator/Owner call succeeds
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", owner.Token);

        using var response = await client.GetAsync("/api/v1/server/health");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var health = await response.Content.ReadFromJsonAsync<ServerHealthResponse>();
        Assert.NotNull(health);
        Assert.True(health.UptimeSeconds >= 0);
        Assert.NotNull(health.BackgroundJobs);
        Assert.NotNull(health.RecentIssues);
        Assert.NotNull(health.Backup);
        Assert.True(health.Backup.Enabled);

        // Issues must never leak file paths or secrets
        foreach (var issue in health.RecentIssues)
        {
            Assert.DoesNotContain("/", issue.Code);
            Assert.DoesNotContain("\\", issue.Code);
            Assert.DoesNotContain(":", issue.Code);
            Assert.True(issue.Severity is "warning" or "error");
        }
    }
}
