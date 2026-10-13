using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Aurelia.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class OptionalProfilePins : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "PinProtectionEnabled",
                table: "Users",
                type: "INTEGER",
                nullable: false,
                // Preserve every existing protected or still-pending profile.
                // A missing PIN hash must never silently make it unprotected.
                defaultValue: true);

            migrationBuilder.AddColumn<long>(
                name: "ProfileRevision",
                table: "Users",
                type: "INTEGER",
                nullable: false,
                defaultValue: 0L);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "PinProtectionEnabled",
                table: "Users");

            migrationBuilder.DropColumn(
                name: "ProfileRevision",
                table: "Users");
        }
    }
}
