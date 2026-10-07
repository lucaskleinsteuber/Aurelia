using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace Aurelia.Server.Data.Migrations;

// Internal protocol bookkeeping, deliberately not an actor-filtered catalog entity.
[DbContext(typeof(AureliaDbContext))]
[Migration("20261004150000_DurableSyncHistory")]
public sealed class DurableSyncHistory : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql("""
            CREATE TABLE "SyncHistoryState" (
                "Id" INTEGER NOT NULL PRIMARY KEY CHECK ("Id" = 1),
                "Generation" TEXT NOT NULL,
                "RetainedFloor" INTEGER NOT NULL,
                "HighWater" INTEGER NOT NULL);
            INSERT INTO "SyncHistoryState"
                SELECT 1, lower(hex(randomblob(16))),
                    coalesce(min("Cursor") - 1, 0), coalesce(max("Cursor"), 0) FROM "SyncChanges";
            CREATE TRIGGER "SyncHistoryHighWater" AFTER INSERT ON "SyncChanges"
            BEGIN
                UPDATE "SyncHistoryState" SET "HighWater" = max("HighWater", NEW."Cursor") WHERE "Id" = 1;
            END;
            """);
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql("DROP TRIGGER IF EXISTS \"SyncHistoryHighWater\"; DROP TABLE \"SyncHistoryState\";");
    }
}
