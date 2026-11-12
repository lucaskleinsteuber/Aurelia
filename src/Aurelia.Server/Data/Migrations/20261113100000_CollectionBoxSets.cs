using System;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations;

[DbContext(typeof(AureliaDbContext))]
[Migration("20261113100000_CollectionBoxSets")]
public sealed class CollectionBoxSets : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.AddColumn<string>(
            name: "Overview",
            table: "MediaCollections",
            type: "TEXT",
            maxLength: 8192,
            nullable: true);

        migrationBuilder.AddColumn<string>(
            name: "SortMode",
            table: "MediaCollections",
            type: "TEXT",
            maxLength: 16,
            nullable: true);

        migrationBuilder.AddColumn<string>(
            name: "ProviderPosterPath",
            table: "MediaCollections",
            type: "TEXT",
            maxLength: 512,
            nullable: true);

        migrationBuilder.AddColumn<string>(
            name: "ProviderBackdropPath",
            table: "MediaCollections",
            type: "TEXT",
            maxLength: 512,
            nullable: true);

        migrationBuilder.AddColumn<Guid>(
            name: "PosterAssetId",
            table: "MediaCollections",
            type: "TEXT",
            nullable: true);

        migrationBuilder.AddColumn<Guid>(
            name: "BackdropAssetId",
            table: "MediaCollections",
            type: "TEXT",
            nullable: true);

        migrationBuilder.CreateTable(
            name: "CollectionArtworkAssets",
            columns: table => new
            {
                Id = table.Column<Guid>(type: "TEXT", nullable: false),
                CollectionId = table.Column<Guid>(type: "TEXT", nullable: false),
                Kind = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                ProviderPath = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                RelativeFilePath = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                ContentType = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                ContentLength = table.Column<long>(type: "INTEGER", nullable: false),
                Revision = table.Column<long>(type: "INTEGER", nullable: false, defaultValue: 1L),
                IsManual = table.Column<bool>(type: "INTEGER", nullable: false),
                OriginalFilePath = table.Column<string>(type: "TEXT", nullable: true),
                CropJson = table.Column<string>(type: "TEXT", nullable: true),
                CreatedAt = table.Column<long>(type: "INTEGER", nullable: false)
            },
            constraints: table =>
            {
                table.PrimaryKey("PK_CollectionArtworkAssets", x => x.Id);
                table.ForeignKey(
                    name: "FK_CollectionArtworkAssets_MediaCollections_CollectionId",
                    column: x => x.CollectionId,
                    principalTable: "MediaCollections",
                    principalColumn: "Id",
                    onDelete: ReferentialAction.Cascade);
            });

        migrationBuilder.CreateIndex(
            name: "IX_CollectionArtworkAssets_CollectionId_Kind",
            table: "CollectionArtworkAssets",
            columns: ["CollectionId", "Kind"]);

        migrationBuilder.CreateIndex(
            name: "IX_CollectionArtworkAssets_RelativeFilePath",
            table: "CollectionArtworkAssets",
            column: "RelativeFilePath",
            unique: true);

        migrationBuilder.Sql("""
            CREATE TABLE "MediaCollectionMembers_New" (
                "Id" TEXT NOT NULL CONSTRAINT "PK_MediaCollectionMembers" PRIMARY KEY,
                "CollectionId" TEXT NOT NULL,
                "MediaItemId" TEXT NOT NULL,
                "SeasonNumber" INTEGER NULL,
                "SortOrder" INTEGER NOT NULL,
                CONSTRAINT "FK_MediaCollectionMembers_MediaCollections_CollectionId" FOREIGN KEY ("CollectionId") REFERENCES "MediaCollections" ("Id") ON DELETE CASCADE,
                CONSTRAINT "FK_MediaCollectionMembers_MediaItems_MediaItemId" FOREIGN KEY ("MediaItemId") REFERENCES "MediaItems" ("Id") ON DELETE CASCADE
            );
            INSERT INTO "MediaCollectionMembers_New" ("Id", "CollectionId", "MediaItemId", "SeasonNumber", "SortOrder")
            SELECT upper(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' || substr('89AB', 1 + (abs(random()) % 4), 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6))),
                   "CollectionId", "MediaItemId", NULL, "SortOrder"
            FROM "MediaCollectionMembers";
            DROP TABLE "MediaCollectionMembers";
            ALTER TABLE "MediaCollectionMembers_New" RENAME TO "MediaCollectionMembers";
            """);

        migrationBuilder.CreateIndex(
            name: "IX_MediaCollectionMembers_MediaItemId",
            table: "MediaCollectionMembers",
            column: "MediaItemId");

        migrationBuilder.CreateIndex(
            name: "IX_MediaCollectionMembers_CollectionId_MediaItemId",
            table: "MediaCollectionMembers",
            columns: ["CollectionId", "MediaItemId"],
            unique: true,
            filter: "\"SeasonNumber\" IS NULL");

        migrationBuilder.CreateIndex(
            name: "IX_MediaCollectionMembers_CollectionId_MediaItemId_SeasonNumber",
            table: "MediaCollectionMembers",
            columns: ["CollectionId", "MediaItemId", "SeasonNumber"],
            unique: true,
            filter: "\"SeasonNumber\" IS NOT NULL");
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropTable(name: "CollectionArtworkAssets");

        migrationBuilder.Sql("""
            CREATE TABLE "MediaCollectionMembers_Old" (
                "CollectionId" TEXT NOT NULL,
                "MediaItemId" TEXT NOT NULL,
                "SortOrder" INTEGER NOT NULL,
                CONSTRAINT "PK_MediaCollectionMembers" PRIMARY KEY ("CollectionId", "MediaItemId"),
                CONSTRAINT "FK_MediaCollectionMembers_MediaCollections_CollectionId" FOREIGN KEY ("CollectionId") REFERENCES "MediaCollections" ("Id") ON DELETE CASCADE,
                CONSTRAINT "FK_MediaCollectionMembers_MediaItems_MediaItemId" FOREIGN KEY ("MediaItemId") REFERENCES "MediaItems" ("Id") ON DELETE CASCADE
            );
            INSERT OR IGNORE INTO "MediaCollectionMembers_Old" ("CollectionId", "MediaItemId", "SortOrder")
            SELECT "CollectionId", "MediaItemId", MIN("SortOrder")
            FROM "MediaCollectionMembers"
            GROUP BY "CollectionId", "MediaItemId";
            DROP TABLE "MediaCollectionMembers";
            ALTER TABLE "MediaCollectionMembers_Old" RENAME TO "MediaCollectionMembers";
            """);

        migrationBuilder.CreateIndex(
            name: "IX_MediaCollectionMembers_MediaItemId",
            table: "MediaCollectionMembers",
            column: "MediaItemId");

        migrationBuilder.Sql("ALTER TABLE \"MediaCollections\" DROP COLUMN \"Overview\";");
        migrationBuilder.Sql("ALTER TABLE \"MediaCollections\" DROP COLUMN \"SortMode\";");
        migrationBuilder.Sql("ALTER TABLE \"MediaCollections\" DROP COLUMN \"ProviderPosterPath\";");
        migrationBuilder.Sql("ALTER TABLE \"MediaCollections\" DROP COLUMN \"ProviderBackdropPath\";");
        migrationBuilder.Sql("ALTER TABLE \"MediaCollections\" DROP COLUMN \"PosterAssetId\";");
        migrationBuilder.Sql("ALTER TABLE \"MediaCollections\" DROP COLUMN \"BackdropAssetId\";");
    }
}
