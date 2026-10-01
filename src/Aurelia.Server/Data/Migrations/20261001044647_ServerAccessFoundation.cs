using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class ServerAccessFoundation : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "IsEnabled",
                table: "Users",
                type: "INTEGER",
                nullable: false,
                defaultValue: true);

            migrationBuilder.CreateTable(
                name: "UserLibraryGrants",
                columns: table => new
                {
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    LibraryRootId = table.Column<Guid>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_UserLibraryGrants", x => new { x.UserId, x.LibraryRootId });
                    table.ForeignKey(
                        name: "FK_UserLibraryGrants_LibraryRoots_LibraryRootId",
                        column: x => x.LibraryRootId,
                        principalTable: "LibraryRoots",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_UserLibraryGrants_Users_UserId",
                        column: x => x.UserId,
                        principalTable: "Users",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_UserLibraryGrants_LibraryRootId",
                table: "UserLibraryGrants",
                column: "LibraryRootId");

            // Preserve access for accounts and libraries that existed before ACLs.
            // This runs once; new accounts and later libraries receive no implicit grants.
            migrationBuilder.Sql("""
                INSERT INTO UserLibraryGrants(UserId, LibraryRootId)
                SELECT u.Id, l.Id FROM Users u CROSS JOIN LibraryRoots l;
                """);
            foreach (var trigger in Services.IncrementalSearchIndex.Triggers()) migrationBuilder.Sql(trigger.Sql);
            // One migration-time rebuild covers pre-existing data; subsequent writes are incremental.
            migrationBuilder.Sql("""
                DELETE FROM MediaSearchIndex;
                INSERT INTO MediaSearchIndex(MediaId, Title, OriginalTitle, Details)
                SELECT lower(replace(m.Id, '-', '')), coalesce(md.ManualTitle, md.ProviderTitle, m.OverrideTitle, m.DetectedTitle),
                    coalesce(md.ManualOriginalTitle, md.ProviderOriginalTitle, ''),
                    coalesce(md.ManualGenresJson, md.ProviderGenresJson, '') || ' ' || coalesce(md.ManualStudiosJson, md.ProviderStudiosJson, '') || ' ' ||
                    coalesce((SELECT group_concat(c.Name || ' ' || coalesce(c.Character, ''), ' ') FROM MediaCredits c WHERE c.MediaItemId = m.Id), '')
                FROM MediaItems m LEFT JOIN MediaMetadata md ON md.MediaItemId = m.Id WHERE m.Kind IN ('Movie', 'Series', 'Episode');
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            foreach (var trigger in Services.IncrementalSearchIndex.Triggers()) migrationBuilder.Sql($"DROP TRIGGER IF EXISTS {trigger.Name};");
            migrationBuilder.DropTable(
                name: "UserLibraryGrants");

            migrationBuilder.DropColumn(
                name: "IsEnabled",
                table: "Users");
        }
    }
}
