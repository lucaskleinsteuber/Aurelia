using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;

namespace Aurelia.Server.Services;

public static class MetadataPresentation
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>Portrait cards use the series poster when an episode has no poster of its own.</summary>
    public static ArtworkSummary? CardPoster(MediaItem item, MediaMetadataSummary metadata) =>
        metadata.Poster ?? (item.Kind == MediaKind.Episode && item.Parent is not null
            ? ToSummary(item.Parent).Poster : null);

    public static HashSet<string> ManualFields(MediaMetadata? metadata)
    {
        var fields = ParseList(metadata?.ManualFieldsJson).ToHashSet(StringComparer.Ordinal);
        if (metadata?.ManualTitle is not null) fields.Add("title");
        if (metadata?.ManualOverview is not null) fields.Add("overview");
        if (metadata?.ManualReleaseDate is not null) fields.Add("releaseYear");
        if (metadata?.ManualRuntimeMinutes is not null) fields.Add("runtimeMinutes");
        if (metadata?.ManualContentRating is not null) fields.Add("fsk");
        if (metadata?.ManualGenresJson is not null) fields.Add("genres");
        if (metadata?.ManualStudiosJson is not null) fields.Add("studios");
        if (metadata?.ManualCountriesJson is not null) fields.Add("country");
        return fields;
    }

    public static MediaMetadataSummary ToSummary(MediaItem item, bool automatic = false)
    {
        var metadata = item.Metadata;
        var fields = automatic ? [] : ManualFields(metadata);
        var artwork = metadata?.Artwork.Where(asset => asset.Kind != ArtworkKind.Profile && !asset.IsManual)
            .GroupBy(asset => asset.Kind).ToDictionary(group => group.Key, group => group.First());
        ArtworkAsset? Selected(string field, ArtworkKind kind, Guid? manualId) => fields.Contains(field)
            ? metadata?.Artwork.FirstOrDefault(asset => asset.Id == manualId)
            : artwork?.GetValueOrDefault(kind);
        var poster = Selected("poster", ArtworkKind.Poster, metadata?.ManualPosterId);
        var backdrop = Selected("backdrop", item.Kind == MediaKind.Episode ? ArtworkKind.Still : ArtworkKind.Backdrop, metadata?.ManualBackdropId);
        var contentRating = !automatic ? metadata?.ManualContentRating ?? metadata?.ProviderContentRating : metadata?.ProviderContentRating;
        return new MediaMetadataSummary(
            item.Id,
            (!automatic ? metadata?.ManualTitle : null) ?? metadata?.ProviderTitle ?? item.OverrideTitle ?? item.DetectedTitle,
            metadata?.ManualOriginalTitle ?? metadata?.ProviderOriginalTitle,
            fields.Contains("overview") ? metadata?.ManualOverview : metadata?.ProviderOverview,
            metadata?.ManualReleaseDate ?? metadata?.ProviderReleaseDate,
            fields.Contains("releaseYear") ? metadata?.ManualReleaseYear ?? ParseYear(metadata?.ManualReleaseDate) : ParseYear(metadata?.ProviderReleaseDate) ?? item.Year,
            fields.Contains("runtimeMinutes") ? metadata?.ManualRuntimeMinutes : metadata?.ProviderRuntimeMinutes,
            metadata?.ManualRating ?? metadata?.ProviderRating,
            contentRating,
            ParseList(!automatic ? metadata?.ManualGenresJson ?? metadata?.ProviderGenresJson : metadata?.ProviderGenresJson),
            ParseList(!automatic ? metadata?.ManualStudiosJson ?? metadata?.ProviderStudiosJson : metadata?.ProviderStudiosJson),
            ParseList(!automatic ? metadata?.ManualCountriesJson ?? metadata?.ProviderCountriesJson : metadata?.ProviderCountriesJson),
            metadata?.Credits.OrderBy(credit => credit.SortOrder).Select(credit => new CreditSummary(
                credit.Name,
                credit.Department,
                credit.Job,
                credit.Character,
                credit.SortOrder,
                metadata.Artwork.FirstOrDefault(asset => credit.ProfileAssetId != null ? asset.Id == credit.ProfileAssetId
                    : asset.Kind == ArtworkKind.Profile && asset.ProviderPath == credit.ProfilePath) is { } profile
                    ? ToArtwork(profile) : null, credit.Id,
                PersonKey(metadata, credit.ProviderPersonId))).ToList() ?? [],
            poster is not null ? ToArtwork(poster) : null,
            backdrop is not null ? ToArtwork(backdrop) : null,
            item.Kind == MediaKind.Episode && backdrop is not null ? ToArtwork(backdrop) : null,
            metadata?.Provider,
            metadata?.ProviderMediaId,
            metadata?.ReviewState ?? MetadataReviewState.NeedsReview,
            ParseFsk(contentRating));
    }

    /// <summary>The most actors a title's page lists (owner, 16.11.2026: "about 50 are enough").</summary>
    public const int ShownCast = 50;

    /// <summary>The most crew a title's page lists, the key jobs first.</summary>
    public const int ShownCrew = 12;

    // The crew a page names, in this order; the rest (hundreds for a long series) stays in the editor.
    private static readonly string[] KeyJobs =
    [
        "Creator", "Director", "Screenplay", "Writer", "Novel", "Story", "Original Music Composer",
        "Director of Photography", "Producer", "Executive Producer",
    ];

    /// <summary>
    /// The credits a title's page shows: the first <see cref="ShownCast"/> actors and up to
    /// <see cref="ShownCrew"/> people with key jobs, each with all their credits. A series from
    /// TMDB lists everyone who ever worked on it (Better Call Saul: about 600), which made its page
    /// and every client's rail slow. Everything stays saved; the metadata editor still sees all.
    /// </summary>
    public static MediaMetadataSummary ForPage(MediaMetadataSummary metadata)
    {
        ArgumentNullException.ThrowIfNull(metadata);
        var credits = metadata.Credits.Select((credit, index) => (Credit: credit, Index: index,
            Key: credit.PersonKey ?? credit.Id?.ToString() ?? $"#{index}")).ToList();
        static bool Acting(CreditSummary credit) => string.Equals(credit.Department, "Acting", StringComparison.OrdinalIgnoreCase);
        static int JobRank(CreditSummary credit) => credit.Job is { } job
            ? Array.FindIndex(KeyJobs, key => string.Equals(key, job, StringComparison.OrdinalIgnoreCase)) : -1;
        var cast = credits.Where(entry => Acting(entry.Credit))
            .OrderBy(entry => entry.Credit.Order).ThenBy(entry => entry.Index)
            .Select(entry => entry.Key).Distinct(StringComparer.Ordinal).Take(ShownCast);
        var crew = credits.Where(entry => !Acting(entry.Credit) && JobRank(entry.Credit) >= 0)
            .OrderBy(entry => JobRank(entry.Credit)).ThenBy(entry => entry.Credit.Order).ThenBy(entry => entry.Index)
            .Select(entry => entry.Key).Distinct(StringComparer.Ordinal).Take(ShownCrew);
        var shown = cast.Concat(crew).ToHashSet(StringComparer.Ordinal);
        if (shown.Count == credits.Select(entry => entry.Key).Distinct(StringComparer.Ordinal).Count()) return metadata;
        return metadata with { Credits = [.. credits.Where(entry => shown.Contains(entry.Key)).Select(entry => entry.Credit)] };
    }

    internal static string? PersonKey(MediaMetadata? metadata, string? providerPersonId) =>
        string.IsNullOrWhiteSpace(metadata?.Provider) || string.IsNullOrWhiteSpace(providerPersonId)
            ? null : $"{metadata.Provider.ToLowerInvariant()}:person:{providerPersonId}";

    public static int? ParseFsk(string? value)
    {
        if (value is null || !value.StartsWith("FSK ", StringComparison.OrdinalIgnoreCase)) return null;
        return int.TryParse(value.AsSpan(4), out var age) && age is 0 or 6 or 12 or 16 or 18 ? age : null;
    }

    public static ArtworkSummary ToArtwork(ArtworkAsset asset) => new(
        asset.Id,
        asset.Kind,
        $"/api/v1/artwork/{asset.Id}",
        asset.ContentType,
        asset.ContentLength,
        asset.Revision);

    public static IReadOnlyList<string> ParseList(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return [];
        try { return JsonSerializer.Deserialize<List<string>>(json, JsonOptions) ?? []; }
        catch (JsonException) { return []; }
    }

    public static string SerializeList(IReadOnlyList<string> values) => JsonSerializer.Serialize(
        values.Select(value => value.Trim()).Where(value => value.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).Take(50),
        JsonOptions);

    private static int? ParseYear(string? date) =>
        date is { Length: >= 4 } && int.TryParse(date[..4], out var year) ? year : null;
}
