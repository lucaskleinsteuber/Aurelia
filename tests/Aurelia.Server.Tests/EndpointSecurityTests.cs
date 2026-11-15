using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class EndpointSecurityTests
{
    /// <summary>
    /// Every endpoint requires sign-in unless it is listed here on purpose. Adding an anonymous
    /// endpoint therefore needs a deliberate change to this list.
    /// </summary>
    private static readonly string[] IntentionallyAnonymous =
    [
        "GET /api/v1/capabilities",
        "GET /api/v1/health",
        "GET /api/v1/health/ready",
        // Home Assistant and shortcuts: each checks an integration key with its own scope.
        "GET /api/v1/integration/players",
        "GET /api/v1/integration/search",
        "GET /api/v1/integration/status",
        "GET /api/v1/integration/titles/{id:guid}/episode",
        "GET /api/v1/integration/titles/{id:guid}/next",
        "GET /api/v1/server/info",
        "GET,HEAD /api/v1/health/live",
        "POST /api/v1/auth/device-pairings/",
        "POST /api/v1/auth/device-pairings/{id:guid}/ack",
        "POST /api/v1/auth/device-pairings/{id:guid}/cancel",
        "POST /api/v1/auth/device-pairings/{id:guid}/status",
        "POST /api/v1/auth/login",
        "POST /api/v1/auth/pair",
        "POST /api/v1/integration/players/{deviceId}/commands",
        "POST /api/v1/integration/power",
        "POST /api/v1/local/owner-pin",
        "POST /api/v1/setup/owner",
        // Moving a server (docs/SERVER_MOVE.md): between the two servers the move code and the
        // bundle's token are the credentials; on a new server without an owner, the setup code
        // or an app host's bootstrap token.
        "GET /api/v1/move/hello",
        "POST /api/v1/move/claim",
        "POST /api/v1/move/arrived",
        "GET /api/v1/setup/move/",
        "DELETE /api/v1/setup/move/",
        "POST /api/v1/setup/move/network",
        "PUT /api/v1/setup/move/file",
        "POST /api/v1/setup/move/file/{uploadId:guid}/open",
        "POST /api/v1/setup/move/locations/preview",
        "POST /api/v1/setup/move/finish",
        // The browser app: its files, and the sign-in steps before a device credential exists.
        "GET,HEAD /web/{**file}",
        "GET,HEAD /web/v/{version}/{**file}",
        "GET,HEAD {**path}",
        "POST /api/v1/web/pair",
        "GET /api/v1/web/setup",
        "POST /api/v1/web/setup",
        "POST /api/v1/web/pairing",
        "POST /api/v1/web/pairing/cancel",
        "POST /api/v1/web/pairing/status",
        "POST /api/v1/web/profile/end",
        "POST /api/v1/web/sign-out",
    ];

    [Fact]
    public void OnlyTheIntendedEndpointsAllowAnonymousAccess()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var anonymous = factory.Services.GetRequiredService<EndpointDataSource>().Endpoints
            .OfType<RouteEndpoint>()
            .Where(endpoint => endpoint.Metadata.GetOrderedMetadata<IAuthorizeData>().Count == 0)
            .Select(endpoint =>
                $"{string.Join(',', endpoint.Metadata.GetMetadata<HttpMethodMetadata>()?.HttpMethods ?? [])} {endpoint.RoutePattern.RawText}")
            .Order(StringComparer.Ordinal)
            .ToArray();
        Assert.Equal(IntentionallyAnonymous.Order(StringComparer.Ordinal), anonymous);
    }

    [Fact]
    public async Task ResponsesCarrySecurityHeadersAndNoServerName()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        using var info = await client.GetAsync("/api/v1/server/info");
        info.EnsureSuccessStatusCode();
        Assert.Equal("nosniff", Assert.Single(info.Headers.GetValues("X-Content-Type-Options")));
        Assert.Equal("DENY", Assert.Single(info.Headers.GetValues("X-Frame-Options")));
        Assert.Equal("no-referrer", Assert.Single(info.Headers.GetValues("Referrer-Policy")));
        Assert.Contains("frame-ancestors 'none'", Assert.Single(info.Headers.GetValues("Content-Security-Policy")));
        Assert.True(info.Headers.CacheControl?.NoStore);
        Assert.False(info.Headers.Contains("Server"));

        // Errors carry the same headers and no details.
        using var missing = await client.GetAsync("/api/v1/does-not-exist");
        Assert.Equal(System.Net.HttpStatusCode.NotFound, missing.StatusCode);
        Assert.Equal("nosniff", Assert.Single(missing.Headers.GetValues("X-Content-Type-Options")));
        Assert.Empty(await missing.Content.ReadAsByteArrayAsync());
    }
}
