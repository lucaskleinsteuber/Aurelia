using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class Build7HostingTests
{
    [Fact]
    public void HostReadinessSignalIsNonceBoundAndEmittedOnlyAfterApplicationStarted()
    {
        using var lifetime = new TestApplicationLifetime();
        using var output = new StringWriter();
        const string nonce = "0123456789abcdefghijklmnopqrstuvwxyz_AB-CD";

        Assert.True(HostReadinessSignal.Register(lifetime, output, nonce));
        Assert.Equal(string.Empty, output.ToString());

        lifetime.Start();

        Assert.Equal(
            $"{HostReadinessSignal.MarkerPrefix}{nonce}{Environment.NewLine}",
            output.ToString());

        lifetime.Stop();

        Assert.Equal(
            $"{HostReadinessSignal.MarkerPrefix}{nonce}{Environment.NewLine}"
                + $"{HostReadinessSignal.StoppingMarkerPrefix}{nonce}{Environment.NewLine}",
            output.ToString());
    }

    [Theory]
    [InlineData(null)]
    [InlineData("short")]
    [InlineData("0123456789abcdefghijklmnopqrstuvwxyz/+")]
    public void HostReadinessSignalRejectsMissingOrUnsafeNonces(string? nonce)
    {
        using var lifetime = new TestApplicationLifetime();
        using var output = new StringWriter();

        Assert.False(HostReadinessSignal.Register(lifetime, output, nonce));
        lifetime.Start();
        lifetime.Stop();

        Assert.Equal(string.Empty, output.ToString());
    }

    [Fact]
    public async Task OwnerSetupRejectsMissingAndIncorrectBootstrapSecrets()
    {
        using var factory = new AureliaServerFactory();
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
                        ["Aurelia:LanAccessEnabled"] = "false",
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

    [Fact]
    public void ANativeHostCanAskForHttpsOnThisComputerWithoutNetworkAccess()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        try
        {
            Directory.CreateDirectory(dataDirectory);
            var configuration = new ConfigurationBuilder().Build();
            var closed = ServerRuntimeOptions.Resolve(configuration, ["run", "--data-dir", dataDirectory, "--lan-port", "45112"]);
            Assert.False(closed.LocalHttpsEnabled);
            Assert.DoesNotContain("https://", closed.ListenUrl, StringComparison.Ordinal);

            // The desktop app reaches its own server over pinned HTTPS on 127.0.0.1, never on other addresses.
            var local = ServerRuntimeOptions.Resolve(configuration, ["run", "--data-dir", dataDirectory, "--lan-port", "45112", "--local-https"]);
            Assert.True(local.LocalHttpsEnabled);
            Assert.False(local.LanAccessEnabled);
            Assert.EndsWith(";https://127.0.0.1:45112", local.ListenUrl, StringComparison.Ordinal);
            Assert.DoesNotContain("https://*", local.ListenUrl, StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(dataDirectory, recursive: true);
        }
    }

    private sealed class TestApplicationLifetime : IHostApplicationLifetime, IDisposable
    {
        private readonly CancellationTokenSource started = new();
        private readonly CancellationTokenSource stopping = new();
        private readonly CancellationTokenSource stopped = new();

        public CancellationToken ApplicationStarted => started.Token;

        public CancellationToken ApplicationStopping => stopping.Token;

        public CancellationToken ApplicationStopped => stopped.Token;

        public void Start()
        {
            started.Cancel();
        }

        public void Stop()
        {
            stopping.Cancel();
        }

        public void StopApplication()
        {
            stopping.Cancel();
            stopped.Cancel();
        }

        public void Dispose()
        {
            started.Dispose();
            stopping.Dispose();
            stopped.Dispose();
        }
    }
}
