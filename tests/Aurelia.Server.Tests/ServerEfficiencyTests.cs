using System.Net;
using System.Net.Http.Headers;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerEfficiencyTests
{
    [Fact]
    public async Task CatalogListsAcceptLargePagesAndAreTheOnlyCompressedResponses()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var capabilities = await client.GetAsync("/api/v1/capabilities");
        var features = (await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities)).Capabilities;
        Assert.Contains("catalog-pages-500-v1", features);
        Assert.Contains("preview-streams-v1", features);

        foreach (var path in new[] { "/api/v1/catalog/items", "/api/v1/catalog/movies", "/api/v1/catalog/series" })
        {
            using var large = Request($"{path}?offset=0&limit=500", owner.Token);
            using var accepted = await client.SendAsync(large);
            Assert.Equal(HttpStatusCode.OK, accepted.StatusCode);
            Assert.Contains("br", accepted.Content.Headers.ContentEncoding);
            using var tooLarge = Request($"{path}?offset=0&limit=501", owner.Token);
            using var rejected = await client.SendAsync(tooLarge);
            Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);
        }

        using var home = Request("/api/v1/home", owner.Token);
        using var homeResponse = await client.SendAsync(home);
        Assert.Equal(HttpStatusCode.OK, homeResponse.StatusCode);
        Assert.Contains("br", homeResponse.Content.Headers.ContentEncoding);
        foreach (var path in new[] { "/api/v1/watchlist", "/api/v1/history" })
        {
            using var list = Request(path, owner.Token);
            using var listResponse = await client.SendAsync(list);
            Assert.True(listResponse.IsSuccessStatusCode, path);
            Assert.Contains("br", listResponse.Content.Headers.ContentEncoding);
        }

        // Responses that can carry credentials or personal state stay uncompressed.
        foreach (var path in new[] { "/api/v1/auth/me", "/api/v1/auth/sessions", "/api/v1/capabilities" })
        {
            using var request = Request(path, owner.Token);
            using var response = await client.SendAsync(request);
            Assert.True(response.IsSuccessStatusCode, path);
            Assert.Empty(response.Content.Headers.ContentEncoding);
        }
    }

    [Fact]
    public async Task DatabaseConnectionsUseNormalSynchronisationInWalMode()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        _ = await ApiTestClient.SetupOwnerAsync(client);
        await using var scope = factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        await database.Database.OpenConnectionAsync();
        try
        {
            await using var command = database.Database.GetDbConnection().CreateCommand();
            command.CommandText = "PRAGMA journal_mode;";
            Assert.Equal("wal", await command.ExecuteScalarAsync());
            command.CommandText = "PRAGMA synchronous;";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
        }
        finally
        {
            await database.Database.CloseConnectionAsync();
        }
    }

    [Fact]
    public void FloodGuardAllowsBrowsingThousandsOfPostersButStillStopsFloods()
    {
        var guard = new Aurelia.Server.Services.ServerRequestGuard();
        var address = System.Net.IPAddress.Parse("192.168.1.20");
        for (var request = 0; request < Aurelia.Server.Services.ServerRequestGuard.RequestsPerMinute; request++)
            Assert.True(guard.Admit(address));
        Assert.False(guard.Admit(address));
        Assert.True(guard.Admit(System.Net.IPAddress.Parse("192.168.1.21")));
    }

    // A device in the home network can use thousands of IPv6 addresses and fill the table of
    // addresses. The server computer itself, where the owner repairs things, still gets in.
    [Fact]
    public void AFullAddressTableStillAdmitsTheServerComputer()
    {
        var guard = new Aurelia.Server.Services.ServerRequestGuard();
        for (var host = 0; host < 4_096; host++)
            Assert.True(guard.Admit(System.Net.IPAddress.Parse($"fd00::{host + 1:x}")));
        Assert.False(guard.Admit(System.Net.IPAddress.Parse("fd00::ffff")));
        Assert.True(guard.Admit(System.Net.IPAddress.Loopback));
        Assert.True(guard.Admit(System.Net.IPAddress.IPv6Loopback));
        Assert.True(guard.Admit(System.Net.IPAddress.Loopback.MapToIPv6()));
        Assert.True(guard.Admit(null));
    }

    [Fact]
    public void PreviewBurstsCountApartAndStillHaveALimit()
    {
        var guard = new Aurelia.Server.Services.ServerRequestGuard();
        var address = System.Net.IPAddress.Parse("192.168.1.30");
        for (var request = 0; request < Aurelia.Server.Services.ServerRequestGuard.PreviewRequestsPerMinute; request++)
            Assert.True(guard.Admit(address, preview: true));
        Assert.False(guard.Admit(address, preview: true));
        // Browsing and playback from the same device are unaffected by the burst.
        Assert.True(guard.Admit(address));

        var context = new Microsoft.AspNetCore.Http.DefaultHttpContext();
        context.Request.Path = "/api/v1/streams/ticket";
        Assert.False(Aurelia.Server.Services.ServerRequestGuard.IsPreviewStream(context.Request));
        context.Request.Headers["X-Aurelia-Stream-Purpose"] = "Preview";
        Assert.True(Aurelia.Server.Services.ServerRequestGuard.IsPreviewStream(context.Request));
        // The marker means nothing outside stream reads.
        context.Request.Path = "/api/v1/media";
        Assert.False(Aurelia.Server.Services.ServerRequestGuard.IsPreviewStream(context.Request));
    }

    private static HttpRequestMessage Request(string path, string token)
    {
        var request = ApiTestClient.Authorized(HttpMethod.Get, path, token);
        request.Headers.AcceptEncoding.Add(new StringWithQualityHeaderValue("br"));
        request.Headers.AcceptEncoding.Add(new StringWithQualityHeaderValue("gzip"));
        return request;
    }
}
