using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace Tarven.Server.Data;

public sealed class TarvenDesignTimeDbContextFactory
    : IDesignTimeDbContextFactory<TarvenDbContext>
{
    public TarvenDbContext CreateDbContext(string[] args)
    {
        var databasePath = Path.Combine(Path.GetTempPath(), "tarven-design.db");
        var options = new DbContextOptionsBuilder<TarvenDbContext>()
            .UseSqlite($"Data Source={databasePath}")
            .Options;

        return new TarvenDbContext(options);
    }
}
