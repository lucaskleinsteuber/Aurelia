using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    /// <summary>
    /// Smart Home and Siri are removed: their webhooks, delivery log and integration keys go. Going
    /// back recreates the empty tables.
    /// </summary>
    public partial class RemoveSmartHome : Migration
    {
        private static readonly string[] StateNextAttemptColumns = ["State", "NextAttemptAt"];
        private static readonly string[] WebhookCreatedColumns = ["WebhookId", "CreatedAt"];

        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "AutomationDeliveries");

            migrationBuilder.DropTable(
                name: "AutomationWebhooks");

            migrationBuilder.DropTable(
                name: "IntegrationTokens");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "AutomationDeliveries",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    Attempt = table.Column<int>(type: "INTEGER", nullable: false),
                    CompletedAt = table.Column<long>(type: "INTEGER", nullable: true),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    DurationMilliseconds = table.Column<int>(type: "INTEGER", nullable: true),
                    Error = table.Column<string>(type: "TEXT", maxLength: 256, nullable: true),
                    Event = table.Column<string>(type: "TEXT", maxLength: 48, nullable: false),
                    EventId = table.Column<Guid>(type: "TEXT", nullable: false),
                    NextAttemptAt = table.Column<long>(type: "INTEGER", nullable: true),
                    Payload = table.Column<string>(type: "TEXT", maxLength: 16384, nullable: true),
                    State = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    StatusCode = table.Column<int>(type: "INTEGER", nullable: true),
                    WebhookId = table.Column<Guid>(type: "TEXT", nullable: false)
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
                    ConsecutiveFailures = table.Column<int>(type: "INTEGER", nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    DeviceIds = table.Column<string>(type: "TEXT", maxLength: 2048, nullable: false),
                    Enabled = table.Column<bool>(type: "INTEGER", nullable: false),
                    Events = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                    ExcludeChildren = table.Column<bool>(type: "INTEGER", nullable: false),
                    IncludeTitles = table.Column<bool>(type: "INTEGER", nullable: false),
                    Name = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    PausedReason = table.Column<string>(type: "TEXT", maxLength: 256, nullable: true),
                    Preset = table.Column<string>(type: "TEXT", maxLength: 32, nullable: false),
                    ProfileIds = table.Column<string>(type: "TEXT", maxLength: 2048, nullable: false),
                    ProtectedSecret = table.Column<string>(type: "TEXT", maxLength: 1024, nullable: false),
                    UpdatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    Url = table.Column<string>(type: "TEXT", maxLength: 2048, nullable: false)
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
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    LastUsedAt = table.Column<long>(type: "INTEGER", nullable: true),
                    Name = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    Scopes = table.Column<string>(type: "TEXT", maxLength: 128, nullable: false),
                    TokenHash = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false)
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
    }
}
