using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class MediaEditing : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            // Native SQLite ALTERs keep existing FTS triggers and tables intact.
            // EF's DROP COLUMN table rebuild temporarily removes their source tables.
            migrationBuilder.Sql("""
                ALTER TABLE "MediaMetadata" ADD COLUMN "EditorRevision" INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE "MediaMetadata" ADD COLUMN "ManualBackdropId" TEXT NULL;
                ALTER TABLE "MediaMetadata" ADD COLUMN "ManualFieldsJson" TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE "MediaMetadata" ADD COLUMN "ManualPosterId" TEXT NULL;
                ALTER TABLE "MediaMetadata" ADD COLUMN "ManualReleaseYear" INTEGER NULL;
                ALTER TABLE "MediaMetadata" ADD COLUMN "ProviderCreditsJson" TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE "MediaItems" ADD COLUMN "ManualSourceBinding" INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE "MediaCredits" ADD COLUMN "ProfileAssetId" TEXT NULL;
                ALTER TABLE "ArtworkAssets" ADD COLUMN "CropJson" TEXT NULL;
                ALTER TABLE "ArtworkAssets" ADD COLUMN "IsManual" INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE "ArtworkAssets" ADD COLUMN "OriginalFilePath" TEXT NULL;
                """);

            migrationBuilder.CreateTable(
                name: "LibraryMutations",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    State = table.Column<string>(type: "TEXT", maxLength: 32, nullable: false),
                    RemovedItems = table.Column<int>(type: "INTEGER", nullable: false),
                    FilesJson = table.Column<string>(type: "TEXT", nullable: false),
                    Error = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_LibraryMutations", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "MediaExclusions",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    LibraryRootId = table.Column<Guid>(type: "TEXT", nullable: false),
                    RelativePath = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    NormalizedSourcePath = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    FileSystemIdentity = table.Column<string>(type: "TEXT", nullable: true),
                    IsDirectory = table.Column<bool>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MediaExclusions", x => x.Id);
                    table.ForeignKey(
                        name: "FK_MediaExclusions_LibraryRoots_LibraryRootId",
                        column: x => x.LibraryRootId,
                        principalTable: "LibraryRoots",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_MediaExclusions_LibraryRootId_NormalizedSourcePath",
                table: "MediaExclusions",
                columns: ["LibraryRootId", "NormalizedSourcePath"],
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "LibraryMutations");

            migrationBuilder.DropTable(
                name: "MediaExclusions");

            migrationBuilder.Sql("""
                ALTER TABLE "MediaMetadata" DROP COLUMN "EditorRevision";
                ALTER TABLE "MediaMetadata" DROP COLUMN "ManualBackdropId";
                ALTER TABLE "MediaMetadata" DROP COLUMN "ManualFieldsJson";
                ALTER TABLE "MediaMetadata" DROP COLUMN "ManualPosterId";
                ALTER TABLE "MediaMetadata" DROP COLUMN "ManualReleaseYear";
                ALTER TABLE "MediaMetadata" DROP COLUMN "ProviderCreditsJson";
                ALTER TABLE "MediaItems" DROP COLUMN "ManualSourceBinding";
                ALTER TABLE "MediaCredits" DROP COLUMN "ProfileAssetId";
                ALTER TABLE "ArtworkAssets" DROP COLUMN "CropJson";
                ALTER TABLE "ArtworkAssets" DROP COLUMN "IsManual";
                ALTER TABLE "ArtworkAssets" DROP COLUMN "OriginalFilePath";
                """);
        }
    }
}
