using System.Text.Json.Nodes;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;

namespace Aurelia.Linux.Core.Management;

public sealed record HostOperationStatus(Guid Id, string Kind, string State, DateTimeOffset? ConfirmBefore, int? HttpsPort);

public sealed record ConfirmedNetwork(StoredServer Server, ProfileSession Profile);

/// <summary>
/// A network change is temporary until the same paired device reconnects with its pinned key,
/// opens its owner profile and confirms management on the new address. Failed or abandoned trials
/// are rolled back by the server host, including when the app closes.
/// </summary>
public sealed class NetworkTrial(AureliaApi api, StoredServer original, ProfileSession owner, TimeProvider? time = null)
{
    private readonly TimeProvider clock = time ?? TimeProvider.System;

    public HostOperationStatus? Operation { get; private set; }

    public StoredServer? Candidate { get; private set; }

    public static JsonObject Settings(JsonObject stored, string name, bool lan, int port, bool advertise, string networks)
    {
        name = name.Trim();
        if (name.Length is 0 or > 128)
            throw new AureliaApiException(400, "invalid_server_name", "Enter a server name of up to 128 characters.");
        if (port is < 1024 or > 65535 || port == 43110)
            throw new AureliaApiException(400, "invalid_port", "Choose an HTTPS port from 1024 to 65535 other than 43110.");
        var candidate = (JsonObject)stored.DeepClone();
        candidate["serverName"] = name;
        candidate["lanAccessEnabled"] = lan;
        candidate["lanHttpsPort"] = port;
        candidate["bonjourEnabled"] = advertise;
        var ranges = networks.Split(['\r', '\n', ','], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        candidate["allowedNetworks"] = ranges.Length == 0 ? null : new JsonArray(ranges.Select(range => (JsonNode?)JsonValue.Create(range)).ToArray());
        return candidate;
    }

    public async Task<HostOperationStatus> StartAsync(ManagementClient management, JsonObject settings, bool confirmDisconnect)
    {
        if (owner.User.Role != Contracts.UserRole.Owner) throw new AureliaApiException(403, "owner_required", "Only the server's owner can do this.");
        var lan = settings["lanAccessEnabled"]!.GetValue<bool>();
        if (!lan && !original.LocallyManaged && !ServerAddress.IsLoopback(original.Address))
            throw new AureliaApiException(400, "local_connection_required", "Turn off home network access on the server computer itself.");
        var operation = await management.StartNetworkTrialAsync(settings, confirmDisconnect);
        if (operation.Id == Guid.Empty || operation.Kind != "network" || operation.State != "awaitingConfirmation"
            || operation.ConfirmBefore is not { } deadline || deadline <= clock.GetUtcNow())
            throw AureliaApiException.InvalidResponse();
        Candidate = original with
        {
            Address = new UriBuilder(original.Address) { Host = lan ? original.Address.Host : "127.0.0.1", Port = settings["lanHttpsPort"]!.GetValue<int>() }.Uri,
            Name = settings["serverName"]!.GetValue<string>(),
        };
        Operation = operation;
        return operation;
    }

    public async Task<ConfirmedNetwork> ConfirmAsync(string pin, string password, IReadOnlyList<string> capabilities, CancellationToken cancellation = default)
    {
        var candidate = Candidate ?? throw new InvalidOperationException("Start a network trial first.");
        var deadline = Operation?.ConfirmBefore ?? throw new InvalidOperationException("Start a network trial first.");
        var remaining = deadline - clock.GetUtcNow();
        if (remaining <= TimeSpan.Zero) throw Expired();
        if (!ProfilePin.IsValid(pin)) throw new AureliaApiException(400, "invalid_profile_pin", "Enter your Profile PIN with four to eight digits.");
        using var timeout = new CancellationTokenSource(remaining, clock);
        using var request = CancellationTokenSource.CreateLinkedTokenSource(cancellation, timeout.Token);
        ProfileSession? fresh = null;
        var confirmed = false;
        try
        {
            // A trial restarts the server, ending profile and management sessions kept in memory.
            // Wait for that restart, then check its identity before sending either credential.
            for (; ; )
            {
                try
                {
                    await api.ServerInfoAsync(candidate, request.Token, TimeSpan.FromSeconds(3));
                    // A name or firewall-only change may keep the same address. Do not confirm
                    // against the old process before its scheduled restart has actually happened.
                    var oldConnection = new ManagementClient(api, new LibraryClient(api, candidate, owner, capabilities), _ => Task.FromResult<string?>(null));
                    try
                    {
                        await oldConnection.GetAsync<Contracts.UserSummary>("/api/v1/auth/me", request.Token);
                    }
                    catch (AureliaApiException failure) when (failure.IsAuthenticationFailure)
                    {
                        break;
                    }
                    await Task.Delay(TimeSpan.FromSeconds(1), clock, request.Token);
                }
                catch (AureliaApiException failure) when (failure.IsUnreachable)
                {
                    await Task.Delay(TimeSpan.FromSeconds(1), clock, request.Token);
                }
            }
            fresh = await api.UnlockProfileAsync(candidate, owner.User.Id, pin, request.Token);
            if (fresh.User.Role != Contracts.UserRole.Owner) throw new AureliaApiException(403, "owner_required", "Only the server's owner can do this.");
            var client = new ManagementClient(api, new LibraryClient(api, candidate, fresh, capabilities), _ => Task.FromResult<string?>(password));
            await client.UnlockAsync("Confirm the new network connection.", request.Token);
            await client.ConfirmNetworkAsync(Operation!.Id, request.Token);
            confirmed = true;
            return new ConfirmedNetwork(candidate, fresh);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested && !cancellation.IsCancellationRequested)
        {
            throw Expired();
        }
        finally
        {
            if (fresh is not null && !confirmed)
            {
                try { await api.EndProfileAsync(candidate, fresh, CancellationToken.None); }
                catch (AureliaApiException) { }
            }
        }
    }

    private static AureliaApiException Expired() => new(409, "network_confirmation_expired", "The 60-second trial ended. The previous network settings return automatically; sign in again and retry.");
}
