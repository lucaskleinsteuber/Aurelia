#pragma warning disable CA1861

using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class Build8AutomaticMediaDiscovery : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "LibraryDiscoveries",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    LibraryRootId = table.Column<Guid>(type: "TEXT", nullable: false),
                    RelativePath = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    NormalizedRelativePath = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    DetectedTitle = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                    SuggestedKind = table.Column<string>(type: "TEXT", maxLength: 16, nullable: true),
                    Reason = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    Decision = table.Column<string>(type: "TEXT", maxLength: 16, nullable: true),
                    LastSeenScanId = table.Column<Guid>(type: "TEXT", nullable: true),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    UpdatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_LibraryDiscoveries", x => x.Id);
                    table.ForeignKey(
                        name: "FK_LibraryDiscoveries_LibraryRoots_LibraryRootId",
                        column: x => x.LibraryRootId,
                        principalTable: "LibraryRoots",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_LibraryDiscoveries_LibraryRootId_NormalizedRelativePath",
                table: "LibraryDiscoveries",
                columns: new[] { "LibraryRootId", "NormalizedRelativePath" },
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "LibraryDiscoveries");
        }
    }
}
