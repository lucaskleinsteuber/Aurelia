using System.Data;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class MediaSearchIndexService(AureliaDbContext database)
{
    public async Task RebuildAsync(CancellationToken cancellationToken)
    {
        await using var transaction = await database.Database.BeginTransactionAsync(cancellationToken);
        await database.Database.ExecuteSqlRawAsync("DELETE FROM MediaSearchIndex;", cancellationToken);
        await database.Database.ExecuteSqlRawAsync("""
            INSERT INTO MediaSearchIndex(MediaId, Title, OriginalTitle, Details)
            SELECT
                lower(replace(m.Id, '-', '')),
                trim(coalesce(md.ManualTitle, md.ProviderTitle, m.OverrideTitle, m.DetectedTitle)),
                trim(coalesce(md.ManualOriginalTitle, md.ProviderOriginalTitle, '')),
                trim(
                    coalesce(md.ManualGenresJson, md.ProviderGenresJson, '') || ' ' ||
                    coalesce(md.ManualStudiosJson, md.ProviderStudiosJson, '') || ' ' ||
                    coalesce((SELECT group_concat(c.Name || ' ' || coalesce(c.Character, ''), ' ')
                              FROM MediaCredits c WHERE c.MediaItemId = m.Id), '') || ' ' ||
                    coalesce((SELECT p.DetectedTitle FROM MediaItems p WHERE p.Id = m.ParentId), '') || ' ' ||
                    CASE WHEN m.SeasonNumber IS NULL THEN '' ELSE 'Season ' || m.SeasonNumber END || ' ' ||
                    CASE WHEN m.EpisodeNumber IS NULL THEN '' ELSE 'Episode ' || m.EpisodeNumber END
                )
            FROM MediaItems m
            LEFT JOIN MediaMetadata md ON md.MediaItemId = m.Id
            WHERE m.Kind IN ('Movie', 'Series', 'Episode');
            """, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
    }

    public async Task<(IReadOnlyList<Guid> Ids, int Total)> SearchAsync(
        string query,
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        var expression = string.Join(' ', query.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(token => $"\"{token.Replace("\"", "\"\"", StringComparison.Ordinal)}\"*"));
        var connection = database.Database.GetDbConnection();
        if (connection.State != ConnectionState.Open)
            await connection.OpenAsync(cancellationToken);

        await using var count = connection.CreateCommand();
        const string visibility = """
            AND ($unrestricted = 1 OR EXISTS (
                SELECT 1 FROM MediaItems m JOIN UserLibraryGrants g ON g.LibraryRootId = m.LibraryRootId
                WHERE lower(replace(m.Id, '-', '')) = MediaSearchIndex.MediaId AND g.UserId = $user))
            """;
        count.CommandText = "SELECT count(*) FROM MediaSearchIndex WHERE MediaSearchIndex MATCH $query " + visibility;
        AddAccessParameters(count);
        var countParameter = count.CreateParameter();
        countParameter.ParameterName = "$query";
        countParameter.Value = expression;
        count.Parameters.Add(countParameter);
        var total = Convert.ToInt32(await count.ExecuteScalarAsync(cancellationToken), System.Globalization.CultureInfo.InvariantCulture);

        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT MediaId FROM MediaSearchIndex
            WHERE MediaSearchIndex MATCH $query
            """ + " " + visibility + " " + """
            ORDER BY bm25(MediaSearchIndex, 0.0, 10.0, 7.0, 1.0), rowid
            LIMIT $limit OFFSET $offset;
            """;
        AddAccessParameters(command);
        foreach (var (name, value) in new[] { ("$query", (object)expression), ("$limit", limit), ("$offset", offset) })
        {
            var parameter = command.CreateParameter();
            parameter.ParameterName = name;
            parameter.Value = value;
            command.Parameters.Add(parameter);
        }

        var ids = new List<Guid>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var compact = reader.GetString(0);
            if (compact.Length == 32 && Guid.TryParseExact(compact, "N", out var id)) ids.Add(id);
        }
        return (ids, total);
    }

    private void AddAccessParameters(System.Data.Common.DbCommand command)
    {
        foreach (var (name, value) in new[]
                 {
                     ("$unrestricted", (object)(database.AccessUserId == null || database.AccessIsOwner ? 1 : 0)),
                     ("$user", (object)(database.AccessUserId?.ToString().ToUpperInvariant() ?? string.Empty)),
                 })
        {
            var parameter = command.CreateParameter();
            parameter.ParameterName = name;
            parameter.Value = value;
            command.Parameters.Add(parameter);
        }
    }
}
