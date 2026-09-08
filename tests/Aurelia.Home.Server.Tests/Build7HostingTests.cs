using System.Net;
using System.Net.Http.Json;
using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Services;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace Aurelia.Home.Server.Tests;

public sealed class Build7HostingTests
{
    [Fact]
    public async Task OwnerSetupRejectsMissingAndIncorrectBootstrapSecrets()
    {
        using var factory = new AureliaHomeServerFactory();
        using var client = factory.CreateClient();

        using var missing = await client.PostAsJsonAsync(
            "/api/v1/setup/owner",
            new SetupOwnerRequest("lucas", "correct horse battery staple", "Test Mac"),
            ApiTestClient.JsonOptions);
        Assert.Equal(HttpStatusCode.Forbidden, missing.StatusCode);

        using var wrongRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/setup/owner");
        wrongRequest.Headers.Add("X-Aurelia-Bootstrap-Token", "not-the-bootstrap-token");
        wrongRequest.Content = JsonContent.Create(
            new SetupOwnerRequest("lucas", "correct horse battery staple", "Test Mac"),
            options: ApiTestClient.JsonOptions);
        using var wrong = await client.SendAsync(wrongRequest);
        Assert.Equal(HttpStatusCode.Forbidden, wrong.StatusCode);
    }

    [Fact]
    public void PersistedHostSettingsAreUsedAndExplicitArgumentsWin()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        try
        {
            Directory.CreateDirectory(dataDirectory);
            File.WriteAllText(
                Path.Combine(dataDirectory, ServerHostSettings.FileName),
                """
                {"version":1,"serverName":"Living Room","lanAccessEnabled":true,"lanHttpsPort":44111}
                """);
            var configuration = new ConfigurationBuilder().Build();
            var persisted = ServerRuntimeOptions.Resolve(
                configuration,
                ["run", "--data-dir", dataDirectory]);
            Assert.Equal("Living Room", persisted.ServerName);
            Assert.True(persisted.LanAccessEnabled);
            Assert.Equal(44111, persisted.LanHttpsPort);

            var loopbackOverride = ServerRuntimeOptions.Resolve(
                new ConfigurationBuilder().AddInMemoryCollection(
                    new Dictionary<string, string?>
                    {
                        ["AureliaHome:LanAccessEnabled"] = "false",
                    }).Build(),
                ["run", "--data-dir", dataDirectory]);
            Assert.False(loopbackOverride.LanAccessEnabled);

            var overridden = ServerRuntimeOptions.Resolve(
                configuration,
                [
                    "run", "--data-dir", dataDirectory, "--lan-port", "45111",
                    "--host-parent-pid",
                    Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                ]);
            Assert.Equal(45111, overridden.LanHttpsPort);
            Assert.Equal(Environment.ProcessId, overridden.HostParentProcessId);
        }
        finally
        {
            Directory.Delete(dataDirectory, recursive: true);
        }
    }
}
