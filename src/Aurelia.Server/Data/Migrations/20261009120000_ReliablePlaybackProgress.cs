using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace Aurelia.Server.Data.Migrations;

[DbContext(typeof(AureliaDbContext))]
[Migration("20261009120000_ReliablePlaybackProgress")]
public sealed class ReliablePlaybackProgress : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.AddColumn<long>("Revision", "PlaybackProgress", nullable: false, defaultValue: 1L);
        migrationBuilder.AddColumn<Guid>("LastMutationId", "PlaybackProgress", nullable: true);
        migrationBuilder.AddColumn<string>("LastMutationFingerprint", "PlaybackProgress", maxLength: 64, nullable: true);
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        // All three columns are unindexed protocol bookkeeping. SQLite supports
        // their direct removal; do not request an EF rebuild against the earlier
        // durable-sync migration, which intentionally has no target model.
        migrationBuilder.Sql("""
            ALTER TABLE "PlaybackProgress" DROP COLUMN "LastMutationFingerprint";
            ALTER TABLE "PlaybackProgress" DROP COLUMN "LastMutationId";
            ALTER TABLE "PlaybackProgress" DROP COLUMN "Revision";
            """);
    }
}
