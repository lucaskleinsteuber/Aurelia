using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class RemotePlaybackTests
{
    private static readonly Guid Session = Guid.NewGuid();
    private static readonly Guid OtherSession = Guid.NewGuid();

    [Fact]
    public void DeviceHeartbeatRegistersAndUpdatesActivePlayer()
    {
        var service = new RemotePlaybackService();
        var userA = Guid.NewGuid();

        var initial = new PlayerHeartbeatRequest(
            "device-apple-tv",
            "Living Room Apple TV",
            "tvos",
            IsPlaying: false);

        var response = service.RecordHeartbeat(userA, Session, initial);
        Assert.True(response.Success);

        var active = service.GetActiveDevices(userA);
        var target = Assert.Single(active);
        Assert.Equal("device-apple-tv", target.DeviceId);
        Assert.Equal("Living Room Apple TV", target.DeviceName);
        Assert.Equal("tvos", target.ClientType);
        Assert.False(target.IsPlaying);

        // Update with active playback
        var mediaId = Guid.NewGuid();
        var update = new PlayerHeartbeatRequest(
            "device-apple-tv",
            "Living Room Apple TV",
            "tvos",
            IsPlaying: true,
            MediaId: mediaId,
            Title: "Inception",
            PositionSeconds: 120.5,
            DurationSeconds: 8880.0,
            IsPaused: false);

        service.RecordHeartbeat(userA, Session, update);

        var status = service.GetDeviceStatus(userA, "device-apple-tv");
        Assert.True(status.IsPlaying);
        Assert.Equal(mediaId, status.MediaId);
        Assert.Equal("Inception", status.Title);
        Assert.Equal(120.5, status.PositionSeconds);
        Assert.Equal(8880.0, status.DurationSeconds);
        Assert.False(status.IsPaused);
    }

    [Fact]
    public void GetActiveDevicesFiltersByProfileAndExcludesSender()
    {
        var service = new RemotePlaybackService();
        var userA = Guid.NewGuid();
        var userB = Guid.NewGuid();

        service.RecordHeartbeat(userA, Session, new PlayerHeartbeatRequest("dev-1", "MacBook", "macos", false));
        service.RecordHeartbeat(userA, Session, new PlayerHeartbeatRequest("dev-2", "Apple TV", "tvos", false));
        service.RecordHeartbeat(userB, OtherSession, new PlayerHeartbeatRequest("dev-3", "iPad", "ios", false));

        var userADevices = service.GetActiveDevices(userA);
        Assert.Equal(2, userADevices.Count);
        Assert.Contains(userADevices, d => d.DeviceId == "dev-1");
        Assert.Contains(userADevices, d => d.DeviceId == "dev-2");

        // Exclude current sender device
        var senderFiltered = service.GetActiveDevices(userA, excludeDeviceId: "dev-1");
        var single = Assert.Single(senderFiltered);
        Assert.Equal("dev-2", single.DeviceId);

        // User B sees only their device
        var userBDevices = service.GetActiveDevices(userB);
        var userBSingle = Assert.Single(userBDevices);
        Assert.Equal("dev-3", userBSingle.DeviceId);
    }

    [Fact]
    public void SendCommandEnqueuesAndValidatesInputs()
    {
        var service = new RemotePlaybackService();
        var userA = Guid.NewGuid();
        var userB = Guid.NewGuid();
        var mediaId = Guid.NewGuid();

        service.RecordHeartbeat(userA, Session, new PlayerHeartbeatRequest("target-tv", "Apple TV", "tvos", false));

        // Invalid action
        var invalidActionEx = Assert.Throws<AccountException>(() =>
            service.SendCommand(userA, "target-tv", new RemotePlaybackCommandRequest("destroy")));
        Assert.Equal("unsupported_action", invalidActionEx.Code);

        // Play missing mediaId
        var missingMediaEx = Assert.Throws<AccountException>(() =>
            service.SendCommand(userA, "target-tv", new RemotePlaybackCommandRequest("play")));
        Assert.Equal("missing_media_id", missingMediaEx.Code);

        // Target offline / not found
        var offlineEx = Assert.Throws<AccountException>(() =>
            service.SendCommand(userA, "nonexistent-device", new RemotePlaybackCommandRequest("play", MediaId: mediaId)));
        Assert.Equal("target_offline", offlineEx.Code);

        // Target profile mismatch
        var mismatchEx = Assert.Throws<AccountException>(() =>
            service.SendCommand(userB, "target-tv", new RemotePlaybackCommandRequest("play", MediaId: mediaId)));
        Assert.Equal("target_profile_mismatch", mismatchEx.Code);

        // Successful play command
        var sendResult = service.SendCommand(userA, "target-tv", new RemotePlaybackCommandRequest("play", MediaId: mediaId, PositionSeconds: 45.0));
        Assert.NotEqual(Guid.Empty, sendResult.CommandId);
        Assert.Equal("queued", sendResult.Status);
    }

    [Fact]
    public async Task CommandsAreDrainedAndDispatchedCorrectly()
    {
        var service = new RemotePlaybackService();
        var userA = Guid.NewGuid();
        var mediaId = Guid.NewGuid();

        service.RecordHeartbeat(userA, Session, new PlayerHeartbeatRequest("target-tv", "Apple TV", "tvos", false));

        // Send play command
        var cmd1 = service.SendCommand(userA, "target-tv", new RemotePlaybackCommandRequest("play", MediaId: mediaId, PositionSeconds: 15.0));
        // Send pause command
        var cmd2 = service.SendCommand(userA, "target-tv", new RemotePlaybackCommandRequest("pause"));

        // Retrieve commands as target device
        var received = await service.GetCommandsAsync(userA, Session, "target-tv", waitMs: 0, CancellationToken.None);
        Assert.Equal(2, received.Count);
        Assert.Equal(cmd1.CommandId, received[0].CommandId);
        Assert.Equal("play", received[0].Action);
        Assert.Equal(mediaId, received[0].MediaId);
        Assert.Equal(15.0, received[0].PositionSeconds);

        Assert.Equal(cmd2.CommandId, received[1].CommandId);
        Assert.Equal("pause", received[1].Action);

        // Next poll should be empty
        var empty = await service.GetCommandsAsync(userA, Session, "target-tv", waitMs: 0, CancellationToken.None);
        Assert.Empty(empty);
    }

    [Fact]
    public async Task LongPollWakesUpImmediatelyWhenCommandIsPosted()
    {
        var service = new RemotePlaybackService();
        var userA = Guid.NewGuid();
        var mediaId = Guid.NewGuid();

        service.RecordHeartbeat(userA, Session, new PlayerHeartbeatRequest("target-tv", "Apple TV", "tvos", false));

        // Start long-poll in background task
        var pollTask = Task.Run(async () =>
        {
            return await service.GetCommandsAsync(userA, Session, "target-tv", waitMs: 5000, CancellationToken.None);
        });

        // Small delay to ensure wait is entered
        await Task.Delay(50);
        Assert.False(pollTask.IsCompleted);

        // Post command
        service.SendCommand(userA, "target-tv", new RemotePlaybackCommandRequest("seek", PositionSeconds: 300.0));

        // Poll task should complete quickly
        var completed = await Task.WhenAny(pollTask, Task.Delay(2000));
        Assert.Same(pollTask, completed);

        var result = await pollTask;
        var single = Assert.Single(result);
        Assert.Equal("seek", single.Action);
        Assert.Equal(300.0, single.PositionSeconds);
    }

    [Fact]
    public async Task AnotherDeviceCannotTakeOverALivePlayerOrReadItsCommands()
    {
        var service = new RemotePlaybackService();
        var owner = Guid.NewGuid();
        var intruder = Guid.NewGuid();
        service.RecordHeartbeat(owner, Session, new PlayerHeartbeatRequest("living-room", "Apple TV", "tvos", false));

        var takeover = Assert.Throws<AccountException>(() =>
            service.RecordHeartbeat(intruder, OtherSession, new PlayerHeartbeatRequest("living-room", "Fake", "web", false)));
        Assert.Equal("device_id_in_use", takeover.Code);

        service.SendCommand(owner, "living-room", new RemotePlaybackCommandRequest("pause"));
        var read = await Assert.ThrowsAsync<AccountException>(() =>
            service.GetCommandsAsync(owner, OtherSession, "living-room", 0, CancellationToken.None));
        Assert.Equal("device_profile_mismatch", read.Code);
        Assert.Single(await service.GetCommandsAsync(owner, Session, "living-room", 0, CancellationToken.None));
    }

    [Fact]
    public async Task SwitchingTheProfileOnAPlayerDropsCommandsForThePreviousProfile()
    {
        var service = new RemotePlaybackService();
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        service.RecordHeartbeat(first, Session, new PlayerHeartbeatRequest("tv", "Apple TV", "tvos", false));
        service.SendCommand(first, "tv", new RemotePlaybackCommandRequest("play", MediaId: Guid.NewGuid()));

        service.RecordHeartbeat(second, Session, new PlayerHeartbeatRequest("tv", "Apple TV", "tvos", false));

        Assert.Empty(await service.GetCommandsAsync(second, Session, "tv", 0, CancellationToken.None));
    }

    [Fact]
    public void OversizedIdentifiersAreRejectedAndLongNamesShortened()
    {
        var service = new RemotePlaybackService();
        var user = Guid.NewGuid();
        Assert.Equal("invalid_device_id", Assert.Throws<AccountException>(() => service.RecordHeartbeat(user, Session,
            new PlayerHeartbeatRequest(new string('x', 129), "TV", "tvos", false))).Code);

        service.RecordHeartbeat(user, Session, new PlayerHeartbeatRequest("tv", new string('n', 500), "tvos", false));
        Assert.Equal(100, Assert.Single(service.GetActiveDevices(user)).DeviceName.Length);
    }
}
