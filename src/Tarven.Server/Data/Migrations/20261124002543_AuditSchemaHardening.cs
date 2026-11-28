using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Tarven.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class AuditSchemaHardening : Migration
    {
        private static readonly string[] SceneNoteKeyColumns = ["UserId", "Id"];
        private static readonly string[] LibraryMutationStateCreatedColumns = ["State", "CreatedAt"];

        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropPrimaryKey(
                name: "PK_SceneNotes",
                table: "SceneNotes");

            migrationBuilder.AlterColumn<long>(
                name: "UpdatedAt",
                table: "ProfilePhotos",
                type: "INTEGER",
                nullable: false,
                oldClrType: typeof(DateTimeOffset),
                oldType: "TEXT");

            migrationBuilder.Sql(
                """
                UPDATE "ProfilePhotos"
                SET "UpdatedAt" = CASE
                    WHEN typeof("UpdatedAt") = 'integer' THEN "UpdatedAt"
                    ELSE COALESCE(CAST(ROUND(unixepoch("UpdatedAt", 'subsec') * 1000) AS INTEGER), 0)
                END
                WHERE typeof("UpdatedAt") <> 'integer';
                """);

            migrationBuilder.AddColumn<long>(
                name: "CreatedAt",
                table: "LibraryStateMutations",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0L);

            migrationBuilder.Sql(
                """
                UPDATE "LibraryStateMutations"
                SET "CreatedAt" = CAST(strftime('%s', 'now') AS INTEGER) * 1000
                WHERE "CreatedAt" = 0;
                """);

            migrationBuilder.AddColumn<long>(
                name: "CreatedAt",
                table: "LibraryMutations",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0L);

            migrationBuilder.Sql(
                """
                UPDATE "LibraryMutations"
                SET "CreatedAt" = CAST(strftime('%s', 'now') AS INTEGER) * 1000
                WHERE "CreatedAt" = 0;
                """);

            migrationBuilder.AddPrimaryKey(
                name: "PK_SceneNotes",
                table: "SceneNotes",
                columns: SceneNoteKeyColumns);

            migrationBuilder.CreateIndex(
                name: "IX_WatchEvents_Timestamp",
                table: "WatchEvents",
                column: "Timestamp");

            migrationBuilder.CreateIndex(
                name: "IX_LibraryStateMutations_CreatedAt",
                table: "LibraryStateMutations",
                column: "CreatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_LibraryMutations_State_CreatedAt",
                table: "LibraryMutations",
                columns: LibraryMutationStateCreatedColumns);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_WatchEvents_Timestamp",
                table: "WatchEvents");

            migrationBuilder.DropPrimaryKey(
                name: "PK_SceneNotes",
                table: "SceneNotes");

            migrationBuilder.DropIndex(
                name: "IX_LibraryStateMutations_CreatedAt",
                table: "LibraryStateMutations");

            migrationBuilder.DropIndex(
                name: "IX_LibraryMutations_State_CreatedAt",
                table: "LibraryMutations");

            migrationBuilder.DropColumn(
                name: "CreatedAt",
                table: "LibraryStateMutations");

            migrationBuilder.DropColumn(
                name: "CreatedAt",
                table: "LibraryMutations");

            migrationBuilder.AlterColumn<DateTimeOffset>(
                name: "UpdatedAt",
                table: "ProfilePhotos",
                type: "TEXT",
                nullable: false,
                oldClrType: typeof(long),
                oldType: "INTEGER");

            migrationBuilder.Sql(
                """
                UPDATE "ProfilePhotos"
                SET "UpdatedAt" = strftime('%Y-%m-%d %H:%M:%f+00:00', CAST("UpdatedAt" AS REAL) / 1000.0, 'unixepoch')
                WHERE "UpdatedAt" GLOB '[0-9]*' OR "UpdatedAt" GLOB '-[0-9]*';
                """);

            migrationBuilder.AddPrimaryKey(
                name: "PK_SceneNotes",
                table: "SceneNotes",
                column: "Id");
        }
    }
}
