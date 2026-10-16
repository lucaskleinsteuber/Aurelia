using System.Text.Json;
using Aurelia.Contracts;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ClientContractTests
{
    [Fact]
    public void SharedClientFixturesDecodeAdditiveAndLegacyFields()
    {
        using var stream = typeof(ClientContractTests).Assembly.GetManifestResourceStream("client-contracts-v1.json");
        Assert.NotNull(stream);
        using var json = JsonDocument.Parse(stream);
        var root = json.RootElement;
        Assert.Null(root.GetProperty("artworkLegacy").Deserialize<ArtworkSummary>(ApiTestClient.JsonOptions)!.Revision);
        Assert.Equal(3, root.GetProperty("artwork").Deserialize<ArtworkSummary>(ApiTestClient.JsonOptions)!.Revision);
        var abilities = root.GetProperty("capabilities").Deserialize<ClientCapabilitiesResponse>(ApiTestClient.JsonOptions)!;
        Assert.Equal("1.5.1", abilities.MinimumClientVersion);
        Assert.Equal(ServerFeatures.All, abilities.Capabilities);
        var status = root.GetProperty("status").Deserialize<ServerStatusResponse>(ApiTestClient.JsonOptions)!;
        Assert.Equal("media_drive_disconnected", Assert.Single(status.Readiness.Components).Reason);
        var pairing = root.GetProperty("pairing").Deserialize<DeviceAuthorizationStatusResponse>(ApiTestClient.JsonOptions)!;
        Assert.Equal(DeviceAuthorizationState.Pending, pairing.State);
        Assert.Null(pairing.Authentication);
        var approved = root.GetProperty("pairingApproved").Deserialize<DeviceAuthorizationStatusResponse>(ApiTestClient.JsonOptions)!;
        Assert.Equal(DeviceAuthorizationState.Approved, approved.State);
        Assert.NotNull(approved.Authentication);
        Assert.Equal(UserRole.Owner, approved.Authentication.User.Role);
        Assert.Equal("device_session_revoked", root.GetProperty("problem").Deserialize<ApiProblem>(ApiTestClient.JsonOptions)!.Code);
    }
}
