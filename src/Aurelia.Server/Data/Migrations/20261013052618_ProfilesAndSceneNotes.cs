using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class ProfilesAndSceneNotes : Migration
    {
        private static readonly string[] NoteIndexColumns = ["UserId", "MediaItemId", "StartMilliseconds"];
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "AccessMode",
                table: "Users",
                type: "TEXT",
                maxLength: 32,
                nullable: false,
                defaultValue: "LegacyLibraries");

            migrationBuilder.AddColumn<long>(
                name: "AccessRevision",
                table: "Users",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0L);

            migrationBuilder.AddColumn<string>(
                name: "PinHash",
                table: "Users",
                type: "TEXT",
                maxLength: 512,
                nullable: true);

            migrationBuilder.AddColumn<Guid>(
                name: "ProfileSessionId",
                table: "PlaybackTickets",
                type: "TEXT",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "AdministrationCredentials",
                columns: table => new
                {
                    Id = table.Column<int>(type: "INTEGER", nullable: false)
                        .Annotation("Sqlite:Autoincrement", true),
                    PasswordHash = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AdministrationCredentials", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "SceneNotes",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    StartMilliseconds = table.Column<long>(type: "INTEGER", nullable: false),
                    EndMilliseconds = table.Column<long>(type: "INTEGER", nullable: true),
                    Text = table.Column<string>(type: "TEXT", maxLength: 2000, nullable: false),
                    Revision = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SceneNotes", x => x.Id);
                    table.ForeignKey(
                        name: "FK_SceneNotes_MediaItems_MediaItemId",
                        column: x => x.MediaItemId,
                        principalTable: "MediaItems",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_SceneNotes_Users_UserId",
                        column: x => x.UserId,
                        principalTable: "Users",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "UserTitleGrants",
                columns: table => new
                {
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_UserTitleGrants", x => new { x.UserId, x.MediaItemId });
                    table.ForeignKey(
                        name: "FK_UserTitleGrants_MediaItems_MediaItemId",
                        column: x => x.MediaItemId,
                        principalTable: "MediaItems",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_UserTitleGrants_Users_UserId",
                        column: x => x.UserId,
                        principalTable: "Users",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_SceneNotes_MediaItemId",
                table: "SceneNotes",
                column: "MediaItemId");

            migrationBuilder.CreateIndex(
                name: "IX_SceneNotes_UserId_MediaItemId_StartMilliseconds",
                table: "SceneNotes",
                columns: NoteIndexColumns);

            migrationBuilder.CreateIndex(
                name: "IX_UserTitleGrants_MediaItemId",
                table: "UserTitleGrants",
                column: "MediaItemId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "AdministrationCredentials");

            migrationBuilder.DropTable(
                name: "SceneNotes");

            migrationBuilder.DropTable(
                name: "UserTitleGrants");

            // The preceding hand-authored migration has no full EF target model.
            // These unindexed, non-FK columns can be removed natively by the pinned SQLite.
            migrationBuilder.Sql("ALTER TABLE Users DROP COLUMN AccessMode;");
            migrationBuilder.Sql("ALTER TABLE Users DROP COLUMN AccessRevision;");
            migrationBuilder.Sql("ALTER TABLE Users DROP COLUMN PinHash;");
            migrationBuilder.Sql("ALTER TABLE PlaybackTickets DROP COLUMN ProfileSessionId;");
        }
    }
}
