using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed record MediaSearchHit(Guid Id, double Rank);

public sealed class MediaSearchIndexService(AureliaDbContext database)
{
    public const string RebuildSql = """
            INSERT INTO MediaSearchIndex(MediaId, Title, OriginalTitle, Details)
            SELECT
                m.Id,
                trim(coalesce(md.ManualTitle, md.ProviderTitle, m.OverrideTitle, m.DetectedTitle)),
                trim(coalesce(md.ManualOriginalTitle, md.ProviderOriginalTitle, '')),
                trim(
                    coalesce(md.ManualGenresJson, md.ProviderGenresJson, '') || ' ' ||
                    coalesce(md.ManualStudiosJson, md.ProviderStudiosJson, '') || ' ' ||
                    coalesce((SELECT group_concat(c.Name || ' ' || coalesce(c.Character, ''), ' ')
                              FROM MediaCredits c WHERE c.MediaItemId = m.Id), '') || ' ' ||
                    coalesce((SELECT coalesce(pm.ManualTitle, pm.ProviderTitle, p.OverrideTitle, p.DetectedTitle) FROM MediaItems p LEFT JOIN MediaMetadata pm ON pm.MediaItemId=p.Id WHERE p.Id=m.ParentId), '') || ' ' ||
                    CASE WHEN m.SeasonNumber IS NULL THEN '' ELSE 'Season ' || m.SeasonNumber END || ' ' ||
                    CASE WHEN m.EpisodeNumber IS NULL THEN '' ELSE 'Episode ' || m.EpisodeNumber END
                )
            FROM MediaItems m
            LEFT JOIN MediaMetadata md ON md.MediaItemId = m.Id
            WHERE m.Kind IN ('Movie', 'Series', 'Episode');
            """;

    public async Task RebuildAsync(CancellationToken cancellationToken)
    {
        await using var transaction = await database.Database.BeginTransactionAsync(cancellationToken);
        await database.Database.ExecuteSqlRawAsync("DELETE FROM MediaSearchIndex;", cancellationToken);
        await database.Database.ExecuteSqlRawAsync(RebuildSql, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
    }

    public IQueryable<MediaSearchHit> Hits(string query)
    {
        var expression = string.Join(' ', query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(token => $"\"{token.Replace("\"", "\"\"", StringComparison.Ordinal)}\"*"));
        return database.Database.SqlQuery<MediaSearchHit>($"""
            SELECT MediaId AS Id,
                bm25(MediaSearchIndex, 0.0, 10.0, 7.0, 1.0) AS Rank
            FROM MediaSearchIndex WHERE MediaSearchIndex MATCH {expression}
            """);
    }
}
