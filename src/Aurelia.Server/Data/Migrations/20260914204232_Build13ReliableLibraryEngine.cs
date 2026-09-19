using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable
#pragma warning disable CA1861 // EF Core migration code intentionally uses generated column arrays.

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class Build13ReliableLibraryEngine : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<int>(
                name: "Attempt",
                table: "MetadataJobs",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0);

            migrationBuilder.AddColumn<long>(
                name: "CancelRequestedAt",
                table: "MetadataJobs",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.AddColumn<long>(
                name: "HeartbeatAt",
                table: "MetadataJobs",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.AddColumn<long>(
                name: "LeaseExpiresAt",
                table: "MetadataJobs",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "Mode",
                table: "MetadataJobs",
                type: "TEXT",
                maxLength: 16,
                nullable: false,
                defaultValue: "FullRefresh");

            migrationBuilder.AddColumn<string>(
                name: "FileSystemIdentity",
                table: "MediaItems",
                type: "TEXT",
                maxLength: 128,
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "Attempt",
                table: "LibraryScans",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0);

            migrationBuilder.AddColumn<long>(
                name: "CancelRequestedAt",
                table: "LibraryScans",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.AddColumn<long>(
                name: "HeartbeatAt",
                table: "LibraryScans",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.AddColumn<long>(
                name: "LeaseExpiresAt",
                table: "LibraryScans",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "TargetRelativePath",
                table: "LibraryScans",
                type: "TEXT",
                maxLength: 4096,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "Trigger",
                table: "LibraryScans",
                type: "TEXT",
                maxLength: 32,
                nullable: false,
                defaultValue: "Manual");

            migrationBuilder.AddColumn<long>(
                name: "LastObservedAt",
                table: "LibraryRoots",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "MonitoringEnabled",
                table: "LibraryRoots",
                type: "INTEGER",
                nullable: false,
                defaultValue: true);

            migrationBuilder.CreateTable(
                name: "SyncChanges",
                columns: table => new
                {
                    Cursor = table.Column<long>(type: "INTEGER", nullable: false)
                        .Annotation("Sqlite:Autoincrement", true),
                    Area = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: true),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: true),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SyncChanges", x => x.Cursor);
                });

            migrationBuilder.CreateIndex(
                name: "IX_MediaItems_Kind_Availability_CreatedAt",
                table: "MediaItems",
                columns: new[] { "Kind", "Availability", "CreatedAt" });

            migrationBuilder.CreateIndex(
                name: "IX_MediaItems_LibraryRootId_FileSystemIdentity",
                table: "MediaItems",
                columns: new[] { "LibraryRootId", "FileSystemIdentity" });

            migrationBuilder.CreateIndex(
                name: "IX_MediaItems_LibraryRootId_Kind_Year",
                table: "MediaItems",
                columns: new[] { "LibraryRootId", "Kind", "Year" });

            migrationBuilder.CreateIndex(
                name: "IX_SyncChanges_CreatedAt",
                table: "SyncChanges",
                column: "CreatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_SyncChanges_UserId_Cursor",
                table: "SyncChanges",
                columns: new[] { "UserId", "Cursor" });

            migrationBuilder.Sql("""
                CREATE VIRTUAL TABLE IF NOT EXISTS MediaSearchIndex USING fts5(
                    MediaId UNINDEXED,
                    Title,
                    OriginalTitle,
                    Details,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql("DROP TABLE IF EXISTS MediaSearchIndex;");

            migrationBuilder.DropTable(
                name: "SyncChanges");

            migrationBuilder.DropIndex(
                name: "IX_MediaItems_Kind_Availability_CreatedAt",
                table: "MediaItems");

            migrationBuilder.DropIndex(
                name: "IX_MediaItems_LibraryRootId_FileSystemIdentity",
                table: "MediaItems");

            migrationBuilder.DropIndex(
                name: "IX_MediaItems_LibraryRootId_Kind_Year",
                table: "MediaItems");

            migrationBuilder.DropColumn(
                name: "Attempt",
                table: "MetadataJobs");

            migrationBuilder.DropColumn(
                name: "CancelRequestedAt",
                table: "MetadataJobs");

            migrationBuilder.DropColumn(
                name: "HeartbeatAt",
                table: "MetadataJobs");

            migrationBuilder.DropColumn(
                name: "LeaseExpiresAt",
                table: "MetadataJobs");

            migrationBuilder.DropColumn(
                name: "Mode",
                table: "MetadataJobs");

            migrationBuilder.DropColumn(
                name: "FileSystemIdentity",
                table: "MediaItems");

            migrationBuilder.DropColumn(
                name: "Attempt",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "CancelRequestedAt",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "HeartbeatAt",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "LeaseExpiresAt",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "TargetRelativePath",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "Trigger",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "LastObservedAt",
                table: "LibraryRoots");

            migrationBuilder.DropColumn(
                name: "MonitoringEnabled",
                table: "LibraryRoots");
        }
    }
}
