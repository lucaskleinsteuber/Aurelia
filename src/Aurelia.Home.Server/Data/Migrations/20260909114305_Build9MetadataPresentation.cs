using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable
#pragma warning disable CA1861 // Generated migration API requires constant column arrays.

namespace Aurelia.Home.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class Build9MetadataPresentation : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "MediaCollections",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    Name = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                    Provider = table.Column<string>(type: "TEXT", maxLength: 32, nullable: true),
                    ProviderCollectionId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                    SourceKey = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: true),
                    IsManual = table.Column<bool>(type: "INTEGER", nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    UpdatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MediaCollections", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "MediaMetadata",
                columns: table => new
                {
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Provider = table.Column<string>(type: "TEXT", maxLength: 32, nullable: true),
                    ProviderMediaId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                    ProviderMediaType = table.Column<string>(type: "TEXT", maxLength: 16, nullable: true),
                    MatchConfidence = table.Column<double>(type: "REAL", nullable: true),
                    ProviderTitle = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true),
                    ProviderOriginalTitle = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true),
                    ProviderOverview = table.Column<string>(type: "TEXT", maxLength: 8192, nullable: true),
                    ProviderReleaseDate = table.Column<string>(type: "TEXT", maxLength: 32, nullable: true),
                    ProviderRuntimeMinutes = table.Column<int>(type: "INTEGER", nullable: true),
                    ProviderRating = table.Column<double>(type: "REAL", nullable: true),
                    ProviderContentRating = table.Column<string>(type: "TEXT", maxLength: 32, nullable: true),
                    ProviderGenresJson = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    ProviderStudiosJson = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    ProviderCountriesJson = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: false),
                    ManualTitle = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true),
                    ManualOriginalTitle = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true),
                    ManualOverview = table.Column<string>(type: "TEXT", maxLength: 8192, nullable: true),
                    ManualReleaseDate = table.Column<string>(type: "TEXT", maxLength: 32, nullable: true),
                    ManualRuntimeMinutes = table.Column<int>(type: "INTEGER", nullable: true),
                    ManualRating = table.Column<double>(type: "REAL", nullable: true),
                    ManualContentRating = table.Column<string>(type: "TEXT", maxLength: 32, nullable: true),
                    ManualGenresJson = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: true),
                    ManualStudiosJson = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: true),
                    ManualCountriesJson = table.Column<string>(type: "TEXT", maxLength: 4096, nullable: true),
                    ReviewState = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    ProviderUpdatedAt = table.Column<long>(type: "INTEGER", nullable: true),
                    UpdatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MediaMetadata", x => x.MediaItemId);
                    table.ForeignKey(
                        name: "FK_MediaMetadata_MediaItems_MediaItemId",
                        column: x => x.MediaItemId,
                        principalTable: "MediaItems",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "MetadataJobs",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    LibraryRootId = table.Column<Guid>(type: "TEXT", nullable: true),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: true),
                    State = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    ItemsTotal = table.Column<int>(type: "INTEGER", nullable: false),
                    ItemsProcessed = table.Column<int>(type: "INTEGER", nullable: false),
                    ItemsMatched = table.Column<int>(type: "INTEGER", nullable: false),
                    ItemsNeedingReview = table.Column<int>(type: "INTEGER", nullable: false),
                    ItemsFailed = table.Column<int>(type: "INTEGER", nullable: false),
                    Error = table.Column<string>(type: "TEXT", maxLength: 1024, nullable: true),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    StartedAt = table.Column<long>(type: "INTEGER", nullable: true),
                    CompletedAt = table.Column<long>(type: "INTEGER", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MetadataJobs", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "MetadataReviews",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Reason = table.Column<string>(type: "TEXT", maxLength: 256, nullable: false),
                    CandidatesJson = table.Column<string>(type: "TEXT", maxLength: 32768, nullable: false),
                    State = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false),
                    UpdatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MetadataReviews", x => x.Id);
                    table.ForeignKey(
                        name: "FK_MetadataReviews_MediaItems_MediaItemId",
                        column: x => x.MediaItemId,
                        principalTable: "MediaItems",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "UserFavorites",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    UserId = table.Column<Guid>(type: "TEXT", nullable: false),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_UserFavorites", x => x.Id);
                    table.ForeignKey(
                        name: "FK_UserFavorites_MediaItems_MediaItemId",
                        column: x => x.MediaItemId,
                        principalTable: "MediaItems",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_UserFavorites_Users_UserId",
                        column: x => x.UserId,
                        principalTable: "Users",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "MediaCollectionMembers",
                columns: table => new
                {
                    CollectionId = table.Column<Guid>(type: "TEXT", nullable: false),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    SortOrder = table.Column<int>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MediaCollectionMembers", x => new { x.CollectionId, x.MediaItemId });
                    table.ForeignKey(
                        name: "FK_MediaCollectionMembers_MediaCollections_CollectionId",
                        column: x => x.CollectionId,
                        principalTable: "MediaCollections",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_MediaCollectionMembers_MediaItems_MediaItemId",
                        column: x => x.MediaItemId,
                        principalTable: "MediaItems",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "ArtworkAssets",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    Kind = table.Column<string>(type: "TEXT", maxLength: 16, nullable: false),
                    ProviderPath = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                    RelativeFilePath = table.Column<string>(type: "TEXT", maxLength: 512, nullable: false),
                    ContentType = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    ContentLength = table.Column<long>(type: "INTEGER", nullable: false),
                    CreatedAt = table.Column<long>(type: "INTEGER", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ArtworkAssets", x => x.Id);
                    table.ForeignKey(
                        name: "FK_ArtworkAssets_MediaMetadata_MediaItemId",
                        column: x => x.MediaItemId,
                        principalTable: "MediaMetadata",
                        principalColumn: "MediaItemId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "MediaCredits",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "TEXT", nullable: false),
                    MediaItemId = table.Column<Guid>(type: "TEXT", nullable: false),
                    ProviderPersonId = table.Column<string>(type: "TEXT", maxLength: 64, nullable: true),
                    Name = table.Column<string>(type: "TEXT", maxLength: 256, nullable: false),
                    Department = table.Column<string>(type: "TEXT", maxLength: 64, nullable: false),
                    Job = table.Column<string>(type: "TEXT", maxLength: 128, nullable: true),
                    Character = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true),
                    SortOrder = table.Column<int>(type: "INTEGER", nullable: false),
                    ProfilePath = table.Column<string>(type: "TEXT", maxLength: 512, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_MediaCredits", x => x.Id);
                    table.ForeignKey(
                        name: "FK_MediaCredits_MediaMetadata_MediaItemId",
                        column: x => x.MediaItemId,
                        principalTable: "MediaMetadata",
                        principalColumn: "MediaItemId",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_ArtworkAssets_MediaItemId_Kind_ProviderPath",
                table: "ArtworkAssets",
                columns: new[] { "MediaItemId", "Kind", "ProviderPath" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_ArtworkAssets_RelativeFilePath",
                table: "ArtworkAssets",
                column: "RelativeFilePath",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_MediaCollectionMembers_MediaItemId",
                table: "MediaCollectionMembers",
                column: "MediaItemId");

            migrationBuilder.CreateIndex(
                name: "IX_MediaCollections_Provider_ProviderCollectionId",
                table: "MediaCollections",
                columns: new[] { "Provider", "ProviderCollectionId" });

            migrationBuilder.CreateIndex(
                name: "IX_MediaCollections_SourceKey",
                table: "MediaCollections",
                column: "SourceKey");

            migrationBuilder.CreateIndex(
                name: "IX_MediaCredits_MediaItemId_SortOrder",
                table: "MediaCredits",
                columns: new[] { "MediaItemId", "SortOrder" });

            migrationBuilder.CreateIndex(
                name: "IX_MediaMetadata_Provider_ProviderMediaId",
                table: "MediaMetadata",
                columns: new[] { "Provider", "ProviderMediaId" });

            migrationBuilder.CreateIndex(
                name: "IX_MetadataJobs_State_CreatedAt",
                table: "MetadataJobs",
                columns: new[] { "State", "CreatedAt" });

            migrationBuilder.CreateIndex(
                name: "IX_MetadataReviews_MediaItemId",
                table: "MetadataReviews",
                column: "MediaItemId",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_UserFavorites_MediaItemId",
                table: "UserFavorites",
                column: "MediaItemId");

            migrationBuilder.CreateIndex(
                name: "IX_UserFavorites_UserId_MediaItemId",
                table: "UserFavorites",
                columns: new[] { "UserId", "MediaItemId" },
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "ArtworkAssets");

            migrationBuilder.DropTable(
                name: "MediaCollectionMembers");

            migrationBuilder.DropTable(
                name: "MediaCredits");

            migrationBuilder.DropTable(
                name: "MetadataJobs");

            migrationBuilder.DropTable(
                name: "MetadataReviews");

            migrationBuilder.DropTable(
                name: "UserFavorites");

            migrationBuilder.DropTable(
                name: "MediaCollections");

            migrationBuilder.DropTable(
                name: "MediaMetadata");
        }
    }
}
#pragma warning restore CA1861
