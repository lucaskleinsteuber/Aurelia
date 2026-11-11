using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class MediaSegmentTimes : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "MediaSegments",
                columns: table => new
                {
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    IntroStartMilliseconds = table.Column<long>(type: "INTEGER", nullable: true),
                    IntroEndMilliseconds = table.Column<long>(type: "INTEGER", nullable: true),
                    IntroSource = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    IntroConfidence = table.Column<double>(type: "REAL", nullable: false),
                    CreditsStartMilliseconds = table.Column<long>(type: "INTEGER", nullable: true),
                    CreditsSource = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    CreditsConfidence = table.Column<double>(type: "REAL", nullable: false),
                    AnalysisVersion = table.Column<int>(type: "INTEGER", nullable: false),
                    AnalyzedFileSize = table.Column<long>(type: "INTEGER", nullable: true),
                    AnalyzedFileModifiedAt = table.Column<long>(type: "INTEGER", nullable: true),
                    UpdatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MediaSegments", x => x.MediaItemId);
                    table.ForeignKey(
                        name: "FK_MediaSegments_MediaItems_MediaItemId",
                        column: x => x.MediaItemId,
                        principalTable: "MediaItems",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "MediaSegments");
        }
    }
}
