using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;

namespace Aurelia.Server.Services;

public static class MetadataPresentation
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public static MediaMetadataSummary ToSummary(MediaItem item)
    {
        var metadata = item.Metadata;
        var artwork = metadata?.Artwork.Where(asset => asset.Kind != ArtworkKind.Profile)
            .GroupBy(asset => asset.Kind).ToDictionary(group => group.Key, group => group.First());
        return new MediaMetadataSummary(
            item.Id,
            metadata?.ManualTitle ?? metadata?.ProviderTitle ?? item.OverrideTitle ?? item.DetectedTitle,
            metadata?.ManualOriginalTitle ?? metadata?.ProviderOriginalTitle,
            metadata?.ManualOverview ?? metadata?.ProviderOverview,
            metadata?.ManualReleaseDate ?? metadata?.ProviderReleaseDate,
            ParseYear(metadata?.ManualReleaseDate ?? metadata?.ProviderReleaseDate) ?? item.Year,
            metadata?.ManualRuntimeMinutes ?? metadata?.ProviderRuntimeMinutes,
            metadata?.ManualRating ?? metadata?.ProviderRating,
            metadata?.ManualContentRating ?? metadata?.ProviderContentRating,
            ParseList(metadata?.ManualGenresJson ?? metadata?.ProviderGenresJson),
            ParseList(metadata?.ManualStudiosJson ?? metadata?.ProviderStudiosJson),
            ParseList(metadata?.ManualCountriesJson ?? metadata?.ProviderCountriesJson),
            metadata?.Credits.OrderBy(credit => credit.SortOrder).Select(credit => new CreditSummary(
                credit.Name,
                credit.Department,
                credit.Job,
                credit.Character,
                credit.SortOrder,
                metadata.Artwork.FirstOrDefault(asset => asset.Kind == ArtworkKind.Profile && asset.ProviderPath == credit.ProfilePath) is { } profile
                    ? ToArtwork(profile) : null)).ToList() ?? [],
            artwork?.GetValueOrDefault(ArtworkKind.Poster) is { } poster ? ToArtwork(poster) : null,
            artwork?.GetValueOrDefault(ArtworkKind.Backdrop) is { } backdrop ? ToArtwork(backdrop) : null,
            artwork?.GetValueOrDefault(ArtworkKind.Still) is { } still ? ToArtwork(still) : null,
            metadata?.Provider,
            metadata?.ProviderMediaId,
            metadata?.ReviewState ?? MetadataReviewState.NeedsReview);
    }

    public static ArtworkSummary ToArtwork(ArtworkAsset asset) => new(
        asset.Id,
        asset.Kind,
        $"/api/v1/artwork/{asset.Id}",
        asset.ContentType,
        asset.ContentLength);

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
