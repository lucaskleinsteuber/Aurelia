using System.Security.Claims;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Http;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerUseClockTests
{
    [Theory]
    [InlineData("GET", "/api/v1/catalog/home", true, true)]
    [InlineData("PUT", "/api/v1/playback/progress/00000000-0000-0000-0000-000000000001", true, true)]
    [InlineData("GET", "/api/v1/streams/00000000-0000-0000-0000-000000000001", true, true)]
    [InlineData("GET", "/api/v1/sync/changes", true, false)]
    [InlineData("POST", "/api/v1/devices/player/heartbeat", true, false)]
    [InlineData("GET", "/api/v1/devices/player/commands", true, false)]
    [InlineData("GET", "/api/v1/server/info", false, false)]
    [InlineData("GET", "/api/v1/health", true, false)]
    [InlineData("GET", "/api/v1/catalog/home", false, false)]
    [InlineData("POST", "/api/v1/auth/pair", false, true)]
    [InlineData("POST", "/api/v1/setup/owner", false, true)]
    public void OnlyRequestsSomeoneMadeCountAsUse(string method, string path, bool signedIn, bool expected)
    {
        var context = new DefaultHttpContext();
        context.Request.Method = method;
        context.Request.Path = path;
        if (signedIn) context.User = new ClaimsPrincipal(new ClaimsIdentity([new Claim("sub", "synthetic")], "Test"));
        Assert.Equal(expected, ServerUseClock.CountsAsUse(context));
    }

    [Fact]
    public void UseIsWrittenAtMostTwiceAMinute()
    {
        var root = Directory.CreateTempSubdirectory("aurelia-use-");
        try
        {
            var clock = new Clock();
            var runtime = new ServerRuntimeOptions(root.FullName, Path.Combine(root.FullName, "unused.db"),
                "http://127.0.0.1:43110", "Synthetic", false, 43111, "", "", null);
            var use = new ServerUseClock(runtime, clock);
            var path = Path.Combine(root.FullName, ServerUseClock.FileName);

            Assert.True(use.Record());
            Assert.Equal(clock.GetUtcNow().ToUnixTimeSeconds().ToString(System.Globalization.CultureInfo.InvariantCulture), File.ReadAllText(path));
            clock.Advance(TimeSpan.FromSeconds(10));
            Assert.False(use.Record());
            clock.Advance(TimeSpan.FromSeconds(25));
            Assert.True(use.Record());
            Assert.Equal(clock.GetUtcNow().ToUnixTimeSeconds().ToString(System.Globalization.CultureInfo.InvariantCulture), File.ReadAllText(path));
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    private sealed class Clock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan by) => now += by;
    }
}
