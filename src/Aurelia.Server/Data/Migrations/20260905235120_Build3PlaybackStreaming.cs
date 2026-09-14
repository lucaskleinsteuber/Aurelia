using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class Build3PlaybackStreaming : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "PlaybackTickets",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    DeviceSessionId = table.Column<Guid>(type: "TEXT", nullable: false),
                    TokenHash = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    ExpiresAt = table.Column<long>(type: "INTEGER", nullable: false),
                    RevokedAt = table.Column<long>(type: "INTEGER", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PlaybackTickets", x => x.Id);
                    table.ForeignKey(
                        name: "FK_PlaybackTickets_DeviceSessions_DeviceSessionId",
                        column: x => x.DeviceSessionId,
                        principalTable: "DeviceSessions",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_PlaybackTickets_MediaItems_MediaItemId",
                        column: x => x.MediaItemId,
                        principalTable: "MediaItems",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_PlaybackTickets_Users_UserId",
                        column: x => x.UserId,
                        principalTable: "Users",
                        principalColumn: "Id");
                });

            migrationBuilder.CreateIndex(
                name: "IX_PlaybackTickets_DeviceSessionId_ExpiresAt",
                table: "PlaybackTickets",
                columns: ["DeviceSessionId", "ExpiresAt"]);

            migrationBuilder.CreateIndex(
                name: "IX_PlaybackTickets_MediaItemId",
                table: "PlaybackTickets",
                column: "MediaItemId");

            migrationBuilder.CreateIndex(
                name: "IX_PlaybackTickets_TokenHash",
                table: "PlaybackTickets",
                column: "TokenHash",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_PlaybackTickets_UserId_ExpiresAt",
                table: "PlaybackTickets",
                columns: ["UserId", "ExpiresAt"]);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "PlaybackTickets");
        }
    }
}
