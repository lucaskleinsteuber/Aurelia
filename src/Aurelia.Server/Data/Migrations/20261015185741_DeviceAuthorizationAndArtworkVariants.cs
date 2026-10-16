using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class DeviceAuthorizationAndArtworkVariants : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<long>(
                name: "Revision",
                table: "ArtworkAssets",
                type: "INTEGER",
                nullable: false,
                defaultValue: 1L);

            migrationBuilder.CreateTable(
                name: "DeviceAuthorizationRequests",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    DeviceName = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    CodeHash = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    SecretHash = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    State = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    ExpiresAt = table.Column<long>(type: "INTEGER", nullable: false),
                    LastPolledAt = table.Column<long>(type: "INTEGER", nullable: true),
                    AcknowledgedAt = table.Column<long>(type: "INTEGER", nullable: true),
                    DeviceSessionId = table.Column<Guid>(type: "TEXT", nullable: true),
                    ProtectedAuthentication = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_DeviceAuthorizationRequests", x => x.Id);
                    table.ForeignKey(
                        name: "FK_DeviceAuthorizationRequests_DeviceSessions_DeviceSessionId",
                        column: x => x.DeviceSessionId,
                        principalTable: "DeviceSessions",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "IX_DeviceAuthorizationRequests_CodeHash",
                table: "DeviceAuthorizationRequests",
                column: "CodeHash",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_DeviceAuthorizationRequests_DeviceSessionId",
                table: "DeviceAuthorizationRequests",
                column: "DeviceSessionId",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_DeviceAuthorizationRequests_ExpiresAt",
                table: "DeviceAuthorizationRequests",
                column: "ExpiresAt");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "DeviceAuthorizationRequests");

            migrationBuilder.DropColumn(
                name: "Revision",
                table: "ArtworkAssets");
        }
    }
}
