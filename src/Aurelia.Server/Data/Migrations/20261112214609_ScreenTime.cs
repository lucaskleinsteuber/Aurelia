using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class ScreenTime : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<long>(
                name: "ScreenTimeExtraEndsAt",
                table: "PlaybackTickets",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "ScreenTimeDays",
                columns: table => new
                {
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Day = table.Column<DateOnly>(type: "TEXT", nullable: false),
                    WatchedSeconds = table.Column<int>(type: "INTEGER", nullable: false),
                    ExtraMinutes = table.Column<int>(type: "INTEGER", nullable: false),
                    BedtimeLifted = table.Column<bool>(type: "INTEGER", nullable: false),
                    OneMoreTitleGranted = table.Column<bool>(type: "INTEGER", nullable: false),
                    OneMoreTitleUsed = table.Column<bool>(type: "INTEGER", nullable: false),
                    LimitReachedAt = table.Column<long>(type: "INTEGER", nullable: true),
                    LastMediaId = table.Column<Guid>(type: "TEXT", nullable: true),
                    LastPositionMilliseconds = table.Column<long>(type: "INTEGER", nullable: false),
                    LastReportAt = table.Column<long>(type: "INTEGER", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ScreenTimeDays", x => new { x.UserId, x.Day });
                    table.ForeignKey(
                        name: "FK_ScreenTimeDays_Users_UserId",
                        column: x => x.UserId,
                        principalTable: "Users",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "ScreenTimeRules",
                columns: table => new
                {
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Enabled = table.Column<bool>(type: "INTEGER", nullable: false),
                    LockScope = table.Column<string>(type: "TEXT", maxLength: 32, nullable: false),
                    Ending = table.Column<string>(type: "TEXT", maxLength: 32, nullable: false),
                    MaxOvertimeMinutes = table.Column<int>(type: "INTEGER", nullable: false),
                    SchoolBedtime = table.Column<string>(type: "TEXT", maxLength: 5, nullable: true),
                    SchoolWakeTime = table.Column<string>(type: "TEXT", maxLength: 5, nullable: false),
                    SchoolLimitMinutes = table.Column<int>(type: "INTEGER", nullable: true),
                    WeekendBedtime = table.Column<string>(type: "TEXT", maxLength: 5, nullable: true),
                    WeekendWakeTime = table.Column<string>(type: "TEXT", maxLength: 5, nullable: false),
                    WeekendLimitMinutes = table.Column<int>(type: "INTEGER", nullable: true),
                    Revision = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ScreenTimeRules", x => x.UserId);
                    table.ForeignKey(
                        name: "FK_ScreenTimeRules_Users_UserId",
                        column: x => x.UserId,
                        principalTable: "Users",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "ScreenTimeDays");

            migrationBuilder.DropTable(
                name: "ScreenTimeRules");

            migrationBuilder.DropColumn(
                name: "ScreenTimeExtraEndsAt",
                table: "PlaybackTickets");
        }
    }
}
