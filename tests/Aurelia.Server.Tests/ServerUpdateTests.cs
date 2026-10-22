using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerUpdateTests
{
    [Fact]
    public void ANewerReleaseCanBeRequestedAndIsReportedInstalledOnceTheBuildMatches()
    {
        using var fixture = new Fixture(build: 91);
        Assert.Equal(new ServerUpdateStatus(true, "1.8.7 (91)", null, false, "idle", null, null), fixture.Store.Read());
        var installRefused = Assert.Throws<AccountException>(() => fixture.Store.RequestInstall());
        Assert.Equal(409, installRefused.StatusCode);

        Assert.Equal("checking", fixture.Store.RequestCheck().State);
        Assert.True(File.Exists(fixture.PathOf(ServerUpdateStore.CheckRequestFileName)));
        // The package's root-run check answers and removes the request.
        File.Delete(fixture.PathOf(ServerUpdateStore.CheckRequestFileName));
        fixture.WriteStatus("STATE=idle", $"CHECKED_AT={fixture.Seconds}", "NEWEST_VERSION=1.8.8", "NEWEST_BUILD=92");
        var found = fixture.Store.Read();
        Assert.True(found.UpdateAvailable);
        Assert.Equal("1.8.8 (92)", found.Newest);
        Assert.Equal(fixture.Clock.GetUtcNow().ToUnixTimeSeconds(), found.CheckedAt?.ToUnixTimeSeconds());

        Assert.Equal("installing", fixture.Store.RequestInstall().State);
        Assert.True(File.Exists(fixture.PathOf(ServerUpdateStore.InstallRequestFileName)));
        Assert.Equal(409, Assert.Throws<AccountException>(() => fixture.Store.RequestInstall()).StatusCode);

        // The new program reports its own build after the restart.
        File.Delete(fixture.PathOf(ServerUpdateStore.InstallRequestFileName));
        fixture.WriteStatus("STATE=installing", $"CHANGED_AT={fixture.Seconds}", "NEWEST_VERSION=1.8.8", "NEWEST_BUILD=92", "TARGET_BUILD=92");
        Assert.Equal("installing", fixture.Store.Read().State);
        var updated = new ServerUpdateStore(fixture.Runtime, fixture.Clock, true, "1.8.8", 92).Read();
        Assert.Equal(new ServerUpdateStatus(true, "1.8.8 (92)", "1.8.8 (92)", false, "idle", null, null), updated);
    }

    [Fact]
    public void AnInstallationThatNeverFinishesAndAFailureAreReported()
    {
        using var fixture = new Fixture(build: 91);
        fixture.WriteStatus("STATE=installing", $"CHANGED_AT={fixture.Seconds}", "NEWEST_VERSION=1.8.8", "NEWEST_BUILD=92", "TARGET_BUILD=92");
        fixture.Clock.Advance(TimeSpan.FromMinutes(16));
        Assert.Equal("failed", fixture.Store.Read().State);

        fixture.WriteStatus("STATE=failed", "MESSAGE=The download does not match its checksum; nothing was installed.");
        var failed = fixture.Store.Read();
        Assert.Equal("failed", failed.State);
        Assert.Equal("The download does not match its checksum; nothing was installed.", failed.Message);
    }

    [Fact]
    public void MalformedStatusLinesAreIgnored()
    {
        using var fixture = new Fixture(build: 91);
        fixture.WriteStatus("STATE=rebooting", "NEWEST_VERSION=$(id)", "NEWEST_BUILD=92a", "MESSAGE=\u001b[31mred", "PATH=/tmp");
        Assert.Equal(new ServerUpdateStatus(true, "1.8.7 (91)", null, false, "idle", null, null), fixture.Store.Read());
    }

    [Fact]
    public void ServersWithoutTheLinuxPackageCannotUpdateFromTheApp()
    {
        using var fixture = new Fixture(build: 91, available: false);
        Assert.False(fixture.Store.Read().Available);
        Assert.Equal(409, Assert.Throws<AccountException>(() => fixture.Store.RequestCheck()).StatusCode);
        Assert.False(File.Exists(fixture.PathOf(ServerUpdateStore.CheckRequestFileName)));
    }

    [Fact]
    public async Task OwnersSeeWhereTheServerRunsAndOnlyThePackageRestartsOnLinux()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var capabilitiesRequest = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/capabilities", owner.Token);
        using var capabilitiesResponse = await client.SendAsync(capabilitiesRequest);
        var capabilities = await ApiTestClient.ReadAsync<ServerManagementCapabilities>(capabilitiesResponse);
        Assert.Equal(LinuxPackage.Platform, capabilities.Platform);
        Assert.False(capabilities.LinuxPackage);

        using var updatesRequest = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/updates", owner.Token);
        using var updatesResponse = await client.SendAsync(updatesRequest);
        Assert.False((await ApiTestClient.ReadAsync<ServerUpdateStatus>(updatesResponse)).Available);
        using var install = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/updates/install", owner.Token);
        using var refused = await ApiTestClient.SendAsync(client, install);
        Assert.Equal(HttpStatusCode.Conflict, refused.StatusCode);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly DirectoryInfo root = Directory.CreateTempSubdirectory("aurelia-updates-");
        public ServerRuntimeOptions Runtime { get; }
        public Clock Clock { get; } = new();
        public ServerUpdateStore Store { get; }
        public long Seconds => Clock.GetUtcNow().ToUnixTimeSeconds();

        public Fixture(int build, bool available = true)
        {
            Runtime = new ServerRuntimeOptions(root.FullName, Path.Combine(root.FullName, "unused.db"),
                "http://127.0.0.1:43110", "Synthetic", false, 43111, "", "", null);
            Store = new ServerUpdateStore(Runtime, Clock, available, "1.8.7", build);
        }

        public string PathOf(string name) => Path.Combine(root.FullName, name);
        public void WriteStatus(params string[] lines) => File.WriteAllLines(PathOf(ServerUpdateStore.StatusFileName), lines);
        public void Dispose() => root.Delete(recursive: true);
    }

    public sealed class Clock : TimeProvider
    {
        private DateTimeOffset now = new(2026, 10, 22, 18, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan by) => now += by;
    }
}
