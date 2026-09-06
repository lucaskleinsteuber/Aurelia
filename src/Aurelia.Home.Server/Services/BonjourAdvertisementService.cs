using Aurelia.Home.Server.Data;
using Haukcode.Mdns;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Home.Server.Services;

public sealed class BonjourAdvertisementService(
    ServerRuntimeOptions runtime,
    IServiceScopeFactory scopeFactory,
    ILogger<BonjourAdvertisementService> logger) : IHostedService, IAsyncDisposable
{
    public const string ServiceType = "_aurelia-home._tcp";

    private static readonly Action<ILogger, Guid, Exception?> DiscoveryStarted =
        LoggerMessage.Define<Guid>(
            LogLevel.Information,
            new EventId(4001, nameof(DiscoveryStarted)),
            "Bonjour discovery is available for Aurelia Home server {ServerId}.");

    private static readonly Action<ILogger, Exception?> DiscoveryUnavailable =
        LoggerMessage.Define(
            LogLevel.Warning,
            new EventId(4002, nameof(DiscoveryUnavailable)),
            "Bonjour discovery could not start. Manual server addresses remain available.");

    private MdnsAdvertiser? advertiser;

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (!runtime.LanAccessEnabled)
        {
            return;
        }

        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
        var identity = await database.ServerIdentities
            .AsNoTracking()
            .SingleAsync(candidate => candidate.Id == 1, cancellationToken);
        var profile = CreateProfile(runtime, identity.ServerId);

        try
        {
            advertiser = new MdnsAdvertiser(profile);
            advertiser.Start();
            DiscoveryStarted(logger, identity.ServerId, null);
        }
        catch (Exception exception) when (exception is IOException
            or InvalidOperationException
            or System.Net.Sockets.SocketException)
        {
            advertiser?.Dispose();
            advertiser = null;
            DiscoveryUnavailable(logger, null);
        }
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        advertiser?.Dispose();
        advertiser = null;
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        advertiser?.Dispose();
        advertiser = null;
        return ValueTask.CompletedTask;
    }

    public static ServiceProfile CreateProfile(ServerRuntimeOptions runtime, Guid serverId)
    {
        var instanceSuffix = serverId.ToString("N")[..8];
        var instanceName = $"{runtime.ServerName} {instanceSuffix}";
        return new ServiceProfile(
            instanceName,
            ServiceType,
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
}
