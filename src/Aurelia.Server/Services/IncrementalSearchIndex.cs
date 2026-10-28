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
                var guardedMediaUpdate = table == "MediaItems" && action == "UPDATE";
                var affected = guardedMediaUpdate
                    ? "(m.Id IN (OLD.Id, NEW.Id) OR m.ParentId IN (OLD.Id, NEW.Id))"
                    : $"(m.Id = {id} OR m.ParentId = {id})";
                var deleted = guardedMediaUpdate
                    ? "MediaId IN (OLD.Id, NEW.Id) OR MediaId IN (SELECT Id FROM MediaItems WHERE ParentId IN (OLD.Id, NEW.Id))"
                    : $"MediaId = {id} OR MediaId IN (SELECT Id FROM MediaItems WHERE ParentId = {id})";
                // A rescan changes bookkeeping on every row. None of these document inputs changed,
                // so its UPDATE must not scan/delete/rebuild the full-text index.
                var when = guardedMediaUpdate
                    ? " WHEN OLD.Id IS NOT NEW.Id OR OLD.Kind IS NOT NEW.Kind OR OLD.ParentId IS NOT NEW.ParentId"
                        + " OR OLD.DetectedTitle IS NOT NEW.DetectedTitle OR OLD.OverrideTitle IS NOT NEW.OverrideTitle"
                        + " OR OLD.SeasonNumber IS NOT NEW.SeasonNumber OR OLD.EpisodeNumber IS NOT NEW.EpisodeNumber"
                    : string.Empty;
                var name = $"search_{table}_{action}";
                yield return (name, $"""
                CREATE TRIGGER {name} AFTER {action} ON {table}{when} BEGIN
                    DELETE FROM MediaSearchIndex WHERE {deleted};
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
