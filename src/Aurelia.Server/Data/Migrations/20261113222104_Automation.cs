using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class Automation : Migration
    {
        private static readonly string[] StateNextAttemptColumns = ["State", "NextAttemptAt"];
        private static readonly string[] WebhookCreatedColumns = ["WebhookId", "CreatedAt"];

        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "AutomationDeliveries",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    WebhookId = table.Column<Guid>(type: "TEXT", nullable: false),
                    EventId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Event = table.Column<string>(type: "TEXT", maxLength: 48, nullable: false),
                    State = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    Attempt = table.Column<int>(type: "INTEGER", nullable: false),
                    Payload = table.Column<string>(type: "TEXT", maxLength: 16384, nullable: true),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    NextAttemptAt = table.Column<long>(type: "INTEGER", nullable: true),
                    CompletedAt = table.Column<long>(type: "INTEGER", nullable: true),
                    StatusCode = table.Column<int>(type: "INTEGER", nullable: true),
                    DurationMilliseconds = table.Column<int>(type: "INTEGER", nullable: true),
                    Error = table.Column<string>(type: "TEXT", maxLength: 256, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AutomationDeliveries", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "AutomationWebhooks",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    Name = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    Url = table.Column<string>(type: "TEXT", maxLength: 2048, nullable: false),
                    Preset = table.Column<string>(type: "TEXT", maxLength: 32, nullable: false),
                    Events = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                    DeviceIds = table.Column<string>(type: "TEXT", maxLength: 2048, nullable: false),
                    ProfileIds = table.Column<string>(type: "TEXT", maxLength: 2048, nullable: false),
                    IncludeTitles = table.Column<bool>(type: "INTEGER", nullable: false),
                    ExcludeChildren = table.Column<bool>(type: "INTEGER", nullable: false),
                    Enabled = table.Column<bool>(type: "INTEGER", nullable: false),
                    PausedReason = table.Column<string>(type: "TEXT", maxLength: 256, nullable: true),
                    ConsecutiveFailures = table.Column<int>(type: "INTEGER", nullable: false),
                    ProtectedSecret = table.Column<string>(type: "TEXT", maxLength: 1024, nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    UpdatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AutomationWebhooks", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "IntegrationTokens",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    Name = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    TokenHash = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    Scopes = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    LastUsedAt = table.Column<long>(type: "INTEGER", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_IntegrationTokens", x => x.Id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_AutomationDeliveries_State_NextAttemptAt",
                table: "AutomationDeliveries",
                columns: StateNextAttemptColumns);

            migrationBuilder.CreateIndex(
                name: "IX_AutomationDeliveries_WebhookId_CreatedAt",
                table: "AutomationDeliveries",
                columns: WebhookCreatedColumns);

            migrationBuilder.CreateIndex(
                name: "IX_IntegrationTokens_TokenHash",
                table: "IntegrationTokens",
                column: "TokenHash",
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "AutomationDeliveries");

            migrationBuilder.DropTable(
                name: "AutomationWebhooks");

            migrationBuilder.DropTable(
                name: "IntegrationTokens");
        }
    }
}
