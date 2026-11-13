using System.Net;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Management;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>Security on Linux ("security-v1"): the log's words, the installation id and confirming an unlock elsewhere.</summary>
public sealed class SecurityTests
{
    private static readonly UserSummary Admin = new(FakeLibrary.OwnerId, "Admin", UserRole.Admin, DateTimeOffset.UtcNow);
    private static readonly StoredServer Server = new(FakeServer.ServerId, "Synthetic Server", new Uri("https://127.0.0.1:43111"), FakeServer.Fingerprint,
        "synthetic-device-token-000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));
    private static readonly ProfileSession Profile = new(Admin, Guid.NewGuid(), "synthetic-profile-token-000000000000000001", DateTimeOffset.UtcNow.AddHours(12));
    private static string Json<T>(T value) => JsonSerializer.Serialize(value, AureliaJson.Options);

    [Fact]
    public void TheLogUsesTheSameWordsAsTheOtherAppsAndShowsUnknownKinds()
    {
        Assert.Equal("Storage location removed", SecurityText.Kind("library_removed"));
        Assert.Equal("Wrong Server Password", SecurityText.Kind("wrong_password"));
        Assert.Equal("Something New", SecurityText.Kind("something_new"));
        Assert.Equal("iOS · 192.0.2.40", SecurityText.DeviceLine("iOS", "192.0.2.40"));
        Assert.Equal("", SecurityText.DeviceLine(null, ""));
        Assert.Equal("New device signed in: Invented Phone · iOS · 192.0.2.40", SecurityText.NewDevice("Invented Phone", "iOS", "192.0.2.40"));
        Assert.True(SecurityText.RemoteUnlockFinished("denied"));
        Assert.False(SecurityText.RemoteUnlockFinished("pending"));
    }

    [Fact]
    public void TheInstallationIdIsCreatedOnceAndKept()
    {
        var folder = Path.Combine(Path.GetTempPath(), "aurelia-linux-security-" + Guid.NewGuid().ToString("N"));
        try
        {
            var first = AureliaInstallation.Identifier(folder);
            Assert.True(Guid.TryParse(first, out _));
            Assert.Equal(first, AureliaInstallation.Identifier(folder));
            Assert.StartsWith("linux/", AureliaInstallation.ClientHeader, StringComparison.Ordinal);
        }
        finally
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public async Task WhenFaceIdIsRequiredTheUnlockIsConfirmedOnAnotherDevice()
    {
        var requestId = Guid.NewGuid();
        var expires = DateTimeOffset.UtcNow.AddMinutes(2);
        var server = FakeServer.WithServerInfo()
            .Answer("POST", "/api/v1/management/unlock", """{"code":"passkey_required","message":"Confirm with Face ID or Touch ID."}""", HttpStatusCode.Forbidden)
            .Answer("POST", "/api/v1/management/remote-unlock", Json(new RemoteUnlockStartResponse(requestId, "4821", expires)))
            .Answer("GET", $"/api/v1/management/remote-unlock/{requestId}", Json(new RemoteUnlockStatusResponse("pending", expires, null)))
            .Answer("GET", $"/api/v1/management/remote-unlock/{requestId}", Json(new RemoteUnlockStatusResponse("approved", expires, DateTimeOffset.UtcNow.AddMinutes(10))));
        using var api = new AureliaApi(server);
        string? shownCode = null;
        var client = new ManagementClient(api, new LibraryClient(api, Server, Profile, []), _ => Task.FromResult<string?>("synthetic server password"),
            async management =>
            {
                var request = await management.StartRemoteUnlockAsync();
                shownCode = request.Code;
                return await management.WaitForRemoteUnlockAsync(request.Id, TimeSpan.Zero);
            });

        await client.UnlockAsync("Unlock", TestContext.Current.CancellationToken);

        Assert.Equal("4821", shownCode);
        Assert.Equal(2, server.Requests.Count(r => r == $"GET /api/v1/management/remote-unlock/{requestId}"));
    }

    [Fact]
    public async Task ADeniedConfirmationLeavesManagementLocked()
    {
        var requestId = Guid.NewGuid();
        var expires = DateTimeOffset.UtcNow.AddMinutes(2);
        var server = FakeServer.WithServerInfo()
            .Answer("POST", "/api/v1/management/unlock", """{"code":"passkey_required","message":"Confirm with Face ID or Touch ID."}""", HttpStatusCode.Forbidden)
            .Answer("POST", "/api/v1/management/remote-unlock", Json(new RemoteUnlockStartResponse(requestId, "1111", expires)))
            .Answer("GET", $"/api/v1/management/remote-unlock/{requestId}", Json(new RemoteUnlockStatusResponse("denied", expires, null)));
        using var api = new AureliaApi(server);
        var client = new ManagementClient(api, new LibraryClient(api, Server, Profile, []), _ => Task.FromResult<string?>("synthetic server password"),
            async management =>
            {
                var request = await management.StartRemoteUnlockAsync();
                return await management.WaitForRemoteUnlockAsync(request.Id, TimeSpan.Zero);
            });

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.UnlockAsync("Unlock", TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task TheSecurityCallsUseTheOwnersEndpointsAndTheLogFilter()
    {
        var device = Guid.NewGuid();
        var server = FakeServer.WithServerInfo()
            .Answer("GET", "/api/v1/server/security/events", Json(new SecurityEventPage([], null)))
            .Answer("POST", $"/api/v1/server/security/devices/{device}/block", Json(new BlockDeviceResponse(true, 1)))
            .Answer("POST", $"/api/v1/server/security/devices/{device}/acknowledge", "", HttpStatusCode.NoContent);
        using var api = new AureliaApi(server);
        var client = new ManagementClient(api, new LibraryClient(api, Server, Profile, []), _ => Task.FromResult<string?>(null));

        await client.SecurityEventsAsync("failed");
        var blocked = await client.BlockDeviceAsync(device);
        await client.AcknowledgeDeviceAsync(device);

        Assert.Contains(server.RequestUris, uri => uri.Contains("outcome=failed", StringComparison.Ordinal) && uri.Contains("limit=50", StringComparison.Ordinal));
        Assert.True(blocked.Listed);
        Assert.Contains($"POST /api/v1/server/security/devices/{device}/acknowledge", server.Requests);
    }
}
