using System.Net;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class ServerAddressTests
{
    [Theory]
    [InlineData("192.168.1.20", "https://192.168.1.20:43111/")]
    [InlineData("  server.local ", "https://server.local:43111/")]
    [InlineData("https://server.local:8443", "https://server.local:8443/")]
    [InlineData("[fd00::1]", "https://[fd00::1]:43111/")]
    [InlineData("[fd00::1]:9000", "https://[fd00::1]:9000/")]
    public void NormalizesTypedAddresses(string typed, string expected)
    {
        Assert.True(ServerAddress.TryNormalize(typed, out var address));
        Assert.Equal(expected, address.ToString());
    }

    [Theory]
    [InlineData("")]
    [InlineData("http://192.168.1.20")]
    [InlineData("https://user:secret@server.local")]
    [InlineData("https://server.local/path")]
    [InlineData("https://server.local/?q=1")]
    public void RejectsUnsafeOrUnclearAddresses(string typed) => Assert.False(ServerAddress.TryNormalize(typed, out _));

    [Fact]
    public void KnowsLoopback()
    {
        Assert.True(ServerAddress.IsLoopback(new Uri("https://127.0.0.1:43111")));
        Assert.False(ServerAddress.IsLoopback(new Uri("https://192.168.1.2:43111")));
    }
}

public sealed class ServerIdentityTests
{
    private const string Fingerprint = "A1B2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4B5C6D7E8F90";

    [Fact]
    public void ShowsTheFirstTwentyFourCharactersInGroups() => Assert.Equal("A1B2-C3D4-E5F6-0718-293A-4B5C", ServerIdentity.Display(Fingerprint));

    [Fact]
    public void ComparesIgnoringCaseButOnlyWholeFingerprints()
    {
        Assert.True(ServerIdentity.Matches(Fingerprint, Fingerprint.ToLowerInvariant()));
        Assert.False(ServerIdentity.Matches(Fingerprint, Fingerprint[..63]));
        Assert.False(ServerIdentity.Matches(Fingerprint, null));
    }

    [Fact]
    public void FingerprintIsTheHashOfTheP256PublicKey()
    {
        using var key = System.Security.Cryptography.ECDsa.Create(System.Security.Cryptography.ECCurve.NamedCurves.nistP256);
        var request = new System.Security.Cryptography.X509Certificates.CertificateRequest("CN=Aurelia Test", key, System.Security.Cryptography.HashAlgorithmName.SHA256);
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        var expected = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(key.ExportSubjectPublicKeyInfo()));
        Assert.Equal(expected, ServerIdentity.Fingerprint(certificate));
    }
}

public sealed class ProblemMappingTests
{
    [Fact]
    public async Task ReadsTheServersCodeAndRetryAfter()
    {
        using var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests)
        {
            Content = new StringContent("""{"code":"profile_pin_busy","message":"PIN verification is busy."}""", Encoding.UTF8, "application/json"),
        };
        response.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(900));
        var problem = await AureliaApi.ProblemAsync(response, CancellationToken.None);
        Assert.Equal(429, problem.Status);
        Assert.Equal("profile_pin_busy", problem.Code);
        Assert.Equal("PIN verification is busy.", problem.Message);
        Assert.Equal(TimeSpan.FromSeconds(300), problem.RetryAfter);
        Assert.True(problem.IsTransient);
    }

    [Fact]
    public async Task FallsBackToAPlainMessage()
    {
        using var response = new HttpResponseMessage(HttpStatusCode.Unauthorized) { Content = new StringContent("not json") };
        var problem = await AureliaApi.ProblemAsync(response, CancellationToken.None);
        Assert.Null(problem.Code);
        Assert.True(problem.IsAuthenticationFailure);
        Assert.False(problem.IsTransient);
    }

    [Fact]
    public void ReadsEnumsAndDatesLikeTheServer()
    {
        var summary = System.Text.Json.JsonSerializer.Deserialize<UserSummary>(
            """{"id":"6f1b2a3c-0000-4000-8000-000000000001","username":"lucas","role":"owner","createdAt":"2026-10-31T20:00:00+00:00","accessMode":"entireLibrary"}""",
            AureliaJson.Options)!;
        Assert.Equal(UserRole.Owner, summary.Role);
        Assert.Equal(new DateTimeOffset(2026, 10, 31, 20, 0, 0, TimeSpan.Zero), summary.CreatedAt);
        Assert.Equal(ProfileAccessMode.EntireLibrary, summary.AccessMode);
    }
}

public sealed class WakeOnLanTests
{
    [Fact]
    public void BuildsTheMagicPacket()
    {
        var packet = UdpWakeOnLan.MagicPacket("AA:bb:CC:dd:EE:01")!;
        Assert.Equal(102, packet.Length);
        Assert.All(packet[..6], value => Assert.Equal(0xFF, value));
        for (var repeat = 0; repeat < 16; repeat++)
        {
            Assert.Equal(new byte[] { 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01 }, packet[(6 + repeat * 6)..(12 + repeat * 6)]);
        }
        Assert.NotNull(UdpWakeOnLan.MagicPacket("aa-bb-cc-dd-ee-01"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("aa:bb:cc:dd:ee")]
    [InlineData("zz:bb:cc:dd:ee:ff")]
    [InlineData("00:00:00:00:00:00")]
    [InlineData("ff:ff:ff:ff:ff:ff")]
    public void IgnoresInvalidAddresses(string address) => Assert.Null(UdpWakeOnLan.MagicPacket(address));
}

public sealed class StoredConnectionTests
{
    private static StoredServer Sample() => new(Guid.NewGuid(), "Living Room", new Uri("https://192.168.1.20:43111"),
        new string('A', 64), "device-token-with-enough-length-0000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30),
        WakeOnLanAddresses: ["aa:bb:cc:dd:ee:01"]);

    [Fact]
    public void RoundTripsThroughTheKeyringFormat()
    {
        var server = Sample();
        var restored = StoredServerSerializer.Deserialize(StoredServerSerializer.Serialize(server))!;
        Assert.Equal(server.ServerId, restored.ServerId);
        Assert.Equal(server.Address, restored.Address);
        Assert.Equal(server.Fingerprint, restored.Fingerprint);
        Assert.Equal(server.DeviceToken, restored.DeviceToken);
        Assert.Equal(server.WakeOnLanAddresses, restored.WakeOnLanAddresses);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("""{"serverId":"6f1b2a3c-0000-4000-8000-000000000001","name":"x","address":"http://plain:80","fingerprint":"AA","deviceToken":"t"}""")]
    public void IgnoresDamagedEntries(string text) => Assert.Null(StoredServerSerializer.Deserialize(text));
}

public sealed class DiscoveryMergeTests
{
    [Fact]
    public void ListsEachServerOnceSortedByName()
    {
        var id = Guid.NewGuid();
        var merged = MdnsServerDiscovery.Merge(
        [
            new(id, "Studio", new Uri("https://192.168.1.2:43111")),
            new(id, "Studio", new Uri("https://[fd00::2]:43111")),
            new(null, "Attic", new Uri("https://192.168.1.3:43111")),
        ]);
        Assert.Equal(["Attic", "Studio"], merged.Select(server => server.Name));
    }
}

public sealed class ProfileVisualsTests
{
    [Fact]
    public void ColorComesFromTheIdLikeOnTheMac()
    {
        var id = Guid.Parse("00000000-0000-0000-0000-000000000003");
        Assert.Equal(3 % ProfileVisuals.Palettes.Length, ProfileVisuals.PaletteIndex(id));
        Assert.Equal(0, ProfileVisuals.PaletteIndex(null));
        Assert.Equal("L", ProfileVisuals.Initial("  lucas"));
        Assert.Equal("?", ProfileVisuals.Initial(" "));
    }
}

public sealed class FirstContactFingerprintTests
{
    [Fact]
    public async Task RejectsAServerWhoseShownFingerprintBelongsToAnotherKey()
    {
        // A server in the middle presents its own key but reports the real server's display text.
        var server = FakeServer.WithServerInfo().Replace("GET", "/api/v1/server/info", $$"""
            {"serverId":"{{FakeServer.ServerId}}","name":"Living Room Server","version":"1.26.3","isSetup":true,"lanAccessEnabled":true,
             "lanHttpsPort":43111,"publicKeyFingerprint":"{{FakeServer.Fingerprint}}","displayFingerprint":"FFFF-EEEE-DDDD-CCCC-BBBB-AAAA",
             "capabilities":["library-state-v1"]}
            """);
        using var api = new AureliaApi(server);
        var failure = await Assert.ThrowsAsync<AureliaApiException>(() =>
            api.InspectAsync(new Uri("https://192.168.1.20:43111"), TestContext.Current.CancellationToken));
        Assert.Equal("identity_mismatch", failure.Code);
    }

    [Fact]
    public async Task ShowsTheFingerprintOfThePresentedKey()
    {
        using var api = new AureliaApi(FakeServer.WithServerInfo());
        var inspected = await api.InspectAsync(new Uri("https://192.168.1.20:43111"), TestContext.Current.CancellationToken);
        Assert.Equal(ServerIdentity.Display(FakeServer.Fingerprint), ServerIdentity.Display(inspected.Fingerprint));
        Assert.True(AureliaApi.ShowsIdentity(inspected.Info, FakeServer.Fingerprint));
        Assert.False(AureliaApi.ShowsIdentity(inspected.Info with { DisplayFingerprint = "FFFF-EEEE-DDDD-CCCC-BBBB-AAAA" }, FakeServer.Fingerprint));
    }
}

public sealed class SecureConnectionFailureTests
{
    private sealed class FailingTransport(Exception inner) : IServerTransport
    {
        public HttpClient CreateClient(Uri address, string? expectedFingerprint, CapturedFingerprint? captured, TimeSpan timeout) =>
            new(new Failing(inner)) { BaseAddress = address, Timeout = timeout };

        private sealed class Failing(Exception inner) : HttpMessageHandler
        {
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
                throw new HttpRequestException(HttpRequestError.SecureConnectionError, "TLS failed", inner);
        }
    }

    private static readonly StoredServer Server = new(Guid.NewGuid(), "Living Room Server", new Uri("https://192.168.1.20:43111"),
        FakeServer.Fingerprint, "synthetic-device-token", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));

    [Fact]
    public async Task ARejectedKeyIsAnIdentityMismatch()
    {
        using var api = new AureliaApi(new FailingTransport(new System.Security.Authentication.AuthenticationException("rejected")));
        var failure = await Assert.ThrowsAsync<AureliaApiException>(() => api.ServerInfoAsync(Server, TestContext.Current.CancellationToken));
        Assert.Equal("identity_mismatch", failure.Code);
    }

    [Fact]
    public async Task AHandshakeCutShortIsNotReportedAsAnotherServer()
    {
        using var api = new AureliaApi(new FailingTransport(new IOException("connection reset")));
        var failure = await Assert.ThrowsAsync<AureliaApiException>(() => api.ServerInfoAsync(Server, TestContext.Current.CancellationToken));
        Assert.NotEqual("identity_mismatch", failure.Code);
        Assert.Equal(AureliaApiException.Unreachable().Code, failure.Code);
    }
}

public sealed class KeyringFailureMessageTests
{
    [Fact]
    public void OnlyAMissingSecretServiceAsksToInstallAKeyring()
    {
        var missing = Aurelia.Linux.Core.Platform.SecretServiceCredentialStore.Unavailable(
            new InvalidOperationException("org.freedesktop.DBus.Error.ServiceUnknown: The name org.freedesktop.secrets was not provided"));
        Assert.Contains("Install and start", missing.Message, StringComparison.Ordinal);
        var refused = Aurelia.Linux.Core.Platform.SecretServiceCredentialStore.Unavailable(
            new InvalidOperationException("org.freedesktop.DBus.Error.NoReply: Did not receive a reply"));
        Assert.DoesNotContain("Install", refused.Message, StringComparison.Ordinal);
        Assert.Contains("keyring", refused.Message, StringComparison.Ordinal);
    }
}
