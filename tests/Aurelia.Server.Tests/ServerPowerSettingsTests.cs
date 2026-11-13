using System.Net.Http.Json;
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
            ["MODE=sleep", "IDLE_MINUTES=20", "AWAKE_FROM=17:00", "AWAKE_UNTIL=23:30", "WAKE_ON_ACCESS=off", "AFTER_SLEEP_TIMER=on"],
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
        Assert.True(saved.AfterSleepTimer);
        Assert.Contains("WAKE_ON_ACCESS=on", File.ReadAllLines(fixture.SettingsPath));

        // An app that doesn't know the choice sends none; it stays as it was.
        var older = fixture.Store.Update(new("sleep", 30, null, null));
        Assert.True(older.WakeOnAccess);
        Assert.False(fixture.Store.Update(new("sleep", 30, null, null, WakeOnAccess: false)).WakeOnAccess);
    }

    [Fact]
    public void AServerHostedByTheAppOnlyStopsAfterUnusedMinutesAndIsNeverWokenOverTheNetwork()
    {
        using var fixture = new Fixture(available: null, hosting: ServerHosting.MacApp);
        File.WriteAllText(fixture.WakeSupportPath, "pumbg");
        var initial = fixture.Store.Read();
        Assert.True(initial.Available);
        Assert.Equal((ServerHosting.MacApp, ""), (initial.Hosting, initial.WakeSupport));
        foreach (var mode in new[] { "sleep", "shutdown" })
            Assert.Equal("invalid_power_mode", Assert.Throws<AccountException>(() => fixture.Store.Update(new(mode, 15, null, null))).Code);
        Assert.Equal("wake_on_access_unavailable",
            Assert.Throws<AccountException>(() => fixture.Store.Update(new("stop", 15, null, null, WakeOnAccess: true))).Code);
        var saved = fixture.Store.Update(new("stop", 30, null, null, AfterSleepTimer: false));
        Assert.Equal(("stop", 30, false), (saved.Mode, saved.IdleMinutes, saved.AfterSleepTimer));
        // A file written for a Linux server keeps working, as stop.
        File.WriteAllLines(fixture.SettingsPath, ["MODE=sleep", "IDLE_MINUTES=20"]);
        Assert.Equal("stop", fixture.Store.Read().Mode);
    }

    [Fact]
    public void AnAppHostedServerStopsWhenUnusedOutsideAwakeHoursAndNeverWhileSomethingPlays()
    {
        var settings = new ServerPowerSettings(true, "stop", 30, null, null, Hosting: ServerHosting.LinuxApp);
        var now = new DateTimeOffset(2026, 11, 11, 20, 0, 0, TimeSpan.Zero);
        var utc = TimeZoneInfo.Utc;
        Assert.Null(AppHostedIdleStop.Decide(settings, now, now.AddMinutes(-29), 0, null, utc));
        Assert.Equal("Unused for 30 minutes", AppHostedIdleStop.Decide(settings, now, now.AddMinutes(-30), 0, null, utc));
        Assert.Null(AppHostedIdleStop.Decide(settings, now, now.AddHours(-2), 1, null, utc));
        Assert.Null(AppHostedIdleStop.Decide(settings with { Mode = "off" }, now, now.AddHours(-2), 0, null, utc));
        Assert.Null(AppHostedIdleStop.Decide(settings with { AwakeFrom = "19:00", AwakeUntil = "01:00" }, now, now.AddHours(-2), 0, null, utc));
        Assert.Equal("A sleep timer ended", AppHostedIdleStop.Decide(settings, now, now.AddMinutes(-6), 0, now.AddMinutes(-1), utc));
        Assert.Null(AppHostedIdleStop.Decide(settings with { AfterSleepTimer = false }, now, now.AddMinutes(-6), 0, now.AddMinutes(-1), utc));
        Assert.Null(AppHostedIdleStop.Decide(settings, now, now.AddMinutes(-6), 0, now.AddMinutes(-10), utc)); // someone watched after the timer
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
    public void TheWakeOnLanCheckReportsTheCardTheConnectionAndTheSleepTheComputerOffers()
    {
        using var fixture = new Fixture(available: true);
        // Nothing known yet: the wake script hasn't run, and this is not Linux.
        Assert.Equal(("", "", ""), Check(fixture.Store.Read()));

        File.WriteAllLines(fixture.WakeStatusPath, ["NETWORK=wired", "WAKE_ON=g"]);
        fixture.WritePower("freeze mem disk\n", "s2idle [deep]\n");
        Assert.Equal(("wired", "g", "deep"), Check(fixture.Store.Read()));

        fixture.WritePower("freeze mem\n", "[s2idle] deep\n");
        Assert.Equal("light", fixture.Store.Read().SleepKind);
        fixture.WritePower("freeze mem\n", "[s2idle]\n");
        Assert.Equal("light", fixture.Store.Read().SleepKind);
        fixture.WritePower("freeze disk\n", "[s2idle]\n");
        Assert.Equal("none", fixture.Store.Read().SleepKind);
        // A kernel before mem_sleep only knew suspend to RAM.
        fixture.WritePower("mem disk\n", null);
        Assert.Equal("deep", fixture.Store.Read().SleepKind);

        File.WriteAllLines(fixture.WakeStatusPath, ["NETWORK=wifi", "WAKE_ON=d"]);
        Assert.Equal(("wifi", "d"), (fixture.Store.Read().Network, fixture.Store.Read().WakeOn));
        // Only the two known values are read; anything else in the file is ignored.
        File.WriteAllLines(fixture.WakeStatusPath, ["NETWORK=pumbg", "WAKE_ON=wired", "WAKE_ON=g; reboot", "MODE=sleep", "NETWORK = wired"]);
        Assert.Equal(("", ""), (fixture.Store.Read().Network, fixture.Store.Read().WakeOn));
        File.WriteAllText(fixture.WakeStatusPath, "NETWORK=wired\n" + new string('#', 300));
        Assert.Equal("", fixture.Store.Read().Network);
    }

    [Fact]
    public void ServersThatCantPowerDownTheirComputerHaveNoWakeOnLanCheck()
    {
        foreach (var (available, hosting) in new (bool? Available, string? Hosting)[] { (null, ServerHosting.MacApp), (false, null) })
        {
            using var fixture = new Fixture(available, hosting);
            File.WriteAllLines(fixture.WakeStatusPath, ["NETWORK=wired", "WAKE_ON=g"]);
            fixture.WritePower("freeze mem disk\n", "s2idle [deep]\n");
            Assert.Equal(("", "", ""), Check(fixture.Store.Read()));
        }
    }

    private static (string, string, string) Check(ServerPowerSettings settings) =>
        (settings.Network, settings.WakeOn, settings.SleepKind);

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

        // Every device learns where the server runs, so it knows whether to wake it or ask for Aurelia to be opened.
        var info = await client.GetFromJsonAsync<ServerInfoResponse>("/api/v1/server/info", ApiTestClient.JsonOptions);
        Assert.Contains(info!.Hosting, new[] { ServerHosting.Server, ServerHosting.LinuxServer, ServerHosting.MacApp, ServerHosting.LinuxApp });
    }

    private sealed class Fixture : IDisposable
    {
        private readonly DirectoryInfo root = Directory.CreateTempSubdirectory("aurelia-power-");
        public ServerPowerSettingsStore Store { get; }
        public string SettingsPath => Path.Combine(root.FullName, ServerPowerSettingsStore.FileName);
        public string WakeSupportPath => Path.Combine(root.FullName, ServerPowerSettingsStore.WakeSupportFileName);
        public string WakeStatusPath => Path.Combine(root.FullName, ServerPowerSettingsStore.WakeStatusFileName);
        private string SystemPower => Path.Combine(root.FullName, "sys-power");

        public Fixture(bool? available, string? hosting = null)
        {
            var runtime = new ServerRuntimeOptions(root.FullName, Path.Combine(root.FullName, "unused.db"),
                "http://127.0.0.1:43110", "Synthetic", false, 43111, "", "", null);
            Store = new ServerPowerSettingsStore(runtime, available, hosting, SystemPower);
        }

        /// <summary>Stands in for /sys/power: its state and, unless null, mem_sleep.</summary>
        public void WritePower(string state, string? memSleep)
        {
            Directory.CreateDirectory(SystemPower);
            File.WriteAllText(Path.Combine(SystemPower, "state"), state);
            var memSleepPath = Path.Combine(SystemPower, "mem_sleep");
            if (memSleep is null) File.Delete(memSleepPath);
            else File.WriteAllText(memSleepPath, memSleep);
        }

        public void Dispose() => root.Delete(recursive: true);
    }
}
