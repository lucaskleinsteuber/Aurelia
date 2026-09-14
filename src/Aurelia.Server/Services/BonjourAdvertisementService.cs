using Aurelia.Server.Data;
using Haukcode.Mdns;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class BonjourAdvertisementService(
    ServerRuntimeOptions runtime,
    IServiceScopeFactory scopeFactory,
    ILogger<BonjourAdvertisementService> logger) : IHostedService, IAsyncDisposable
{
    public const string ServiceType = "_aurelia._tcp";
    public const string LegacyServiceType = "_aurelia-home._tcp";

    private static readonly Action<ILogger, Guid, Exception?> DiscoveryStarted =
        LoggerMessage.Define<Guid>(
            LogLevel.Information,
            new EventId(4001, nameof(DiscoveryStarted)),
            "Bonjour discovery is available for Aurelia server {ServerId}.");

    private static readonly Action<ILogger, Exception?> DiscoveryUnavailable =
        LoggerMessage.Define(
            LogLevel.Warning,
            new EventId(4002, nameof(DiscoveryUnavailable)),
            "Bonjour discovery could not start. Manual server addresses remain available.");

    private readonly List<MdnsAdvertiser> advertisers = [];

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (!runtime.LanAccessEnabled)
        {
            return;
        }

        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var identity = await database.ServerIdentities
            .AsNoTracking()
            .SingleAsync(candidate => candidate.Id == 1, cancellationToken);
        try
        {
            foreach (var serviceType in new[] { ServiceType, LegacyServiceType })
            {
                var advertiser = new MdnsAdvertiser(CreateProfile(runtime, identity.ServerId, serviceType));
                advertiser.Start();
                advertisers.Add(advertiser);
            }
            DiscoveryStarted(logger, identity.ServerId, null);
        }
        catch (Exception exception) when (exception is IOException
            or InvalidOperationException
            or System.Net.Sockets.SocketException)
        {
            DisposeAdvertisers();
            DiscoveryUnavailable(logger, null);
        }
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        DisposeAdvertisers();
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        DisposeAdvertisers();
        return ValueTask.CompletedTask;
    }

    public static ServiceProfile CreateProfile(ServerRuntimeOptions runtime, Guid serverId)
        => CreateProfile(runtime, serverId, ServiceType);

    private static ServiceProfile CreateProfile(
        ServerRuntimeOptions runtime,
        Guid serverId,
        string serviceType)
    {
        var instanceSuffix = serverId.ToString("N")[..8];
        var instanceName = $"{runtime.ServerName} {instanceSuffix}";
        return new ServiceProfile(
            instanceName,
            serviceType,
            checked((ushort)runtime.LanHttpsPort),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["id"] = serverId.ToString("D"),
                ["api"] = "1",
                ["tls"] = "1",
                ["port"] = runtime.LanHttpsPort.ToString(
                    System.Globalization.CultureInfo.InvariantCulture),
                ["name"] = runtime.ServerName,
            });
    }

    private void DisposeAdvertisers()
    {
        foreach (var advertiser in advertisers)
        {
            advertiser.Dispose();
        }

        advertisers.Clear();
    }
}
