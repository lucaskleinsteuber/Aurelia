using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

// This probe is independent of scan scheduling and never reads media contents.
public sealed class LibraryReachabilityService(AureliaDbContext database)
{
    public async Task RefreshAsync(CancellationToken cancellationToken)
    {
        foreach (var root in await database.LibraryRoots.ToListAsync(cancellationToken))
        {
            var availability = Probe(root.Path);
            if (root.Availability == availability) continue;
            root.Availability = availability;
            root.LastObservedAt = DateTimeOffset.UtcNow;
            root.LastError = availability == LibraryAvailability.Error ? "The media location could not be accessed."
                : availability == LibraryAvailability.Unavailable ? "The media drive is unavailable." : null;
        }
        await database.SaveChangesAsync(cancellationToken);
    }

    internal static MediaAvailability ProbeFile(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 ? MediaAvailability.Error : MediaAvailability.Available;
        }
        catch (FileNotFoundException) { return MediaAvailability.Missing; }
        catch (DirectoryNotFoundException) { return MediaAvailability.Missing; }
        catch (UnauthorizedAccessException) { return MediaAvailability.Error; }
        catch (IOException) { return MediaAvailability.Error; }
    }

    internal static LibraryAvailability Probe(string path)
    {
        try
        {
            _ = File.GetAttributes(path);
            var directory = new DirectoryInfo(path);
            if (directory.LinkTarget is not null) return LibraryAvailability.Error;
            _ = directory.EnumerateFileSystemInfos().Take(1).ToArray();
            return LibraryAvailability.Available;
        }
        catch (UnauthorizedAccessException) { return LibraryAvailability.Error; }
        catch (DirectoryNotFoundException) { return LibraryAvailability.Unavailable; }
        catch (FileNotFoundException) { return LibraryAvailability.Unavailable; }
        catch (IOException) { return LibraryAvailability.Error; }
    }
}

public sealed class LibraryReachabilityWorker(IServiceScopeFactory scopes, ILogger<LibraryReachabilityWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var recovery = new StorageRecovery(logger, "library reachability");
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                await recovery.RunAsync(async () =>
                {
                    await using var scope = scopes.CreateAsyncScope();
                    await scope.ServiceProvider.GetRequiredService<LibraryReachabilityService>().RefreshAsync(stoppingToken);
                }, stoppingToken);
                await Task.Delay(TimeSpan.FromSeconds(25), stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }
}
