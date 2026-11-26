using System.Net;
using System.Net.Http.Json;
using System.Net.NetworkInformation;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class WakeOnLanTests
{
    [Fact]
    public void WakeAddressesAreSixByteHardwareAddresses()
    {
        Assert.Equal("02:00:5e:10:00:01", WakeOnLan.Format(PhysicalAddress.Parse("02-00-5E-10-00-01")));
        Assert.Null(WakeOnLan.Format(PhysicalAddress.None));
        Assert.Null(WakeOnLan.Format(PhysicalAddress.Parse("00-00-00-00-00-00")));
        Assert.All(WakeOnLan.LocalAddresses(), address => Assert.Matches("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", address));
    }

    // Audit SRV-SEC-009 Phase 1: authenticated GET /api/v1/profiles returns Hosting and
    // WakeOnLanAddresses matching GET /api/v1/server/info, while unauthenticated callers get 401
    // and /api/v1/server/info keeps WakeOnLanAddresses for Phase 1 compatibility.
    [Fact]
    public async Task ProfilePickerReturnsWakeOnLanAndHostingForAuthenticatedDevices()
    {
        using var factory = new AureliaServerFactory(settings: new Dictionary<string, string>
        {
            ["Aurelia:LanAccessEnabled"] = "true",
        });
        using var client = factory.CreateClient();
        await ApiTestClient.SetupOwnerAsync(client);

        using (var anonymous = await client.GetAsync("/api/v1/profiles"))
            Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);

        using var loginResponse = await client.PostAsJsonAsync("/api/v1/auth/login",
            new LoginRequest("lucas", "correct horse battery staple", "Synthetic Paired Device"), ApiTestClient.JsonOptions);
        loginResponse.EnsureSuccessStatusCode();
        var device = await ApiTestClient.ReadAsync<AuthenticationResponse>(loginResponse);

        using var infoResponse = await client.GetAsync("/api/v1/server/info");
        infoResponse.EnsureSuccessStatusCode();
        var info = await ApiTestClient.ReadAsync<ServerInfoResponse>(infoResponse);
        Assert.NotNull(info.Hosting);
        Assert.NotNull(info.WakeOnLanAddresses);

        using var pickerRequest = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/profiles", device.Token);
        using var pickerResponse = await client.SendAsync(pickerRequest);
        pickerResponse.EnsureSuccessStatusCode();
        var picker = await ApiTestClient.ReadAsync<ProfilePickerResponse>(pickerResponse);

        Assert.Equal(info.Hosting, picker.Hosting);
        Assert.Equal(info.WakeOnLanAddresses, picker.WakeOnLanAddresses);
    }

    [Fact]
    public async Task ProfilePickerOmitsWakeOnLanWhenLanAccessIsDisabled()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        await ApiTestClient.SetupOwnerAsync(client);

        using var loginResponse = await client.PostAsJsonAsync("/api/v1/auth/login",
            new LoginRequest("lucas", "correct horse battery staple", "Synthetic Local Device"), ApiTestClient.JsonOptions);
        loginResponse.EnsureSuccessStatusCode();
        var device = await ApiTestClient.ReadAsync<AuthenticationResponse>(loginResponse);

        using var infoResponse = await client.GetAsync("/api/v1/server/info");
        infoResponse.EnsureSuccessStatusCode();
        var info = await ApiTestClient.ReadAsync<ServerInfoResponse>(infoResponse);
        Assert.Null(info.WakeOnLanAddresses);

        using var pickerRequest = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/profiles", device.Token);
        using var pickerResponse = await client.SendAsync(pickerRequest);
        pickerResponse.EnsureSuccessStatusCode();
        var picker = await ApiTestClient.ReadAsync<ProfilePickerResponse>(pickerResponse);

        Assert.Equal(info.Hosting, picker.Hosting);
        Assert.Null(picker.WakeOnLanAddresses);
    }
}
