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

    /// <summary>How many seasons and episodes TMDB lists for a show, to tell same-named shows apart.</summary>
    Task<TmdbShowShape> GetShowShapeAsync(string token, string providerId, CancellationToken cancellationToken) =>
        Task.FromResult(new TmdbShowShape(null, null));
}

public sealed record TmdbShowShape(int? Seasons, int? Episodes);

public sealed class TmdbClient(HttpClient client, TimeProvider? clock = null) : ITmdbClient
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
        using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
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
                confidence,
                result.TryGetProperty("vote_count", out var votes) && votes.ValueKind == JsonValueKind.Number
                    && votes.TryGetInt32(out var voteCount) && voteCount >= 0 ? voteCount : null);
        }).OrderByDescending(candidate => candidate.Confidence).ToList();
    }

    public async Task<TmdbShowShape> GetShowShapeAsync(string token, string providerId, CancellationToken cancellationToken)
    {
        if (!int.TryParse(providerId, NumberStyles.None, CultureInfo.InvariantCulture, out _))
        {
            throw new MetadataException("invalid_metadata_match", "The metadata match is invalid.", StatusCodes.Status400BadRequest);
        }

        using var response = await SendAsync(token, $"tv/{providerId}", cancellationToken);
        await EnsureSuccessAsync(response, cancellationToken);
        using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
        static int? Count(JsonElement root, string name) =>
            root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) && number >= 0
                ? number : null;
        return new TmdbShowShape(Count(document.RootElement, "number_of_seasons"), Count(document.RootElement, "number_of_episodes"));
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
        using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
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
        using var response = await SendAsync(token, $"tv/{seriesProviderId}/season/{seasonNumber}?language={language}", cancellationToken, allowNotFound: true);
        // TMDB does not know every season a library has (a special or a differently counted one).
        // That season simply gets no episode details; it is not a failure of the whole series.
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return [];
        await EnsureSuccessAsync(response, cancellationToken);
        using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
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

        using var response = await SendProviderAsync(() =>
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

    private async Task<HttpResponseMessage> SendAsync(string token, string path, CancellationToken cancellationToken, bool allowNotFound = false)
    {
        return await SendProviderAsync(() =>
        {
            var request = new HttpRequestMessage(HttpMethod.Get, new Uri(new Uri("https://api.themoviedb.org/3/"), path));
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            return request;
        }, cancellationToken, allowNotFound);
    }

    private async Task<HttpResponseMessage> SendProviderAsync(
        Func<HttpRequestMessage> requestFactory,
        CancellationToken cancellationToken,
        bool allowNotFound = false)
    {
        using var request = requestFactory();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (client.Timeout != Timeout.InfiniteTimeSpan) deadline.CancelAfter(client.Timeout);
        HttpResponseMessage? response = null;
        try
        {
            response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            if (allowNotFound && response.StatusCode == System.Net.HttpStatusCode.NotFound) return response;
            if (!response.IsSuccessStatusCode)
            {
                var status = (int)response.StatusCode;
                var retryAfter = response.Headers.RetryAfter switch
                {
                    { Delta: { } delta } => delta,
                    { Date: { } date } => date - (clock ?? TimeProvider.System).GetUtcNow(),
                    _ => TimeSpan.Zero,
                };
                throw new MetadataProviderException(
                    status is 401 or 403 ? "TMDB rejected the API token." : "TMDB is temporarily unavailable.",
                    transient: status is 408 or 429 || status >= 500,
                    authenticationFailure: status is 401 or 403,
                    retryAfter: retryAfter > TimeSpan.Zero ? retryAfter : null);
            }
            // The deadline also covers stalled response bodies, not just headers.
            // Only provider JSON/images are buffered; media files never pass here.
            await response.Content.LoadIntoBufferAsync(10 * 1024 * 1024, deadline.Token);
            return response;
        }
        catch (HttpRequestException)
        {
            response?.Dispose();
            throw new MetadataProviderException("TMDB could not be reached.", transient: true);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            response?.Dispose();
            throw new MetadataProviderException("TMDB did not respond in time.", transient: true);
        }
        catch
        {
            response?.Dispose();
            throw;
        }
    }

    private static Task EnsureSuccessAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        response.EnsureSuccessStatusCode();
        return Task.CompletedTask;
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

        // Keep fuzzy matches below the automatic threshold. The narrowly permitted
        // one-letter plural variation is checked separately with a matching year.
        return Math.Clamp(score, 0.1, 0.94);
    }

    public static MetadataCandidateSummary? SelectAutomaticMatch(
        IReadOnlyList<MetadataCandidateSummary> candidates,
        string requestedTitle,
        int? requestedYear)
    {
        if (candidates.Count == 0)
        {
            return null;
        }

        var ranked = candidates.OrderByDescending(candidate => candidate.Confidence).ToList();
        var best = ranked[0];
        var hasClearLead = ranked.Count == 1
            || best.Confidence - ranked[1].Confidence >= 0.08;
        if (!hasClearLead)
        {
            return null;
        }

        if (best.Confidence >= 0.95)
        {
            return best;
        }

        // A single trailing "s" is a common filename/provider variation. It is
        // safe to accept only when the release year agrees and no candidate is
        // close enough to make the choice ambiguous.
        return requestedYear.HasValue
            && best.Year == requestedYear
            && best.Confidence >= 0.86
            && new[] { best.Title, best.OriginalTitle ?? string.Empty }
                .Any(candidate => IsSinglePluralVariant(requestedTitle, candidate))
            ? best
            : null;
    }

    /// <summary>What this library holds of a series: its highest season number and its episode count.</summary>
    public sealed record LocalShape(int? HighestSeason, int EpisodeCount);

    /// <summary>
    /// A second, careful step after <see cref="SelectAutomaticMatch"/>, for titles that are equal by name.
    /// It accepts a candidate only when the other signals single it out: a year one off (regional release
    /// dates), the only exact title, the only show with enough seasons and episodes for the files here, or
    /// a show far better known than the rest with the same name (at least five times the votes).
    /// </summary>
    public static MetadataCandidateSummary? SelectBySignals(
        IReadOnlyList<MetadataCandidateSummary> candidates,
        string requestedTitle,
        int? requestedYear,
        LocalShape? local = null,
        IReadOnlyDictionary<string, TmdbShowShape>? shapes = null)
    {
        var requested = Normalize(requestedTitle);
        if (requested.Length == 0) return null;
        var exact = candidates
            .Where(candidate => Normalize(candidate.Title) == requested
                || (candidate.OriginalTitle is { } original && Normalize(original) == requested))
            .ToList();
        if (exact.Count == 0) return null;
        if (requestedYear is { } year)
        {
            var near = exact.Where(candidate => candidate.Year is { } candidateYear && Math.Abs(candidateYear - year) <= 1).ToList();
            return near.Count == 1 ? near[0] : null;
        }

        if (exact.Count == 1) return exact[0];
        var fitting = exact;
        if (local is { } here && shapes is not null)
        {
            var fits = exact.Where(candidate => shapes.TryGetValue(candidate.ProviderMediaId, out var shape)
                && shape.Seasons is { } seasons && seasons >= (here.HighestSeason ?? 1)
                && (shape.Episodes is not { } episodes || episodes >= here.EpisodeCount)).ToList();
            if (fits.Count == 1) return fits[0];
            if (fits.Count > 1) fitting = fits;
        }

        var byVotes = fitting.OrderByDescending(candidate => candidate.VoteCount ?? 0).ToList();
        var best = byVotes[0].VoteCount ?? 0;
        var runnerUp = byVotes[1].VoteCount ?? 0;
        return best >= 20 && best >= 5 * Math.Max(1, runnerUp) ? byVotes[0] : null;
    }

    /// <summary>
    /// Shorter searches for a title TMDB does not find as a whole: the part before a dash or colon
    /// ("Main Title - Long German Subtitle"), when it still has two words or more.
    /// </summary>
    public static IReadOnlyList<string> FallbackQueries(string title)
    {
        var queries = new List<string>();
        foreach (var separator in new[] { " - ", " – ", " — ", ": " })
        {
            var index = title.IndexOf(separator, StringComparison.Ordinal);
            if (index <= 0) continue;
            var head = title[..index].Trim();
            if (head.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length >= 2 && !queries.Contains(head, StringComparer.OrdinalIgnoreCase))
            {
                queries.Add(head);
            }
        }

        return queries;
    }

    public static bool IsUnambiguous(
        IReadOnlyList<MetadataCandidateSummary> candidates,
        string requestedTitle,
        int? requestedYear) =>
        SelectAutomaticMatch(candidates, requestedTitle, requestedYear) is not null;

    public static string ReviewReason(
        string requestedTitle,
        int? requestedYear,
        IReadOnlyList<MetadataCandidateSummary> candidates)
    {
        if (candidates.Count == 0)
        {
            return "TMDB returned no results for the detected title.";
        }

        var best = candidates.OrderByDescending(candidate => candidate.Confidence).First();
        if (requestedYear.HasValue && best.Year.HasValue && requestedYear != best.Year)
        {
            return $"A possible title match was found, but TMDB lists it as {best.Year.Value} instead of {requestedYear.Value}.";
        }

        if (candidates.Count == 1)
        {
            var titleLooksClose = new[] { best.Title, best.OriginalTitle ?? string.Empty }
                .Any(candidate => Normalize(candidate) == Normalize(requestedTitle)
                    || IsSinglePluralVariant(requestedTitle, candidate));
            return titleLooksClose
                ? "One possible TMDB match was found, but it did not meet the safe automatic-selection rules."
                : "TMDB returned one result, but it is not a close title match.";
        }

        var runnerUp = candidates
            .OrderByDescending(candidate => candidate.Confidence)
            .Skip(1)
            .First();
        return best.Confidence - runnerUp.Confidence < 0.08
            ? "Several similar TMDB matches need confirmation."
            : "The best TMDB match is below the safe automatic-selection threshold.";
    }

    private static bool IsSinglePluralVariant(string requested, string candidate)
    {
        var requestedWords = Words(requested);
        var candidateWords = Words(candidate);
        if (requestedWords.Length == 0 || requestedWords.Length != candidateWords.Length)
        {
            return false;
        }

        var differingWords = 0;
        for (var index = 0; index < requestedWords.Length; index++)
        {
            var left = requestedWords[index];
            var right = candidateWords[index];
            if (left == right)
            {
                continue;
            }

            var pluralizesLeft = right.Length > 4
                && right.EndsWith('s')
                && right[..^1] == left;
            var pluralizesRight = left.Length > 4
                && left.EndsWith('s')
                && left[..^1] == right;
            if (!pluralizesLeft && !pluralizesRight)
            {
                return false;
            }

            differingWords++;
        }

        return differingWords == 1;
    }

    private static string[] Words(string value)
    {
        var words = new List<string>();
        var current = new StringBuilder();
        foreach (var character in value.Normalize(NormalizationForm.FormKD))
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) == UnicodeCategory.NonSpacingMark)
            {
                continue;
            }

            if (char.IsLetterOrDigit(character))
            {
                current.Append(char.ToLowerInvariant(character));
                continue;
            }

            if (current.Length > 0)
            {
                words.Add(current.ToString());
                current.Clear();
            }
        }

        if (current.Length > 0)
        {
            words.Add(current.ToString());
        }

        return words
            .Where((word, index) => word != "and" || index == 0 || index == words.Count - 1)
            .ToArray();
    }

    private static string Normalize(string value) => string.Concat(Words(value));

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
