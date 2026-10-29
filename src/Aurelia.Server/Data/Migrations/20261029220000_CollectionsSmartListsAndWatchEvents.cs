using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace Aurelia.Server.Data.Migrations;

[DbContext(typeof(AureliaDbContext))]
[Migration("20261029220000_CollectionsSmartListsAndWatchEvents")]
public sealed class CollectionsSmartListsAndWatchEvents : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.AddColumn<Guid>(
            name: "UserId",
            table: "MediaCollections",
            type: "TEXT",
            nullable: true);

        migrationBuilder.AddColumn<bool>(
            name: "IsSmart",
            table: "MediaCollections",
            type: "INTEGER",
            nullable: false,
            defaultValue: false);

        migrationBuilder.AddColumn<string>(
            name: "SmartRulesJson",
            table: "MediaCollections",
            type: "TEXT",
            nullable: true);

        migrationBuilder.CreateIndex(
            name: "IX_MediaCollections_UserId",
            table: "MediaCollections",
            column: "UserId");

        migrationBuilder.CreateTable(
            name: "WatchEvents",
            columns: table => new
            {
                Id = table.Column<Guid>(type: "TEXT", nullable: false),
                UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                Timestamp = table.Column<long>(type: "INTEGER", nullable: false),
                PositionMilliseconds = table.Column<long>(type: "INTEGER", nullable: false),
                DurationMilliseconds = table.Column<long>(type: "INTEGER", nullable: false),
                SecondsWatched = table.Column<long>(type: "INTEGER", nullable: false),
                IsCompleted = table.Column<bool>(type: "INTEGER", nullable: false)
            },
            constraints: table =>
            {
                table.PrimaryKey("PK_WatchEvents", x => x.Id);
                table.ForeignKey(
                    name: "FK_WatchEvents_MediaItems_MediaItemId",
                    column: x => x.MediaItemId,
                    principalTable: "MediaItems",
                    principalColumn: "Id",
                    onDelete: ReferentialAction.Cascade);
                table.ForeignKey(
                    name: "FK_WatchEvents_Users_UserId",
                    column: x => x.UserId,
                    principalTable: "Users",
                    principalColumn: "Id",
                    onDelete: ReferentialAction.Cascade);
            });

        migrationBuilder.CreateIndex(
            name: "IX_WatchEvents_MediaItemId",
            table: "WatchEvents",
            column: "MediaItemId");

        migrationBuilder.CreateIndex(
            name: "IX_WatchEvents_UserId_Timestamp",
            table: "WatchEvents",
            columns: ["UserId", "Timestamp"]);
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropTable(name: "WatchEvents");

        migrationBuilder.DropIndex(
            name: "IX_MediaCollections_UserId",
            table: "MediaCollections");

        migrationBuilder.Sql("ALTER TABLE MediaCollections DROP COLUMN UserId;");
        migrationBuilder.Sql("ALTER TABLE MediaCollections DROP COLUMN IsSmart;");
        migrationBuilder.Sql("ALTER TABLE MediaCollections DROP COLUMN SmartRulesJson;");
    }
}
