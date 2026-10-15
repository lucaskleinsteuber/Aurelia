using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Aurelia.Server.Services;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class DurableMetadataWorklists : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<int>(
                name: "ItemsSkipped",
                table: "MetadataJobs",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0);

            migrationBuilder.AddColumn<long>(
                name: "NextAttemptAt",
                table: "MetadataJobs",
                type: "INTEGER",
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "RequestedByUserId",
                table: "MetadataJobs",
                type: "TEXT",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "WaitReason",
                table: "MetadataJobs",
                type: "TEXT",
                maxLength: 32,
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "WorklistInitialized",
                table: "MetadataJobs",
                type: "INTEGER",
                nullable: false,
                defaultValue: false);

            migrationBuilder.CreateTable(
                name: "MetadataJobItems",
                columns: table => new
                {
                    JobId = table.Column<Guid>(type: "TEXT", nullable: false),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Ordinal = table.Column<int>(type: "INTEGER", nullable: false),
                    State = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    Attempt = table.Column<int>(type: "INTEGER", nullable: false),
                    CompletedAt = table.Column<long>(type: "INTEGER", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MetadataJobItems", x => new { x.JobId, x.MediaItemId });
                    table.ForeignKey(
                        name: "FK_MetadataJobItems_MetadataJobs_JobId",
                        column: x => x.JobId,
                        principalTable: "MetadataJobs",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "MetadataProviderCooldowns",
                columns: table => new
                {
                    Provider = table.Column<string>(type: "TEXT", maxLength: 32, nullable: false),
                    NotBefore = table.Column<long>(type: "INTEGER", nullable: true),
                    WaitReason = table.Column<string>(type: "TEXT", maxLength: 32, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MetadataProviderCooldowns", x => x.Provider);
                });

            migrationBuilder.CreateIndex(
                name: "IX_MetadataJobs_State_NextAttemptAt_CreatedAt",
                table: "MetadataJobs",
                columns: ["State", "NextAttemptAt", "CreatedAt"]);

            migrationBuilder.CreateIndex(
                name: "IX_MetadataJobItems_JobId_State_Ordinal",
                table: "MetadataJobItems",
                columns: ["JobId", "State", "Ordinal"]);

            // The measured card/series queries otherwise scan the Kind index and
            // sort every regular episode before their window/aggregate operations.
            migrationBuilder.CreateIndex(
                name: "IX_MediaItems_Kind_ParentId_SeasonNumber_EpisodeNumber_DetectedTitle_Id",
                table: "MediaItems",
                columns: ["Kind", "ParentId", "SeasonNumber", "EpisodeNumber", "DetectedTitle", "Id"]);

            // Legacy counters cannot identify which titles already completed. Preserve
            // them as history and require Retry to create an authorized worklist.
            migrationBuilder.Sql("""
                UPDATE MetadataJobs SET State='Interrupted',
                    Error='This metadata job was interrupted by an update. Retry to create a resumable worklist.',
                    CompletedAt=CAST(strftime('%s','now') AS INTEGER)*1000,
                    LeaseExpiresAt=NULL,HeartbeatAt=NULL
                WHERE State IN ('Queued','Running') AND WorklistInitialized=0;
                """);
            foreach (var trigger in IncrementalSearchIndex.Triggers())
            {
                migrationBuilder.Sql("DROP TRIGGER IF EXISTS " + trigger.Name + ";");
                migrationBuilder.Sql(trigger.Sql);
            }
            migrationBuilder.Sql("DELETE FROM MediaSearchIndex;");
            migrationBuilder.Sql(MediaSearchIndexService.RebuildSql);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_MediaItems_Kind_ParentId_SeasonNumber_EpisodeNumber_DetectedTitle_Id",
                table: "MediaItems");
            migrationBuilder.DropTable(
                name: "MetadataJobItems");

            migrationBuilder.DropTable(
                name: "MetadataProviderCooldowns");

            migrationBuilder.DropIndex(
                name: "IX_MetadataJobs_State_NextAttemptAt_CreatedAt",
                table: "MetadataJobs");

            migrationBuilder.DropColumn(
                name: "ItemsSkipped",
                table: "MetadataJobs");

            migrationBuilder.DropColumn(
                name: "NextAttemptAt",
                table: "MetadataJobs");

            migrationBuilder.DropColumn(
                name: "RequestedByUserId",
                table: "MetadataJobs");

            migrationBuilder.DropColumn(
                name: "WaitReason",
                table: "MetadataJobs");

            migrationBuilder.DropColumn(
                name: "WorklistInitialized",
                table: "MetadataJobs");
        }
    }
}
