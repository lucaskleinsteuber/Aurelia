using System;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations;

[DbContext(typeof(AureliaDbContext))]
[Migration("20261113120000_FamilyWishes")]
public sealed class FamilyWishes : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.CreateTable(
            name: "Wishes",
            columns: table => new
            {
                Id = table.Column<Guid>(type: "TEXT", nullable: false),
                UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                Kind = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                Provider = table.Column<string>(type: "TEXT", maxLength: 32, nullable: true),
                ProviderMediaId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                Title = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                Year = table.Column<int>(type: "INTEGER", nullable: true),
                Overview = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: true),
                PosterPath = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true),
                AgeRating = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                Note = table.Column<string>(type: "TEXT", maxLength: 1000, nullable: true),
                State = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                ResolvedByUserId = table.Column<Guid>(type: "TEXT", nullable: true),
                ResolutionNote = table.Column<string>(type: "TEXT", maxLength: 1000, nullable: true),
                FulfilledMediaItemId = table.Column<Guid>(type: "TEXT", nullable: true),
                CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                ResolvedAt = table.Column<long>(type: "INTEGER", nullable: true),
                SeenByWisherAt = table.Column<long>(type: "INTEGER", nullable: true),
            },
            constraints: table =>
            {
                table.PrimaryKey("PK_Wishes", x => x.Id);
                table.ForeignKey(
                    name: "FK_Wishes_Users_UserId",
                    column: x => x.UserId,
                    principalTable: "Users",
                    principalColumn: "Id",
                    onDelete: ReferentialAction.Cascade);
                table.ForeignKey(
                    name: "FK_Wishes_Users_ResolvedByUserId",
                    column: x => x.ResolvedByUserId,
                    principalTable: "Users",
                    principalColumn: "Id",
                    onDelete: ReferentialAction.SetNull);
                table.ForeignKey(
                    name: "FK_Wishes_MediaItems_FulfilledMediaItemId",
                    column: x => x.FulfilledMediaItemId,
                    principalTable: "MediaItems",
                    principalColumn: "Id",
                    onDelete: ReferentialAction.SetNull);
            });

        migrationBuilder.CreateTable(
            name: "WishSupports",
            columns: table => new
            {
                WishId = table.Column<Guid>(type: "TEXT", nullable: false),
                UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
            },
            constraints: table =>
            {
                table.PrimaryKey("PK_WishSupports", x => new { x.WishId, x.UserId });
                table.ForeignKey(
                    name: "FK_WishSupports_Wishes_WishId",
                    column: x => x.WishId,
                    principalTable: "Wishes",
                    principalColumn: "Id",
                    onDelete: ReferentialAction.Cascade);
                table.ForeignKey(
                    name: "FK_WishSupports_Users_UserId",
                    column: x => x.UserId,
                    principalTable: "Users",
                    principalColumn: "Id",
                    onDelete: ReferentialAction.Cascade);
            });

        migrationBuilder.CreateIndex(
            name: "IX_Wishes_FulfilledMediaItemId",
            table: "Wishes",
            column: "FulfilledMediaItemId");

        migrationBuilder.CreateIndex(
            name: "IX_Wishes_Provider_ProviderMediaId_Kind",
            table: "Wishes",
            columns: ["Provider", "ProviderMediaId", "Kind"],
            unique: true,
            filter: "\"State\" = 'Open' AND \"Provider\" IS NOT NULL AND \"ProviderMediaId\" IS NOT NULL");

        migrationBuilder.CreateIndex(
            name: "IX_Wishes_ResolvedByUserId",
            table: "Wishes",
            column: "ResolvedByUserId");

        migrationBuilder.CreateIndex(
            name: "IX_Wishes_State_CreatedAt",
            table: "Wishes",
            columns: ["State", "CreatedAt"]);

        migrationBuilder.CreateIndex(
            name: "IX_Wishes_UserId_State_SeenByWisherAt",
            table: "Wishes",
            columns: ["UserId", "State", "SeenByWisherAt"]);

        migrationBuilder.CreateIndex(
            name: "IX_WishSupports_UserId",
            table: "WishSupports",
            column: "UserId");
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropTable(name: "WishSupports");
        migrationBuilder.DropTable(name: "Wishes");
    }
}
