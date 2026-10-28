using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace Aurelia.Server.Data.Migrations;

// Change only trigger work; catalog tables, data and full-text documents remain intact.
[DbContext(typeof(AureliaDbContext))]
[Migration("20261028010000_AvoidUnchangedSearchDocuments")]
public sealed class AvoidUnchangedSearchDocuments : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => Replace(migrationBuilder,
        IncrementalSearchIndex.Triggers().Single(value => value.Name == "search_MediaItems_UPDATE").Sql);
    protected override void Down(MigrationBuilder migrationBuilder) => Replace(migrationBuilder, LegacyUpdate);

    private static void Replace(MigrationBuilder migrationBuilder, string sql)
    {
        migrationBuilder.Sql("DROP TRIGGER IF EXISTS search_MediaItems_UPDATE;");
        migrationBuilder.Sql(sql);
    }

    // Frozen legacy definition: future trigger optimizations must not change rollback.
    private const string LegacyUpdate = """
        CREATE TRIGGER search_MediaItems_UPDATE AFTER UPDATE ON MediaItems BEGIN
            DELETE FROM MediaSearchIndex WHERE MediaId = NEW.Id
                OR MediaId IN (SELECT Id FROM MediaItems WHERE ParentId = NEW.Id);
            INSERT INTO MediaSearchIndex(MediaId, Title, OriginalTitle, Details)
            SELECT m.Id,
                trim(coalesce(md.ManualTitle, md.ProviderTitle, m.OverrideTitle, m.DetectedTitle)),
                trim(coalesce(md.ManualOriginalTitle, md.ProviderOriginalTitle, '')),
                trim(coalesce(md.ManualGenresJson, md.ProviderGenresJson, '') || ' ' ||
                    coalesce(md.ManualStudiosJson, md.ProviderStudiosJson, '') || ' ' ||
                    coalesce((SELECT group_concat(c.Name || ' ' || coalesce(c.Character, ''), ' ') FROM MediaCredits c WHERE c.MediaItemId = m.Id), '') || ' ' ||
                    coalesce((SELECT coalesce(pm.ManualTitle, pm.ProviderTitle, p.OverrideTitle, p.DetectedTitle) FROM MediaItems p LEFT JOIN MediaMetadata pm ON pm.MediaItemId=p.Id WHERE p.Id=m.ParentId), '') || ' ' ||
                    CASE WHEN m.SeasonNumber IS NULL THEN '' ELSE 'Season ' || m.SeasonNumber END || ' ' ||
                    CASE WHEN m.EpisodeNumber IS NULL THEN '' ELSE 'Episode ' || m.EpisodeNumber END)
            FROM MediaItems m LEFT JOIN MediaMetadata md ON md.MediaItemId = m.Id
            WHERE (m.Id = NEW.Id OR m.ParentId = NEW.Id) AND m.Kind IN ('Movie', 'Series', 'Episode');
        END;
        """;
}
