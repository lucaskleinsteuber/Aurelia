using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class QueryWarmerTests
{
    [Fact]
    public async Task WarmingRunsHomeOnceAProfileExistsAndChangesNothing()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var warmer = new Aurelia.Server.Services.QueryWarmer(factory.Services.GetRequiredService<IServiceScopeFactory>(),
            NullLogger<Aurelia.Server.Services.QueryWarmer>.Instance);
        // Before setup there is nobody whose Home could be prepared.
        Assert.False(await warmer.WarmAsync(CancellationToken.None));

        await ApiTestClient.SetupOwnerAsync(client);
        long Changes()
        {
            using var scope = factory.Services.CreateScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            return database.Users.AsNoTracking().Count() + database.PlaybackProgress.AsNoTracking().Count() + database.MediaItems.AsNoTracking().Count();
        }
        var before = Changes();
        Assert.True(await warmer.WarmAsync(CancellationToken.None));
        Assert.Equal(before, Changes());
    }
}
