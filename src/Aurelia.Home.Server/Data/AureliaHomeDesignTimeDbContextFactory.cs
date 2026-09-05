using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace Aurelia.Home.Server.Data;

public sealed class AureliaHomeDesignTimeDbContextFactory
    : IDesignTimeDbContextFactory<AureliaHomeDbContext>
{
    public AureliaHomeDbContext CreateDbContext(string[] args)
    {
        var databasePath = Path.Combine(Path.GetTempPath(), "aurelia-home-design.db");
        var options = new DbContextOptionsBuilder<AureliaHomeDbContext>()
            .UseSqlite($"Data Source={databasePath}")
            .Options;

        return new AureliaHomeDbContext(options);
    }
}
