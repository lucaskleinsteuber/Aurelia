using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class ReliableImportPlanning : Migration
    {
        private static readonly string[] AssignmentIndexColumns = ["LibraryRootId", "NormalizedRelativePath", "IsDirectory"];
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "ConfirmedPreviewId",
                table: "LibraryScans",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "FailedFiles",
                table: "LibraryScans",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0);

            migrationBuilder.AddColumn<int>(
                name: "IgnoredFiles",
                table: "LibraryScans",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0);

            migrationBuilder.AddColumn<int>(
                name: "PendingFiles",
                table: "LibraryScans",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0);

            migrationBuilder.AddColumn<string>(
                name: "Phase",
                table: "LibraryScans",
                type: "TEXT",
                nullable: false,
                defaultValue: "");

            migrationBuilder.AddColumn<int>(
                name: "RecognizedFiles",
                table: "LibraryScans",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0);

            migrationBuilder.AddColumn<long>(
                name: "ImportAssignmentRevision",
                table: "LibraryRoots",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0L);

            migrationBuilder.AddColumn<bool>(
                name: "ImportPreviewRequired",
                table: "LibraryRoots",
                type: "INTEGER",
                nullable: false,
                defaultValue: false);

            migrationBuilder.CreateTable(
                name: "LibraryImportAssignments",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    LibraryRootId = table.Column<Guid>(type: "TEXT", nullable: false),
                    RelativePath = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    NormalizedRelativePath = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    IsDirectory = table.Column<bool>(type: "INTEGER", nullable: false),
                    Kind = table.Column<int>(type: "INTEGER", nullable: true),
                    ParentRelativePath = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: true),
                    SeasonNumber = table.Column<int>(type: "INTEGER", nullable: true),
                    EpisodeNumber = table.Column<int>(type: "INTEGER", nullable: true),
                    Category = table.Column<string>(type: "TEXT", maxLength: 1024, nullable: true),
                    Title = table.Column<string>(type: "TEXT", maxLength: 500, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_LibraryImportAssignments", x => x.Id);
                    table.ForeignKey(
                        name: "FK_LibraryImportAssignments_LibraryRoots_LibraryRootId",
                        column: x => x.LibraryRootId,
                        principalTable: "LibraryRoots",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "LibraryImportPreviews",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    LibraryRootId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Revision = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    BaseAssignmentRevision = table.Column<long>(type: "INTEGER", nullable: false),
                    Manifest = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    ItemsJson = table.Column<string>(type: "TEXT", nullable: false),
                    AssignmentsJson = table.Column<string>(type: "TEXT", nullable: false),
                    SummaryJson = table.Column<string>(type: "TEXT", nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    Confirmed = table.Column<bool>(type: "INTEGER", nullable: false),
                    WasInitialImport = table.Column<bool>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_LibraryImportPreviews", x => x.Id);
                    table.ForeignKey(
                        name: "FK_LibraryImportPreviews_LibraryRoots_LibraryRootId",
                        column: x => x.LibraryRootId,
                        principalTable: "LibraryRoots",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_LibraryImportAssignments_LibraryRootId_NormalizedRelativePath_IsDirectory",
                table: "LibraryImportAssignments",
                columns: AssignmentIndexColumns,
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_LibraryImportPreviews_LibraryRootId",
                table: "LibraryImportPreviews",
                column: "LibraryRootId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "LibraryImportAssignments");

            migrationBuilder.DropTable(
                name: "LibraryImportPreviews");

            migrationBuilder.DropColumn(
                name: "ConfirmedPreviewId",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "FailedFiles",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "IgnoredFiles",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "PendingFiles",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "Phase",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "RecognizedFiles",
                table: "LibraryScans");

            migrationBuilder.DropColumn(
                name: "ImportAssignmentRevision",
                table: "LibraryRoots");

            migrationBuilder.DropColumn(
                name: "ImportPreviewRequired",
                table: "LibraryRoots");
        }
    }
}
