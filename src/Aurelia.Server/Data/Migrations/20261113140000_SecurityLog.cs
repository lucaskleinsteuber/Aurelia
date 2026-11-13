using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class SecurityLog : Migration
    {
        private static readonly string[] OutcomeAtColumns = ["Outcome", "At"];

        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<long>(
                name: "AcknowledgedAt",
                table: "DeviceSessions",
                type: "INTEGER",
                nullable: true);

            // Devices signed in before this version count as known; only later ones are "new".
            migrationBuilder.Sql("UPDATE \"DeviceSessions\" SET \"AcknowledgedAt\" = CAST(strftime('%s','now') AS INTEGER) * 1000;");

            migrationBuilder.AddColumn<string>(
                name: "ClientVersion",
                table: "DeviceSessions",
                type: "TEXT",
                maxLength: 32,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "FirstIpAddress",
                table: "DeviceSessions",
                type: "TEXT",
                maxLength: 64,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "InstallationId",
                table: "DeviceSessions",
                type: "TEXT",
                maxLength: 64,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "LastIpAddress",
                table: "DeviceSessions",
                type: "TEXT",
                maxLength: 64,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "Platform",
                table: "DeviceSessions",
                type: "TEXT",
                maxLength: 64,
                nullable: true);

            migrationBuilder.CreateTable(
                name: "BlockedDevices",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    InstallationId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    DeviceName = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    Platform = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                    IpAddress = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                    BlockedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    BlockedByUserId = table.Column<Guid>(type: "TEXT", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_BlockedDevices", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "ManagementPasskeys",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    DeviceSessionId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Name = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    PublicKey = table.Column<byte[]>(type: "BLOB", maxLength: 65, nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    LastUsedAt = table.Column<long>(type: "INTEGER", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ManagementPasskeys", x => x.Id);
                    table.ForeignKey(
                        name: "FK_ManagementPasskeys_DeviceSessions_DeviceSessionId",
                        column: x => x.DeviceSessionId,
                        principalTable: "DeviceSessions",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_ManagementPasskeys_Users_UserId",
                        column: x => x.UserId,
                        principalTable: "Users",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "SecurityEvents",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    At = table.Column<long>(type: "INTEGER", nullable: false),
                    Kind = table.Column<string>(type: "TEXT", maxLength: 48, nullable: false),
                    Outcome = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: true),
                    UserName = table.Column<string>(type: "TEXT", maxLength: 128, nullable: true),
                    DeviceSessionId = table.Column<Guid>(type: "TEXT", nullable: true),
                    DeviceName = table.Column<string>(type: "TEXT", maxLength: 128, nullable: true),
                    Platform = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                    IpAddress = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                    Detail = table.Column<string>(type: "TEXT", maxLength: 256, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SecurityEvents", x => x.Id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_DeviceSessions_InstallationId",
                table: "DeviceSessions",
                column: "InstallationId");

            migrationBuilder.CreateIndex(
                name: "IX_BlockedDevices_InstallationId",
                table: "BlockedDevices",
                column: "InstallationId",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_ManagementPasskeys_DeviceSessionId",
                table: "ManagementPasskeys",
                column: "DeviceSessionId");

            migrationBuilder.CreateIndex(
                name: "IX_ManagementPasskeys_UserId",
                table: "ManagementPasskeys",
                column: "UserId");

            migrationBuilder.CreateIndex(
                name: "IX_SecurityEvents_At",
                table: "SecurityEvents",
                column: "At");

            migrationBuilder.CreateIndex(
                name: "IX_SecurityEvents_Outcome_At",
                table: "SecurityEvents",
                columns: OutcomeAtColumns);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(name: "BlockedDevices");
            migrationBuilder.DropTable(name: "ManagementPasskeys");
            migrationBuilder.DropTable(name: "SecurityEvents");
            migrationBuilder.DropIndex(name: "IX_DeviceSessions_InstallationId", table: "DeviceSessions");
            // SQLite 3.35 drops a column in place; the earlier migrations carry no model to rebuild from.
            foreach (var column in new[] { "AcknowledgedAt", "ClientVersion", "FirstIpAddress", "InstallationId", "LastIpAddress", "Platform" })
                migrationBuilder.Sql($"ALTER TABLE \"DeviceSessions\" DROP COLUMN \"{column}\";");
        }
    }
}
