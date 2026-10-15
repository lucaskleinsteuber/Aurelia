using Aurelia.Server.Data;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed record SeriesResumeRow(Guid SeriesId, Guid TargetId, long? LastPlayedAt, int ActionCode, bool ContinueWatchingEligible);

// One compact selection per series. The episode access boundary precedes every
// window/aggregate, including when a series spans several storage locations.
public sealed class SeriesResumeQuery(AureliaDbContext database)
{
    public IQueryable<SeriesResumeRow> Plans(Guid userId) => database.Database.SqlQueryRaw<SeriesResumeRow>(Sql,
        new SqliteParameter("$user", userId.ToString().ToUpperInvariant()),
        new SqliteParameter("$accessUser", database.AccessUserId?.ToString().ToUpperInvariant() ?? string.Empty),
        new SqliteParameter("$unrestricted", database.AccessUserId == null || database.AccessWholeCatalog ? 1 : 0),
        new SqliteParameter("$mode", database.AccessMode.ToString()));

    private const string Sql = """
        WITH eligible AS (
            SELECT e.Id,e.ParentId AS SeriesId,p.PositionMilliseconds,coalesce(p.IsCompleted,0) AS IsCompleted,p.LastPlayedAt,
                row_number() OVER (PARTITION BY e.ParentId ORDER BY e.SeasonNumber,e.EpisodeNumber,e.DetectedTitle,e.Id) AS Ordinal
            FROM MediaItems e
            LEFT JOIN PlaybackProgress p ON p.MediaItemId=e.Id AND p.UserId=$user
            LEFT JOIN MediaItems parent ON parent.Id=e.ParentId
            LEFT JOIN MediaItems grandparent ON grandparent.Id=parent.ParentId
            WHERE e.Kind='Episode' AND e.SeasonNumber>0 AND ($unrestricted=1
                OR ($mode='LegacyLibraries' AND EXISTS (SELECT 1 FROM UserLibraryGrants g WHERE g.UserId=$accessUser AND g.LibraryRootId=e.LibraryRootId))
                OR ($mode='SelectedTitles' AND EXISTS (SELECT 1 FROM UserTitleGrants g WHERE g.UserId=$accessUser AND g.MediaItemId IN (e.Id,e.ParentId,parent.ParentId,grandparent.ParentId))))
        ), played AS (
            SELECT *,row_number() OVER (PARTITION BY SeriesId ORDER BY LastPlayedAt DESC,Id) AS PlayedRank
            FROM eligible WHERE LastPlayedAt IS NOT NULL
        ), bounds AS (
            SELECT SeriesId,min(Ordinal) AS FirstOrdinal FROM eligible GROUP BY SeriesId
        ), selection AS (
            SELECT b.SeriesId,b.FirstOrdinal,p.LastPlayedAt,p.IsCompleted AS LastCompleted,p.PositionMilliseconds AS LastPosition,
                CASE WHEN p.IsCompleted=0 AND p.PositionMilliseconds>10000 THEN p.Ordinal
                    ELSE (SELECT min(e.Ordinal) FROM eligible e WHERE e.SeriesId=b.SeriesId AND e.IsCompleted=0
                        AND (p.Ordinal IS NULL OR e.Ordinal>=p.Ordinal+CASE WHEN p.IsCompleted=1 THEN 1 ELSE 0 END)) END AS TargetOrdinal
            FROM bounds b LEFT JOIN played p ON p.SeriesId=b.SeriesId AND p.PlayedRank=1
        )
        SELECT s.SeriesId,e.Id AS TargetId,s.LastPlayedAt,
            CASE WHEN s.TargetOrdinal IS NULL THEN 2 WHEN e.IsCompleted=0 AND e.PositionMilliseconds>10000 THEN 1 ELSE 0 END AS ActionCode,
            CASE WHEN s.LastPlayedAt IS NOT NULL AND s.TargetOrdinal IS NOT NULL
                AND (s.LastCompleted=1 OR s.LastPosition>10000) THEN 1 ELSE 0 END AS ContinueWatchingEligible
        FROM selection s JOIN eligible e ON e.SeriesId=s.SeriesId AND e.Ordinal=coalesce(s.TargetOrdinal,s.FirstOrdinal)
        """;
}
