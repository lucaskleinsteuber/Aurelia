using System.Net.NetworkInformation;
using System.Threading.Channels;
using Aurelia.Server.Data;
using Haukcode.Mdns;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class BonjourAdvertisementService(
    ServerRuntimeOptions runtime,
    ServerConfigurationStore configuration,
    IServiceScopeFactory scopeFactory,
    ILogger<BonjourAdvertisementService> logger,
    TimeProvider timeProvider) : BackgroundService, IAsyncDisposable
{
    private static readonly string[] ServiceTypes = ["_aurelia._tcp", "_aurelia-home._tcp"];
    private static readonly int[] RetrySeconds = [3, 6, 12, 30];
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
    private readonly object lifecycleGate = new();
    private readonly Channel<bool> renewals = Channel.CreateBounded<bool>(new BoundedChannelOptions(1)
    {
        FullMode = BoundedChannelFullMode.DropWrite,
        SingleReader = true,
    });
    private bool stopped;
    private bool observingNetwork;
    private Guid serverId;

    public override async Task StartAsync(CancellationToken cancellationToken)
    {
        if (!runtime.LanAccessEnabled || !configuration.Current.BonjourEnabled) return;
        await using var scope = scopeFactory.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        serverId = (await database.ServerIdentities.AsNoTracking()
            .SingleAsync(candidate => candidate.Id == 1, cancellationToken)).ServerId;
        lock (lifecycleGate)
        {
            if (stopped) return;
            NetworkChange.NetworkAddressChanged += NetworkChanged;
            NetworkChange.NetworkAvailabilityChanged += NetworkAvailabilityChanged;
            observingNetwork = true;
        }
        await base.StartAsync(cancellationToken);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var monitorCancellation = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        var wakeMonitor = MonitorWakeAsync(monitorCancellation.Token);
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                await PublishWithRetriesAsync(stoppingToken);
                _ = await renewals.Reader.ReadAsync(stoppingToken);
                // Coalesce interface changes before replacing both announcements.
                await Task.Delay(TimeSpan.FromSeconds(1), timeProvider, stoppingToken);
                while (renewals.Reader.TryRead(out _)) { }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        finally
        {
            await monitorCancellation.CancelAsync();
            await wakeMonitor;
            DisposeAdvertisers();
        }
    }

    private async Task PublishWithRetriesAsync(CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (attempt > 0)
                await Task.Delay(RetryDelay(attempt - 1), timeProvider, cancellationToken);
            try
            {
                lock (lifecycleGate)
                {
                    if (stopped) return;
                    DisposeAdvertisersUnderLock();
                    foreach (var serviceType in ServiceTypes)
                    {
                        var advertiser = new MdnsAdvertiser(CreateProfile(runtime, serverId, serviceType));
                        advertisers.Add(advertiser);
                        advertiser.Start();
                    }
                }
                DiscoveryStarted(logger, serverId, null);
                return;
            }
            catch (Exception exception) when (exception is IOException
                or InvalidOperationException or System.Net.Sockets.SocketException)
            {
                DisposeAdvertisers();
                if (attempt == 4) DiscoveryUnavailable(logger, null);
            }
        }
    }

    private async Task MonitorWakeAsync(CancellationToken cancellationToken)
    {
        var previous = timeProvider.GetUtcNow();
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(15), timeProvider, cancellationToken);
                var current = timeProvider.GetUtcNow();
                if (ShouldRenewAfterPause(previous, current)) renewals.Writer.TryWrite(true);
                previous = current;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    }

    internal static TimeSpan RetryDelay(int attempt)
        => TimeSpan.FromSeconds(RetrySeconds[Math.Clamp(attempt, 0, 3)]);

    internal static bool ShouldRenewAfterPause(DateTimeOffset previous, DateTimeOffset current)
        => current - previous > TimeSpan.FromSeconds(40);

    private void NetworkChanged(object? sender, EventArgs arguments) => renewals.Writer.TryWrite(true);
    private void NetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs arguments)
        => renewals.Writer.TryWrite(true);

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        StopObserving();
        await base.StopAsync(cancellationToken);
        DisposeAdvertisers();
    }

    public override void Dispose()
    {
        StopObserving();
        base.Dispose();
        DisposeAdvertisers();
        GC.SuppressFinalize(this);
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }

    private void StopObserving()
    {
        lock (lifecycleGate)
        {
            stopped = true;
            if (!observingNetwork) return;
            NetworkChange.NetworkAddressChanged -= NetworkChanged;
            NetworkChange.NetworkAvailabilityChanged -= NetworkAvailabilityChanged;
            observingNetwork = false;
        }
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
        lock (lifecycleGate) DisposeAdvertisersUnderLock();
    }

    private void DisposeAdvertisersUnderLock()
    {
        var owned = advertisers.ToArray();
        advertisers.Clear();
        foreach (var advertiser in owned) advertiser.Dispose();
    }
}
