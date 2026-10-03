using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class MediaEditorService(AureliaDbContext database, CatalogMutationGate mutations,
    EditorArtworkStore images, ActiveStreamRegistry streams, LibraryMutationService cleanup)
{
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly HashSet<string> Fields = new(StringComparer.Ordinal)
    { "title", "releaseYear", "overview", "runtimeMinutes", "fsk", "genres", "studios", "country", "credits", "poster", "backdrop" };

    internal async Task<MediaItem> ItemAsync(Guid id, CancellationToken token) =>
        await database.MediaItems.Include(item => item.LibraryRoot)
            .Include(item => item.Metadata)!.ThenInclude(meta => meta!.Credits)
            .Include(item => item.Metadata)!.ThenInclude(meta => meta!.Artwork)
            .SingleOrDefaultAsync(item => item.Id == id, token)
        ?? throw new AccountException("media_not_found", "The title is unavailable or not shared with your account.", 404);

    public async Task<MediaEditorDocument> GetAsync(Guid id, CancellationToken token) => Document(await ItemAsync(id, token));

    private static MediaEditorDocument Document(MediaItem item)
    {
        var summary = MetadataPresentation.ToSummary(item);
        var automatic = MetadataPresentation.ToSummary(item, automatic: true);
        var providerCredits = AutomaticCredits(item);
        MediaEditorValues Values(MediaMetadataSummary value, IReadOnlyList<EditorCredit> credits) => new(
            value.Title, value.Year, value.Overview, item.Kind == MediaKind.Movie ? value.RuntimeMinutes : null,
            value.FskAge, value.Genres, value.Studios, value.Countries.Count > 0 ? value.Countries[0] : null, credits,
            Artwork(item, value.Poster?.Id), Artwork(item, value.Backdrop?.Id));
        var credits = item.Metadata?.Credits.OrderBy(credit => credit.SortOrder)
            .Select(credit => Credit(item, credit)).ToArray() ?? [];
        return new(item.Id, item.LibraryRootId, item.Kind, item.Metadata?.EditorRevision ?? 0,
            Values(summary, credits), MetadataPresentation.ManualFields(item.Metadata).Order().ToArray(),
            item.SourcePath, Path.GetRelativePath(item.LibraryRoot.Path, item.SourcePath), Values(automatic, providerCredits));
    }

    internal static EditorCredit Credit(MediaItem item, MediaCredit credit) => new(credit.Id, credit.Name,
        credit.Department, credit.Job, credit.Character,
        Artwork(item, credit.ProfileAssetId ?? item.Metadata?.Artwork.FirstOrDefault(asset => !asset.IsManual
            && asset.Kind == ArtworkKind.Profile && asset.ProviderPath == credit.ProfilePath)?.Id),
        MetadataPresentation.PersonKey(item.Metadata, credit.ProviderPersonId));

    internal static IReadOnlyList<EditorCredit> AutomaticCredits(MediaItem item)
    {
        if (item.Metadata is null) return [];
        if (!MetadataPresentation.ManualFields(item.Metadata).Contains("credits"))
            return item.Metadata.Credits.OrderBy(credit => credit.SortOrder).Select(credit => Credit(item, credit)).ToArray();
        return JsonSerializer.Deserialize<EditorCredit[]>(item.Metadata.ProviderCreditsJson, Json) ?? [];
    }

    private static EditorArtwork? Artwork(MediaItem item, Guid? id)
    {
        var asset = item.Metadata?.Artwork.FirstOrDefault(asset => asset.Id == id);
        return asset is null ? null : new(asset.Id, Crop: asset.CropJson is null ? null : JsonSerializer.Deserialize<ArtworkCrop>(asset.CropJson, Json));
    }

    public async Task<MediaEditorDocument> SaveAsync(Guid id, Guid userId, Guid sessionId,
        SaveMediaEditorRequest request, CancellationToken token)
    {
        using var lease = await mutations.EnterAsync(token);
        var item = await ItemAsync(id, token);
        var fields = (request.OverrideFields ?? []).ToHashSet(StringComparer.Ordinal);
        if (fields.Any(field => !Fields.Contains(field))) throw Invalid("An unknown manual field was supplied.");
        if ((item.Metadata?.EditorRevision ?? 0) != request.Revision)
            throw new AccountException("editor_conflict", "This title changed on the server. Your draft is still open; reload the title before saving again.", 409);
        var value = request.Values ?? throw Invalid("Editor values are required.");
        Validate(value, item.Kind);
        await using var transaction = await database.Database.BeginTransactionAsync(token);
        if (item.Metadata is null)
        {
            item.Metadata = new MediaMetadata { MediaItemId = item.Id };
            database.MediaMetadata.Add(item.Metadata);
        }
        var meta = item.Metadata;
        if (fields.Contains("credits") && !MetadataPresentation.ManualFields(meta).Contains("credits"))
            meta.ProviderCreditsJson = JsonSerializer.Serialize(AutomaticCredits(item), Json);
        meta.ManualTitle = fields.Contains("title") ? value.Title.Trim() : null;
        meta.ManualOverview = fields.Contains("overview") ? value.Overview?.Trim() ?? "" : null;
        meta.ManualReleaseYear = fields.Contains("releaseYear") ? value.ReleaseYear : null;
        meta.ManualReleaseDate = null;
        meta.ManualRuntimeMinutes = fields.Contains("runtimeMinutes") && item.Kind == MediaKind.Movie ? value.RuntimeMinutes : null;
        meta.ManualContentRating = fields.Contains("fsk") ? value.FskAge is { } age ? $"FSK {age}" : "" : null;
        meta.ManualGenresJson = fields.Contains("genres") ? MetadataPresentation.SerializeList(value.Genres) : null;
        meta.ManualStudiosJson = fields.Contains("studios") ? MetadataPresentation.SerializeList(value.Studios) : null;
        meta.ManualCountriesJson = fields.Contains("country") ? MetadataPresentation.SerializeList(string.IsNullOrWhiteSpace(value.Country) ? [] : [value.Country]) : null;
        meta.ManualPosterId = fields.Contains("poster") ? (await images.MaterializeAsync(database, id, userId, sessionId, value.Poster, ArtworkKind.Poster, token))?.Id : null;
        meta.ManualBackdropId = fields.Contains("backdrop") ? (await images.MaterializeAsync(database, id, userId, sessionId, value.Backdrop,
            item.Kind == MediaKind.Episode ? ArtworkKind.Still : ArtworkKind.Backdrop, token))?.Id : null;
        if (fields.Contains("credits") || MetadataPresentation.ManualFields(meta).Contains("credits"))
        {
            var automaticCredits = AutomaticCredits(item);
            var selected = fields.Contains("credits") ? value.Credits : automaticCredits;
            var existing = meta.Credits.ToDictionary(credit => credit.Id);
            foreach (var removed in meta.Credits.Where(credit => !selected.Any(value => value.Id == credit.Id)).ToArray())
            { database.MediaCredits.Remove(removed); meta.Credits.Remove(removed); }
            for (var index = 0; index < selected.Count; index++)
            {
                var draft = selected[index];
                var credit = existing.GetValueOrDefault(draft.Id);
                if (credit is null)
                {
                    if (await database.MediaCredits.IgnoreQueryFilters().AnyAsync(credit => credit.Id == draft.Id, token))
                        throw Invalid("A person ID is already in use.");
                    credit = new MediaCredit { Id = draft.Id, MediaItemId = id };
                    // Only a server-stored snapshot may restore a deleted provider identity.
                    // PersonKey in an incoming editor draft is never trusted as an assignment.
                    var trustedKey = automaticCredits.FirstOrDefault(value => value.Id == draft.Id)?.PersonKey;
                    var prefix = $"{meta.Provider?.ToLowerInvariant()}:person:";
                    if (meta.Provider is not null && trustedKey?.StartsWith(prefix, StringComparison.Ordinal) == true)
                        credit.ProviderPersonId = trustedKey[prefix.Length..];
                    database.MediaCredits.Add(credit);
                }
                credit.Name = draft.Name.Trim(); credit.Department = draft.Department.Trim();
                credit.Job = draft.Job?.Trim(); credit.Character = draft.Character?.Trim(); credit.SortOrder = index;
                credit.ProfileAssetId = fields.Contains("credits")
                    ? (await images.MaterializeAsync(database, id, userId, sessionId, draft.Profile, ArtworkKind.Profile, token))?.Id
                    : draft.Profile?.AssetId;
                credit.ProfilePath = null;
            }
        }
        if (request.RelativeSourcePath is { } relative && relative != Path.GetRelativePath(item.LibraryRoot.Path, item.SourcePath))
        {
            if (item.Kind is not MediaKind.Movie and not MediaKind.Episode) throw Invalid("Only movies and individual episodes can change their video file.");
            var source = SourcePath(item.LibraryRoot.Path, relative);
            if (!MediaLibraryScanner.IsSupportedMediaPath(source)) throw Invalid("Choose a supported video file.");
            using var handle = PinnedMediaHandle.Open(item.LibraryRoot.Path, source);
            var normalized = MediaPath.Normalize(source);
            if (await database.MediaItems.IgnoreQueryFilters().AnyAsync(other => other.Id != id && other.NormalizedSourcePath == normalized, token))
                throw new AccountException("source_in_use", "This video file already belongs to another title.", 409);
            if (!await database.MediaExclusions.AnyAsync(exclude => exclude.LibraryRootId == item.LibraryRootId && exclude.NormalizedSourcePath == item.NormalizedSourcePath, token))
                database.MediaExclusions.Add(new MediaExclusion
                {
                    Id = Guid.NewGuid(),
                    LibraryRootId = item.LibraryRootId,
                    RelativePath = Path.GetRelativePath(item.LibraryRoot.Path, item.SourcePath),
                    NormalizedSourcePath = item.NormalizedSourcePath,
                    FileSystemIdentity = item.FileSystemIdentity
                });
            await database.MediaExclusions.Where(exclude => exclude.LibraryRootId == item.LibraryRootId && exclude.NormalizedSourcePath == normalized).ExecuteDeleteAsync(token);
            item.SourcePath = source; item.NormalizedSourcePath = normalized; item.ManualSourceBinding = true;
            // An import draft was resolved against the old binding. Invalidate
            // it atomically with the editor save, without penalizing metadata edits.
            item.LibraryRoot.ImportAssignmentRevision++;
            item.Extension = Path.GetExtension(source).ToLowerInvariant(); item.FileSize = handle.Length;
            item.FileModifiedAt = File.GetLastWriteTimeUtc(source); item.FileSystemIdentity = null;
            item.Availability = MediaAvailability.Available;
            await database.PlaybackTickets.Where(ticket => ticket.MediaItemId == id).ExecuteDeleteAsync(token);
            streams.RevokeMedia([id]);
        }
        meta.ManualFieldsJson = JsonSerializer.Serialize(fields.Order().ToArray(), Json);
        var selectedImages = meta.Credits.Select(credit => credit.ProfileAssetId)
            .Concat([meta.ManualPosterId, meta.ManualBackdropId]).ToHashSet();
        var unusedImages = meta.Artwork.Where(asset => asset.IsManual && !selectedImages.Contains(asset.Id)).ToArray();
        database.ArtworkAssets.RemoveRange(unusedImages);
        foreach (var asset in unusedImages) meta.Artwork.Remove(asset);
        var cleanupId = unusedImages.Length == 0 ? (Guid?)null : cleanup.TrackArtworkCleanup(userId,
            unusedImages.SelectMany(asset => new[] { asset.RelativeFilePath, asset.OriginalFilePath }).OfType<string>().Distinct().ToArray());
        meta.UpdatedAt = item.UpdatedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(token);
        await transaction.CommitAsync(token);
        if (cleanupId.HasValue) await cleanup.CleanupAsync(cleanupId.Value, token);
        return Document(item);
    }

    public async Task<ServerFileListing> FilesAsync(Guid id, string? relative, CancellationToken token)
    {
        var item = await ItemAsync(id, token);
        var path = SourcePath(item.LibraryRoot.Path, relative ?? ".");
        var entries = PinnedMediaHandle.ListDirectory(item.LibraryRoot.Path, path)
            .Where(entry => entry.Directory || MediaLibraryScanner.IsSupportedMediaPath(entry.Name))
            .OrderByDescending(entry => entry.Directory).ThenBy(entry => entry.Name, StringComparer.OrdinalIgnoreCase)
            .Select(entry => new ServerFileEntry(entry.Name, Path.GetRelativePath(item.LibraryRoot.Path, Path.Combine(path, entry.Name)), entry.Directory, null)).ToArray();
        return new(item.LibraryRootId, Path.GetRelativePath(item.LibraryRoot.Path, path), entries);
    }

    internal static string SourcePath(string root, string relative)
    {
        if (Path.IsPathRooted(relative) || relative.Contains('\0')) throw Invalid("Select a file within this storage location.");
        var path = Path.GetFullPath(Path.Combine(root, relative));
        var check = Path.GetRelativePath(Path.GetFullPath(root), path);
        if (check == ".." || check.StartsWith("../", StringComparison.Ordinal)) throw Invalid("Select a file within this storage location.");
        return path;
    }

    private static void Validate(MediaEditorValues value, MediaKind kind)
    {
        if (string.IsNullOrWhiteSpace(value.Title) || value.Title.Length > 512 || value.Overview?.Length > 8192
            || value.ReleaseYear is < 1800 or > 3000 || value.FskAge is not null and not 0 and not 6 and not 12 and not 16 and not 18
            || value.RuntimeMinutes is < 1 or > 14400 || kind != MediaKind.Movie && value.RuntimeMinutes is not null
            || value.Country?.Length > 128) throw Invalid("Check the title, year, runtime, FSK and description.");
        foreach (var list in new[] { value.Genres, value.Studios })
            if (list is null || list.Count > 50 || list.Any(entry => string.IsNullOrWhiteSpace(entry) || entry.Length > 128)) throw Invalid("Lists support up to 50 non-empty entries of 128 characters.");
        if (value.Credits is null || value.Credits.Count > 500
            || value.Credits.Any(credit => credit is null || credit.Id == Guid.Empty || string.IsNullOrWhiteSpace(credit.Name) || credit.Name.Length > 256
                || credit.Department is null || credit.Department.Length > 64 || credit.Job?.Length > 128 || credit.Character?.Length > 512)
            || value.Credits.Select(credit => credit.Id).Distinct().Count() != value.Credits.Count)
            throw Invalid("Check the names and roles. Up to 500 distinct people are supported.");
    }
    private static AccountException Invalid(string message) => new("invalid_editor", message, 400);
}
