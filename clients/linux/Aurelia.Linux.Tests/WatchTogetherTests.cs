using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Playback;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>Watch Together with an invented party and a simulated engine; nothing is played.</summary>
public sealed class WatchTogetherTests
{
    private static readonly DateTimeOffset Start = new(2026, 11, 7, 20, 0, 0, TimeSpan.Zero);

    private static WatchPartyState State(bool playing, long position, bool waiting = false, long revision = 2, string action = "pause", Guid? media = null) =>
        new(Guid.Parse("00000000-0000-4000-8000-0000000000a1"), media ?? FakeLibrary.MovieA, "Quiet Orbit", playing, waiting, position, Start, Start, revision,
            [new WatchPartyMember(Guid.NewGuid(), "Lucas", "This PC", false, true, true), new WatchPartyMember(Guid.NewGuid(), "Mia", "Living Room TV", false, false, false)],
            action, "Mia");

    [Fact]
    public void ThePositionRunsOnlyWhilePlayingAndSmallDriftIsLeftAlone()
    {
        var later = Start.AddSeconds(10);
        Assert.Equal(10_000, WatchTogetherFollower.Position(State(true, 0), later));
        Assert.Equal(0, WatchTogetherFollower.Position(State(true, 0, waiting: true), later));
        Assert.Empty(WatchTogetherFollower.Steps(State(true, 0), later, 9_000, localPlaying: true));
        Assert.Equal([(WatchTogetherFollower.FollowStep.Seek, 10_000L)], WatchTogetherFollower.Steps(State(true, 0), later, 3_000, true));
        Assert.Equal([(WatchTogetherFollower.FollowStep.Seek, 42_000L), (WatchTogetherFollower.FollowStep.Pause, 42_000L)],
            WatchTogetherFollower.Steps(State(false, 42_000), later, 42_800, true));
        Assert.Equal(TimeSpan.FromSeconds(9), WatchTogetherFollower.Offset(Start.AddSeconds(10), Start, Start.AddSeconds(2)));
        Assert.Equal("Mia paused", WatchTogetherFollower.Notice(State(false, 0)));
        Assert.Equal("Mia started Quiet Orbit", WatchTogetherFollower.Notice(State(true, 0, action: "change")));
    }

    [AvaloniaFact]
    public void StartingAPartyMakesThePlayerFollowWhatOthersDo()
    {
        var engines = new SimulatedEngines();
        var created = State(true, 1_200_000, revision: 1, action: "started");
        var paused = State(false, 600_000);
        var server = FakeLibrary.Create()
            .Answer("POST", "/api/v1/watch-together", JsonSerializer.Serialize(created, AureliaJson.Options))
            .Answer("POST", $"/api/v1/watch-together/{created.Id}/commands", JsonSerializer.Serialize(created, AureliaJson.Options))
            .Answer("GET", $"/api/v1/watch-together/{created.Id}", JsonSerializer.Serialize(paused, AureliaJson.Options));
        var window = FakeLibrary.ShowLibrary(server, engines);
        var item = window.Session.Library!.Catalog.First(i => i.Id == FakeLibrary.MovieA);
        _ = window.PlayAsync(item, resume: true);
        FakeLibrary.Pump(() => window.Player?.State == PlayerState.Playing);
        var view = window.GetVisualDescendants().OfType<PlayerView>().Single();
        Assert.Contains(view.GetVisualDescendants().OfType<Button>(), button => AutomationProperties.GetName(button) == "Watch Together");

        _ = window.StartWatchTogetherAsync(window.Player!);
        FakeLibrary.Pump(() => window.Player!.State == PlayerState.Paused && view.TogetherNoticeText is not null, rounds: 300);
        Assert.Equal(600_000, window.Player!.Position);
        Assert.Equal("Mia paused", view.TogetherNoticeText);
        Assert.Contains($"\"mediaId\":\"{FakeLibrary.MovieA}\"", server.Bodies["POST /api/v1/watch-together"], StringComparison.Ordinal);
        Assert.Equal(2, window.WatchParty!.State!.Revision);

        // Closing the player leaves the party.
        server.Answer("DELETE", $"/api/v1/watch-together/{created.Id}/members/me", "");
        _ = window.Player.CloseAsync();
        FakeLibrary.Pump(() => window.WatchParty is null && server.Requests.Contains($"DELETE /api/v1/watch-together/{created.Id}/members/me"), rounds: 200);
        Assert.Null(window.WatchParty);
    }
}
