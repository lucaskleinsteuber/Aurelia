using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable
#pragma warning disable CA1861 // EF Core migration code intentionally uses generated column arrays.

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class Build18TrailerImportReview : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "LibraryImportReviews",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    LibraryRootId = table.Column<Guid>(type: "TEXT", nullable: false),
                    RelativePath = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    NormalizedRelativePath = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    DetectedTitle = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                    Reason = table.Column<string>(type: "TEXT", maxLength: 256, nullable: false),
                    State = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    AssignedMovieId = table.Column<Guid>(type: "TEXT", nullable: true),
                    LastSeenScanId = table.Column<Guid>(type: "TEXT", nullable: true),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    UpdatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_LibraryImportReviews", x => x.Id);
                    table.ForeignKey(
                        name: "FK_LibraryImportReviews_LibraryRoots_LibraryRootId",
                        column: x => x.LibraryRootId,
                        principalTable: "LibraryRoots",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_LibraryImportReviews_MediaItems_AssignedMovieId",
                        column: x => x.AssignedMovieId,
                        principalTable: "MediaItems",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "IX_LibraryImportReviews_AssignedMovieId",
                table: "LibraryImportReviews",
                column: "AssignedMovieId");

            migrationBuilder.CreateIndex(
                name: "IX_LibraryImportReviews_LibraryRootId_NormalizedRelativePath",
                table: "LibraryImportReviews",
                columns: new[] { "LibraryRootId", "NormalizedRelativePath" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_LibraryImportReviews_LibraryRootId_State_DetectedTitle",
                table: "LibraryImportReviews",
                columns: new[] { "LibraryRootId", "State", "DetectedTitle" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "LibraryImportReviews");
        }
    }
}
