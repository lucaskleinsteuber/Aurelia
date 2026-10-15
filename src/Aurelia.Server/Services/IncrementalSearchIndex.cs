namespace Aurelia.Server.Services;

public static class IncrementalSearchIndex
{
    // SQLite triggers participate in the same transaction as the catalog change,
    // including ExecuteUpdate/Delete paths and cascades. They never read media files.
    public static IEnumerable<(string Name, string Sql)> Triggers()
    {
        foreach (var (table, key) in new[] { ("MediaItems", "Id"), ("MediaMetadata", "MediaItemId"), ("MediaCredits", "MediaItemId") })
            foreach (var action in new[] { "INSERT", "UPDATE", "DELETE" })
            {
                var row = action == "DELETE" ? "OLD" : "NEW";
                var id = $"{row}.{key}";
                var affected = $"(m.Id = {id} OR m.ParentId = {id})";
                var name = $"search_{table}_{action}";
                yield return (name, $"""
                CREATE TRIGGER {name} AFTER {action} ON {table} BEGIN
                    DELETE FROM MediaSearchIndex WHERE MediaId = {id}
                        OR MediaId IN (SELECT Id FROM MediaItems WHERE ParentId = {id});
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
                    WHERE {affected} AND m.Kind IN ('Movie', 'Series', 'Episode');
                END;
                """);
            }
    }
}
