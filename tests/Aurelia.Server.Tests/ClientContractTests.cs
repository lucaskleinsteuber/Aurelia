using System.Text.Json;
using System.Text.Json.Nodes;
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

    /// <summary>
    /// The clients decode these fixtures; the server must produce exactly their field names, or
    /// a client screen silently stays empty.
    /// </summary>
    [Fact]
    public void ServerResponsesUseTheFieldNamesTheClientFixturesDecode()
    {
        using var stream = typeof(ClientContractTests).Assembly.GetManifestResourceStream("client-contracts-v1.json");
        var root = JsonNode.Parse(stream!)!;
        var artwork = root["artwork"]!.Deserialize<ArtworkSummary>(ApiTestClient.JsonOptions)!;
        var now = DateTimeOffset.UnixEpoch;

        AssertSameShape(root["historyPage"]!, new WatchHistoryPage(
            [new WatchHistoryItem(Guid.NewGuid(), Guid.NewGuid(), "Pilot", "Example Show · S1E1", 2020, MediaKind.Episode, artwork, now, 1, 2, 3, false)],
            0, 50, 1));
        AssertSameShape(root["duplicateGroups"]!, new[] { new DuplicateGroup("key", "Example Film", MediaKind.Movie, 2019,
            [new DuplicateItemSummary(Guid.NewGuid(), "Example Film", MediaKind.Movie, 2019, "file.mkv", 1, MediaAvailability.Available)]) });
        AssertSameShape(root["offlineTitles"]!, new[] { new OfflineTitleSummary(Guid.NewGuid(), "Example Film", MediaKind.Movie, 2019,
            "Movies", "file.mkv", now, 1) });
        AssertSameShape(root["unmatchedTitles"]!, new[] { new UnmatchedTitleSummary(Guid.NewGuid(), "Clip", MediaKind.Movie, null,
            "clip.mkv", "No metadata found") });
    }

    private static void AssertSameShape(JsonNode fixture, object response) =>
        Assert.Equal(Shape(fixture), Shape(JsonSerializer.SerializeToNode(response, ApiTestClient.JsonOptions)!));

    private static string Shape(JsonNode? node) => node switch
    {
        JsonObject value => "{" + string.Join(",", value.OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => pair.Key + (pair.Key == "poster" ? "" : ":" + Shape(pair.Value)))) + "}",
        JsonArray value => "[" + (value.Count > 0 ? Shape(value[0]) : "") + "]",
        _ => "",
    };
}
