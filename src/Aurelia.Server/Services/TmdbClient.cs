using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public interface ITmdbClient
{
    Task ValidateAsync(string token, CancellationToken cancellationToken);
    Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(
        string token,
        string language,
        MediaKind kind,
        string title,
        int? year,
        CancellationToken cancellationToken);
    Task<TmdbMetadata> GetAsync(
        string token,
        string language,
        string mediaType,
        string providerId,
        CancellationToken cancellationToken);
    Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(
        string token,
        string language,
        string seriesProviderId,
        int seasonNumber,
        CancellationToken cancellationToken);
    Task<byte[]> DownloadImageAsync(
        string token,
        string providerPath,
        string size,
        CancellationToken cancellationToken);
}

public sealed class TmdbClient(HttpClient client) : ITmdbClient
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task ValidateAsync(string token, CancellationToken cancellationToken)
    {
        using var response = await SendAsync(token, "authentication", cancellationToken);
        await EnsureSuccessAsync(response, cancellationToken);
    }

    public async Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(
        string token,
        string language,
        MediaKind kind,
        string title,
        int? year,
        CancellationToken cancellationToken)
    {
        var mediaType = kind == MediaKind.Movie ? "movie" : "tv";
        var yearParameter = kind == MediaKind.Movie ? "year" : "first_air_date_year";
        var path = $"search/{mediaType}?query={Uri.EscapeDataString(title)}&language={language}&include_adult=false";
        if (year.HasValue)
        {
            path += $"&{yearParameter}={year.Value.ToString(CultureInfo.InvariantCulture)}";
        }

        using var response = await SendAsync(token, path, cancellationToken);
        await EnsureSuccessAsync(response, cancellationToken);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken));
        var results = document.RootElement.GetProperty("results").EnumerateArray().Take(8);
        return results.Select(result =>
        {
            var candidateTitle = GetString(result, mediaType == "movie" ? "title" : "name") ?? "Untitled";
            var originalTitle = GetString(result, mediaType == "movie" ? "original_title" : "original_name");
            var date = GetString(result, mediaType == "movie" ? "release_date" : "first_air_date");
            var candidateYear = ParseYear(date);
            var confidence = MetadataMatcher.Score(
                title, year, candidateTitle, originalTitle, candidateYear);
            return new MetadataCandidateSummary(
                "tmdb",
                result.GetProperty("id").GetInt32().ToString(CultureInfo.InvariantCulture),
                mediaType,
                candidateTitle,
                originalTitle,
                candidateYear,
                GetString(result, "overview"),
                GetString(result, "poster_path"),
                confidence);
        }).OrderByDescending(candidate => candidate.Confidence).ToList();
    }

    public async Task<TmdbMetadata> GetAsync(
        string token,
        string language,
        string mediaType,
        string providerId,
        CancellationToken cancellationToken)
    {
        if (mediaType is not ("movie" or "tv") || !int.TryParse(providerId, out _))
        {
            throw new MetadataException("invalid_metadata_match", "The metadata match is invalid.", StatusCodes.Status400BadRequest);
        }

        var additions = mediaType == "movie" ? "credits,release_dates" : "credits,content_ratings";
        using var response = await SendAsync(
            token,
            $"{mediaType}/{providerId}?language={language}&append_to_response={additions}",
            cancellationToken);
        await EnsureSuccessAsync(response, cancellationToken);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken));
        var root = document.RootElement;
        var title = GetString(root, mediaType == "movie" ? "title" : "name") ?? "Untitled";
        var releaseDate = GetString(root, mediaType == "movie" ? "release_date" : "first_air_date");
        var runtime = mediaType == "movie"
            ? GetNullableInt(root, "runtime")
            : GetFirstInt(root, "episode_run_time");
        var certification = mediaType == "movie"
            ? GetMovieCertification(root)
            : GetTvCertification(root);
        var credits = ParseCredits(root.GetProperty("credits"));
        var collection = root.TryGetProperty("belongs_to_collection", out var collectionElement)
            && collectionElement.ValueKind == JsonValueKind.Object
            ? new TmdbCollectionInfo(
                collectionElement.GetProperty("id").GetInt32().ToString(CultureInfo.InvariantCulture),
                GetString(collectionElement, "name") ?? "Collection",
                GetString(collectionElement, "poster_path"))
            : null;
        return new TmdbMetadata(
            providerId,
            mediaType,
            title,
            GetString(root, mediaType == "movie" ? "original_title" : "original_name"),
            GetString(root, "overview"),
            releaseDate,
            runtime,
            GetNullableDouble(root, "vote_average"),
            certification,
            GetNames(root, "genres"),
            GetNames(root, "production_companies"),
            GetCountryNames(root),
            GetString(root, "poster_path"),
            GetString(root, "backdrop_path"),
            credits,
            collection);
    }

    public async Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(
        string token,
        string language,
        string seriesProviderId,
        int seasonNumber,
        CancellationToken cancellationToken)
    {
        if (!int.TryParse(seriesProviderId, out _) || seasonNumber < 0)
            throw new MetadataException("invalid_metadata_match", "The series metadata match is invalid.", StatusCodes.Status400BadRequest);
        using var response = await SendAsync(token, $"tv/{seriesProviderId}/season/{seasonNumber}?language={language}", cancellationToken);
        await EnsureSuccessAsync(response, cancellationToken);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken));
        if (!document.RootElement.TryGetProperty("episodes", out var episodes)) return [];
        return episodes.EnumerateArray().Select(episode => new TmdbEpisodeMetadata(
            episode.GetProperty("id").GetInt32().ToString(CultureInfo.InvariantCulture),
            seasonNumber,
            episode.GetProperty("episode_number").GetInt32(),
            GetString(episode, "name") ?? $"Episode {episode.GetProperty("episode_number").GetInt32()}",
            GetString(episode, "overview"),
            GetString(episode, "air_date"),
            GetNullableInt(episode, "runtime"),
            GetNullableDouble(episode, "vote_average"),
            GetString(episode, "still_path"))).ToList();
    }

    public async Task<byte[]> DownloadImageAsync(
        string token,
        string providerPath,
        string size,
        CancellationToken cancellationToken)
    {
        if (!IsSafeImagePath(providerPath) || size is not ("w342" or "w780" or "w1280"))
        {
            throw new MetadataException("invalid_artwork_path", "The artwork path is invalid.", StatusCodes.Status400BadRequest);
        }

        using var response = await SendWithRetryAsync(() =>
        {
            var request = new HttpRequestMessage(HttpMethod.Get, $"https://image.tmdb.org/t/p/{size}{providerPath}");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            return request;
        }, cancellationToken);
        await EnsureSuccessAsync(response, cancellationToken);
        if (response.Content.Headers.ContentLength is > 10 * 1024 * 1024)
        {
            throw new MetadataException("artwork_too_large", "The artwork file is too large.", StatusCodes.Status422UnprocessableEntity);
        }

        var bytes = await ReadBoundedAsync(response.Content, 10 * 1024 * 1024, cancellationToken);
        if (!ArtworkFile.IsSupported(bytes))
        {
            throw new MetadataException("invalid_artwork", "TMDB returned an unsupported image.", StatusCodes.Status422UnprocessableEntity);
        }

        return bytes;
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpContent content, int maximumBytes, CancellationToken cancellationToken)
    {
        await using var source = await content.ReadAsStreamAsync(cancellationToken);
        using var destination = new MemoryStream(capacity: Math.Min(maximumBytes, 256 * 1024));
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var count = await source.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (count == 0) return destination.ToArray();
            if (destination.Length + count > maximumBytes)
                throw new MetadataException("artwork_too_large", "The artwork file is too large.", StatusCodes.Status422UnprocessableEntity);
            await destination.WriteAsync(buffer.AsMemory(0, count), cancellationToken);
        }
    }

    private async Task<HttpResponseMessage> SendAsync(string token, string path, CancellationToken cancellationToken)
    {
        return await SendWithRetryAsync(() =>
        {
            var request = new HttpRequestMessage(HttpMethod.Get, new Uri(new Uri("https://api.themoviedb.org/3/"), path));
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            return request;
        }, cancellationToken);
    }

    private async Task<HttpResponseMessage> SendWithRetryAsync(
        Func<HttpRequestMessage> requestFactory,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; ; attempt++)
        {
            using var request = requestFactory();
            var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (attempt >= 2 || ((int)response.StatusCode != StatusCodes.Status429TooManyRequests && (int)response.StatusCode < 500))
            {
                return response;
            }

            var retryAfter = response.Headers.RetryAfter switch
            {
                { Delta: { } delta } => delta,
                { Date: { } date } => date - DateTimeOffset.UtcNow,
                _ => TimeSpan.FromMilliseconds(250 * Math.Pow(2, attempt)),
            };
            if (retryAfter < TimeSpan.Zero)
            {
                retryAfter = TimeSpan.Zero;
            }
            response.Dispose();
            await Task.Delay(retryAfter > TimeSpan.FromSeconds(10) ? TimeSpan.FromSeconds(10) : retryAfter, cancellationToken);
        }
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        _ = await response.Content.ReadAsStringAsync(cancellationToken);
        var status = (int)response.StatusCode;
        throw new MetadataException(
            status is 401 or 403 ? "metadata_authentication_failed" : "metadata_provider_failed",
            status is 401 or 403 ? "TMDB rejected the API token." : "TMDB is temporarily unavailable.",
            status is 401 or 403 ? StatusCodes.Status400BadRequest : StatusCodes.Status502BadGateway);
    }

    private static bool IsSafeImagePath(string path) =>
        path.Length is > 1 and <= 256
        && path[0] == '/'
        && !path.Contains("..", StringComparison.Ordinal)
        && path.All(character => char.IsLetterOrDigit(character) || character is '/' or '_' or '-' or '.');

    private static string? GetString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static int? GetNullableInt(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetInt32(out var result) ? result : null;

    private static double? GetNullableDouble(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetDouble(out var result) ? result : null;

    private static int? GetFirstInt(JsonElement element, string name) =>
        element.TryGetProperty(name, out var values) && values.ValueKind == JsonValueKind.Array
            ? values.EnumerateArray().Select(value => value.TryGetInt32(out var result) ? result : (int?)null).FirstOrDefault(value => value.HasValue)
            : null;

    private static int? ParseYear(string? date) =>
        date is { Length: >= 4 } && int.TryParse(date[..4], out var year) ? year : null;

    private static List<string> GetNames(JsonElement root, string property) =>
        root.TryGetProperty(property, out var values) && values.ValueKind == JsonValueKind.Array
            ? values.EnumerateArray().Select(value => GetString(value, "name")).Where(value => !string.IsNullOrWhiteSpace(value)).Cast<string>().ToList()
            : [];

    private static List<string> GetCountryNames(JsonElement root) =>
        root.TryGetProperty("production_countries", out var values) && values.ValueKind == JsonValueKind.Array
            ? values.EnumerateArray().Select(value => GetString(value, "iso_3166_1") ?? GetString(value, "name")).Where(value => !string.IsNullOrWhiteSpace(value)).Cast<string>().ToList()
            : [];

    private static IReadOnlyList<TmdbCredit> ParseCredits(JsonElement credits)
    {
        var result = new List<TmdbCredit>();
        if (credits.TryGetProperty("cast", out var cast))
        {
            result.AddRange(cast.EnumerateArray().Take(40).Select((person, index) => new TmdbCredit(
                person.GetProperty("id").GetInt32().ToString(CultureInfo.InvariantCulture),
                GetString(person, "name") ?? "Unknown",
                "Acting",
                null,
                GetString(person, "character"),
                index,
                GetString(person, "profile_path"))));
        }

        if (credits.TryGetProperty("crew", out var crew))
        {
            result.AddRange(crew.EnumerateArray()
                .Where(person => GetString(person, "job") is "Director" or "Writer" or "Screenplay" or "Creator" or "Producer")
                .Take(40)
                .Select((person, index) => new TmdbCredit(
                    person.GetProperty("id").GetInt32().ToString(CultureInfo.InvariantCulture),
                    GetString(person, "name") ?? "Unknown",
                    GetString(person, "department") ?? "Crew",
                    GetString(person, "job"),
                    null,
                    100 + index,
                    GetString(person, "profile_path"))));
        }

        return MetadataCreditDeduplicator.Deduplicate(result);
    }

    private static string? GetMovieCertification(JsonElement root)
    {
        if (!root.TryGetProperty("release_dates", out var releaseDates)
            || !releaseDates.TryGetProperty("results", out var results))
        {
            return null;
        }

        var country = results.EnumerateArray().FirstOrDefault(value => GetString(value, "iso_3166_1") == "US");
        return country.ValueKind == JsonValueKind.Object && country.TryGetProperty("release_dates", out var dates)
            ? dates.EnumerateArray().Select(value => GetString(value, "certification")).FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))
            : null;
    }

    private static string? GetTvCertification(JsonElement root)
    {
        if (!root.TryGetProperty("content_ratings", out var ratings)
            || !ratings.TryGetProperty("results", out var results))
        {
            return null;
        }

        return results.EnumerateArray().Where(value => GetString(value, "iso_3166_1") == "US").Select(value => GetString(value, "rating")).FirstOrDefault();
    }
}

public static class MetadataMatcher
{
    public static double Score(
        string requested,
        int? requestedYear,
        string title,
        string? originalTitle,
        int? candidateYear)
    {
        var requestedNormalized = Normalize(requested);
        if (requestedNormalized.Length == 0)
        {
            return 0.1;
        }

        var candidateTitles = new[] { title, originalTitle ?? string.Empty }
            .Select(Normalize)
            .Where(value => value.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .ToList();
        var exactTitleMatch = candidateTitles.Contains(requestedNormalized, StringComparer.Ordinal);
        if (exactTitleMatch)
        {
            return requestedYear.HasValue && candidateYear.HasValue
                ? requestedYear == candidateYear ? 1 : 0.82
                : 0.96;
        }

        var titleSimilarity = candidateTitles
            .Select(candidate => Similarity(requestedNormalized, candidate))
            .DefaultIfEmpty(0)
            .Max();
        var score = 0.1 + titleSimilarity * 0.82;
        if (requestedYear.HasValue && candidateYear.HasValue)
        {
            score = requestedYear == candidateYear
                ? score + 0.01
                : score * 0.7;
        }

        // Only an exact normalized title can be automatically applied. Similarity
        // still gives reviewers a useful, deterministic ordering without letting a
        // provider's result position act as evidence.
        return Math.Clamp(score, 0.1, 0.94);
    }

    public static bool IsUnambiguous(IReadOnlyList<MetadataCandidateSummary> candidates) =>
        candidates.Count > 0
        && candidates[0].Confidence >= 0.95
        && (candidates.Count == 1 || candidates[0].Confidence - candidates[1].Confidence >= 0.08);

    private static string Normalize(string value) =>
        FilenameMetadataParser.NormalizeMatchTitle(value);

    private static double Similarity(string left, string right)
    {
        var previous = Enumerable.Range(0, right.Length + 1).ToArray();
        var current = new int[right.Length + 1];
        for (var leftIndex = 1; leftIndex <= left.Length; leftIndex++)
        {
            current[0] = leftIndex;
            for (var rightIndex = 1; rightIndex <= right.Length; rightIndex++)
            {
                var substitution = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1;
                current[rightIndex] = Math.Min(
                    Math.Min(current[rightIndex - 1] + 1, previous[rightIndex] + 1),
                    previous[rightIndex - 1] + substitution);
            }

            (previous, current) = (current, previous);
        }

        return 1 - (double)previous[right.Length] / Math.Max(left.Length, right.Length);
    }
}

public static class MetadataCreditDeduplicator
{
    public static IReadOnlyList<TmdbCredit> Deduplicate(IEnumerable<TmdbCredit> credits)
    {
        var seen = new HashSet<CreditKey>();
        var result = new List<TmdbCredit>();
        foreach (var credit in credits)
        {
            if (string.IsNullOrWhiteSpace(credit.ProviderId))
            {
                result.Add(credit);
                continue;
            }

            var key = new CreditKey(
                Normalize(credit.ProviderId),
                Normalize(credit.Job),
                Normalize(credit.Character));
            if (seen.Add(key))
            {
                result.Add(credit);
            }
        }

        return result;
    }

    private static string Normalize(string? value) =>
        (value ?? string.Empty).Trim().Normalize(NormalizationForm.FormKC).ToUpperInvariant();

    private readonly record struct CreditKey(
        string ProviderId,
        string Job,
        string Character);
}

public sealed record TmdbMetadata(
    string ProviderId,
    string MediaType,
    string Title,
    string? OriginalTitle,
    string? Overview,
    string? ReleaseDate,
    int? RuntimeMinutes,
    double? Rating,
    string? ContentRating,
    IReadOnlyList<string> Genres,
    IReadOnlyList<string> Studios,
    IReadOnlyList<string> Countries,
    string? PosterPath,
    string? BackdropPath,
    IReadOnlyList<TmdbCredit> Credits,
    TmdbCollectionInfo? Collection);

public sealed record TmdbCredit(string ProviderId, string Name, string Department, string? Job, string? Character, int Order, string? ProfilePath);
public sealed record TmdbCollectionInfo(string ProviderId, string Name, string? PosterPath);
public sealed record TmdbEpisodeMetadata(string ProviderId, int SeasonNumber, int EpisodeNumber, string Title, string? Overview, string? AirDate, int? RuntimeMinutes, double? Rating, string? StillPath);

public static class ArtworkFile
{
    public static bool IsSupported(ReadOnlySpan<byte> bytes) =>
        bytes.Length >= 12 && (
            (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[^2] == 0xff && bytes[^1] == 0xd9)
            || bytes[..8].SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })
            || (bytes[..4].SequenceEqual("RIFF"u8) && bytes.Slice(8, 4).SequenceEqual("WEBP"u8)));

    public static string ContentType(ReadOnlySpan<byte> bytes) => bytes[0] == 0xff
        ? "image/jpeg"
        : bytes[..4].SequenceEqual("RIFF"u8) ? "image/webp" : "image/png";

    public static string Extension(string contentType) => contentType switch
    {
        "image/jpeg" => ".jpg",
        "image/png" => ".png",
        "image/webp" => ".webp",
        _ => throw new InvalidDataException("Unsupported artwork type."),
    };
}
