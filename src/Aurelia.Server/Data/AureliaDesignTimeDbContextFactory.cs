using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace Aurelia.Server.Data;

public sealed class AureliaDesignTimeDbContextFactory
    : IDesignTimeDbContextFactory<AureliaDbContext>
{
    public AureliaDbContext CreateDbContext(string[] args)
    {
        var databasePath = Path.Combine(Path.GetTempPath(), "aurelia-design.db");
        var options = new DbContextOptionsBuilder<AureliaDbContext>()
            .UseSqlite($"Data Source={databasePath}")
            .Options;

        return new AureliaDbContext(options);
    }
}
