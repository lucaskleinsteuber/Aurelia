using Aurelia.Contracts;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Tests;

/// <summary>A scripted server for flow and screen tests: no network, synthetic data only.</summary>
internal sealed class FakeServerApi : IAureliaServerApi
{
    public static readonly string Fingerprint = new('A', 64);
    public static readonly Guid ServerId = Guid.Parse("11111111-2222-3333-4444-555555555555");
    public static readonly WatchingProfile Owner = new(Guid.Parse("aaaaaaaa-0000-0000-0000-000000000001"), "Alex", UserRole.Owner, false, true);
    public static readonly WatchingProfile Guest = new(Guid.Parse("aaaaaaaa-0000-0000-0000-000000000002"), "Guest", UserRole.User, false, false);
    private const string Token = "synthetic-device-token-0123456789-abcdef";

    public DeviceAuthorizationState PairingResult { get; set; } = DeviceAuthorizationState.Approved;
    public int PendingPolls { get; set; } = 1;
    public Exception? InfoFailure { get; set; }
    public Exception? InspectFailure { get; set; }
    public List<string> Calls { get; } = [];

    public Task<InspectedServer> InspectAsync(Uri address, CancellationToken cancellation)
    {
        Calls.Add("inspect " + address.Authority);
        if (InspectFailure is not null) return Task.FromException<InspectedServer>(InspectFailure);
        return Task.FromResult(new InspectedServer(address, Info, Fingerprint));
    }

    public Task<ServerInfoResponse> ServerInfoAsync(StoredConnection connection, CancellationToken cancellation)
    {
        Calls.Add("info");
        return InfoFailure is null ? Task.FromResult(Info) : Task.FromException<ServerInfoResponse>(InfoFailure);
    }

    public Task<DeviceAuthorizationStartResponse> StartPairingAsync(InspectedServer server, string deviceName, CancellationToken cancellation)
    {
        Calls.Add("pair " + deviceName);
        return Task.FromResult(new DeviceAuthorizationStartResponse(Guid.NewGuid(), "48151623", new string('s', 43),
            DateTimeOffset.UtcNow.AddMinutes(5)));
    }

    public Task<DeviceAuthorizationStatusResponse> PairingStatusAsync(InspectedServer server, Guid id, string secret, CancellationToken cancellation)
    {
        Calls.Add("status");
        if (PendingPolls-- > 0) return Task.FromResult(Status(DeviceAuthorizationState.Pending));
        return Task.FromResult(PairingResult == DeviceAuthorizationState.Approved
            ? Status(DeviceAuthorizationState.Approved, new AuthenticationResponse(
                new UserSummary(Owner.Id, "Alex", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(), Token, DateTimeOffset.UtcNow.AddDays(90)))
            : Status(PairingResult));
    }

    public Task<DeviceAuthorizationStatusResponse> AcknowledgePairingAsync(Uri address, string fingerprint, Guid id, string secret, CancellationToken cancellation)
    {
        Calls.Add("ack");
        return Task.FromResult(Status(DeviceAuthorizationState.Approved) with { Acknowledged = true });
    }

    public Task CancelPairingAsync(InspectedServer server, Guid id, string secret, CancellationToken cancellation)
    {
        Calls.Add("cancel");
        return Task.CompletedTask;
    }

    public Task<ProfilePickerResponse> ProfilesAsync(StoredConnection connection, CancellationToken cancellation)
    {
        Calls.Add("profiles");
        return Task.FromResult(new ProfilePickerResponse(2, "1.5.1", false, [Owner, Guest]));
    }

    public Task<ProfileSessionResponse> UnlockProfileAsync(StoredConnection connection, Guid profileId, string? pin, CancellationToken cancellation)
    {
        Calls.Add("unlock " + (pin ?? "-"));
        var profile = profileId == Owner.Id ? Owner : Guest;
        if (profile.PinProtectionEnabled && pin != "5682")
            return Task.FromException<ProfileSessionResponse>(new AureliaApiException(401, "invalid_profile_pin", "The PIN is incorrect."));
        return Task.FromResult(new ProfileSessionResponse(new UserSummary(profile.Id, profile.Name, profile.Role, DateTimeOffset.UtcNow),
            Guid.NewGuid(), "synthetic-profile-token-0123456789-abcdef", DateTimeOffset.UtcNow.AddHours(12)));
    }

    public Task EndProfileAsync(StoredConnection connection, ProfileSessionResponse session, CancellationToken cancellation)
    {
        Calls.Add("end");
        return Task.CompletedTask;
    }

    public Task DisconnectDeviceAsync(StoredConnection connection, CancellationToken cancellation)
    {
        Calls.Add("disconnect");
        return Task.CompletedTask;
    }

    public static StoredConnection Saved(PendingPairing? pending = null) =>
        new(ServerId, "Living Room Mac", new Uri("https://192.168.1.20:43111"), Fingerprint, Token, Guid.NewGuid(), pending);

    private static ServerInfoResponse Info => new(ServerId, "Living Room Mac", "1.7.16", true, true, 43111, Fingerprint, "AAAA-AAAA");

    private static DeviceAuthorizationStatusResponse Status(DeviceAuthorizationState state, AuthenticationResponse? credential = null) =>
        new(state, DateTimeOffset.UtcNow.AddMinutes(5), 5, credential);
}

internal sealed class MemorySecretStore : ISecretStore
{
    public string? Value { get; set; }
    public string? Read() => Value;
    public void Write(string value) => Value = value;
    public void Delete() => Value = null;
}
