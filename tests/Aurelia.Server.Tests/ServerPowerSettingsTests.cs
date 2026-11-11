using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerPowerSettingsTests
{
    [Fact]
    public void SettingsAreWrittenAsPlainLinesTheSleepScriptReads()
    {
        using var fixture = new Fixture(available: true);
        var initial = fixture.Store.Read();
        Assert.Equal(new ServerPowerSettings(true, "off", ServerPowerSettingsStore.DefaultIdleMinutes, null, null), initial);

        var saved = fixture.Store.Update(new("sleep", 20, "17:00", "23:30"));
        Assert.Equal(new ServerPowerSettings(true, "sleep", 20, "17:00", "23:30"), saved);
        Assert.Equal(
            ["MODE=sleep", "IDLE_MINUTES=20", "AWAKE_FROM=17:00", "AWAKE_UNTIL=23:30", "WAKE_ON_ACCESS=off"],
            File.ReadAllLines(fixture.SettingsPath).Where(line => !line.StartsWith('#')));

        var withoutHours = fixture.Store.Update(new("stop", 15, null, null));
        Assert.Equal(new ServerPowerSettings(true, "stop", 15, null, null), withoutHours);
        Assert.Contains("AWAKE_FROM=", File.ReadAllLines(fixture.SettingsPath));
    }

    [Theory]
    [InlineData(15, null, null, "reboot")]
    [InlineData(4, null, null)]
    [InlineData(1441, null, null)]
    [InlineData(15, "17:00", null)]
    [InlineData(15, "17:00", "17:00")]
    [InlineData(15, "25:00", "23:30")]
    [InlineData(15, "17:00\nENABLED=0", "23:30")]
    [InlineData(15, "17:00\n", "23:30")]
    public void InvalidSettingsAreRejectedAndNothingIsWritten(int idle, string? from, string? until, string mode = "sleep")
    {
        using var fixture = new Fixture(available: true);
        var error = Assert.Throws<AccountException>(() => fixture.Store.Update(new(mode, idle, from, until)));
        Assert.Equal(400, error.StatusCode);
        Assert.False(File.Exists(fixture.SettingsPath));
    }

    [Fact]
    public void ShutDownModeAndWakeOnAccessAreKeptWhereTheCardAllowsIt()
    {
        using var fixture = new Fixture(available: true);
        var refused = Assert.Throws<AccountException>(() => fixture.Store.Update(new("shutdown", 30, null, null, WakeOnAccess: true)));
        Assert.Equal("wake_on_access_unavailable", refused.Code);
        Assert.False(File.Exists(fixture.SettingsPath));

        File.WriteAllText(fixture.WakeSupportPath, "pumbg\n");
        var saved = fixture.Store.Update(new("shutdown", 30, "18:00", "23:00", WakeOnAccess: true));
        Assert.Equal(new ServerPowerSettings(true, "shutdown", 30, "18:00", "23:00", true, "pumbg"), saved);
        Assert.Contains("WAKE_ON_ACCESS=on", File.ReadAllLines(fixture.SettingsPath));

        // An app that doesn't know the choice sends none; it stays as it was.
        var older = fixture.Store.Update(new("sleep", 30, null, null));
        Assert.True(older.WakeOnAccess);
        Assert.False(fixture.Store.Update(new("sleep", 30, null, null, WakeOnAccess: false)).WakeOnAccess);
    }

    [Fact]
    public void OnlyWakeLettersAreReadFromTheSupportFile()
    {
        using var fixture = new Fixture(available: true);
        File.WriteAllText(fixture.WakeSupportPath, "u; rm -rf /\nMODE=sleep");
        Assert.Equal("umfsp", fixture.Store.Read().WakeSupport);
        File.WriteAllText(fixture.WakeSupportPath, new string('u', 65));
        Assert.Equal("", fixture.Store.Read().WakeSupport);
    }

    [Fact]
    public void UnknownOrMalformedLinesAreIgnored()
    {
        using var fixture = new Fixture(available: true);
        File.WriteAllLines(fixture.SettingsPath,
            ["MODE=sleep", "IDLE_MINUTES=2", "AWAKE_FROM=17:00", "AWAKE_UNTIL=", "PATH=/tmp", "MODE = off"]);
        Assert.Equal(new ServerPowerSettings(true, "sleep", ServerPowerSettingsStore.DefaultIdleMinutes, null, null), fixture.Store.Read());
        File.WriteAllLines(fixture.SettingsPath, ["MODE=hibernate"]);
        Assert.Equal("off", fixture.Store.Read().Mode);
    }

    [Fact]
    public void ServersWithoutTheLinuxPackageCannotChangePowerSettings()
    {
        using var fixture = new Fixture(available: false);
        Assert.False(fixture.Store.Read().Available);
        var error = Assert.Throws<AccountException>(() => fixture.Store.Update(new("sleep", 15, null, null)));
        Assert.Equal(409, error.StatusCode);
        Assert.False(File.Exists(fixture.SettingsPath));
    }

    [Fact]
    public async Task OnlyOwnersReadPowerSettings()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/power", owner.Token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        Assert.False((await ApiTestClient.ReadAsync<ServerPowerSettings>(response)).Available);

        using var anonymous = await client.GetAsync("/api/v1/server/power");
        Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly DirectoryInfo root = Directory.CreateTempSubdirectory("aurelia-power-");
        public ServerPowerSettingsStore Store { get; }
        public string SettingsPath => Path.Combine(root.FullName, ServerPowerSettingsStore.FileName);
        public string WakeSupportPath => Path.Combine(root.FullName, ServerPowerSettingsStore.WakeSupportFileName);

        public Fixture(bool available)
        {
            var runtime = new ServerRuntimeOptions(root.FullName, Path.Combine(root.FullName, "unused.db"),
                "http://127.0.0.1:43110", "Synthetic", false, 43111, "", "", null);
            Store = new ServerPowerSettingsStore(runtime, available);
        }

        public void Dispose() => root.Delete(recursive: true);
    }
}
