using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Tarven.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class People : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "PersonProfiles",
                columns: table => new
                {
                    Provider = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    ProviderPersonId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    Language = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    Name = table.Column<string>(type: "TEXT", maxLength: 256, nullable: false),
                    Biography = table.Column<string>(type: "TEXT", maxLength: 8192, nullable: true),
                    Birthday = table.Column<string>(type: "TEXT", maxLength: 10, nullable: true),
                    Deathday = table.Column<string>(type: "TEXT", maxLength: 10, nullable: true),
                    PlaceOfBirth = table.Column<string>(type: "TEXT", maxLength: 256, nullable: true),
                    KnownForDepartment = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                    ProfilePath = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true),
                    CreditsJson = table.Column<string>(type: "TEXT", nullable: false),
                    FetchedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PersonProfiles", x => new { x.Provider, x.ProviderPersonId });
                });

            migrationBuilder.CreateIndex(
                name: "IX_MediaCredits_ProviderPersonId",
                table: "MediaCredits",
                column: "ProviderPersonId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "PersonProfiles");

            migrationBuilder.DropIndex(
                name: "IX_MediaCredits_ProviderPersonId",
                table: "MediaCredits");
        }
    }
}
