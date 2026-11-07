using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

/// <summary>What a subtitle search knows about a title; the hash is the OpenSubtitles file hash.</summary>
public sealed record SubtitleSearch(
    MediaKind Kind,
    string Title,
    int? Year,
    string? TmdbId,
    int? SeasonNumber,
    int? EpisodeNumber,
    string? FileHash,
    IReadOnlyList<string> Languages);

public sealed record SubtitleFile(byte[] Content, int? Remaining, DateTimeOffset? ResetsAt);

/// <summary>A download the provider refused because today's downloads are used up.</summary>
public sealed class SubtitleQuotaException(DateTimeOffset? resetsAt)
    : MetadataException("subtitle_quota_reached", "Today's OpenSubtitles downloads are used up. Add an OpenSubtitles account in Settings for more, or try again later.", StatusCodes.Status429TooManyRequests)
{
    public DateTimeOffset? ResetsAt { get; } = resetsAt;
}

public interface IOpenSubtitlesClient
{
    Task<IReadOnlyList<SubtitleCandidate>> SearchAsync(string apiKey, SubtitleSearch search, CancellationToken cancellationToken);
    Task<SubtitleFile> DownloadAsync(string apiKey, string? accountName, string? accountPassword, string fileId, CancellationToken cancellationToken);
}

/// <summary>
/// The OpenSubtitles.com REST API (v1). Searches by file hash and TMDB id first, then by title;
/// downloads ask for SubRip. An account token is fetched once and kept in memory only.
/// </summary>
public sealed class OpenSubtitlesClient(HttpClient client) : IOpenSubtitlesClient
{
    public const long MaximumBytes = SidecarSubtitles.MaximumFileBytes;
    private static readonly Uri BaseAddress = new("https://api.opensubtitles.com/api/v1/");
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    // Typed HTTP clients are short-lived, so the sign-in is shared and kept in memory only.
    private static readonly SemaphoreSlim LoginGate = new(1, 1);
    private static (string Account, string Token, DateTimeOffset Expires)? login;

    public async Task<IReadOnlyList<SubtitleCandidate>> SearchAsync(string apiKey, SubtitleSearch search, CancellationToken cancellationToken)
    {
        using var response = await SendAsync(HttpMethod.Get, "subtitles?" + Query(search), apiKey, null, null, cancellationToken);
        await EnsureSuccessAsync(response, cancellationToken);
        using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
        return Candidates(document.RootElement);
    }

    public async Task<SubtitleFile> DownloadAsync(string apiKey, string? accountName, string? accountPassword, string fileId, CancellationToken cancellationToken)
    {
        if (!long.TryParse(fileId, NumberStyles.None, CultureInfo.InvariantCulture, out var id))
            throw new MetadataException("invalid_subtitle", "The subtitle was not found.", StatusCodes.Status404NotFound);
        var token = accountName is { Length: > 0 } && accountPassword is { Length: > 0 }
            ? await LoginAsync(apiKey, accountName, accountPassword, cancellationToken)
            : null;
        using var response = await SendAsync(HttpMethod.Post, "download", apiKey, token,
            JsonContent.Create(new { file_id = id, sub_format = "srt" }), cancellationToken);
        if (response.StatusCode is HttpStatusCode.NotAcceptable or HttpStatusCode.TooManyRequests)
            throw new SubtitleQuotaException(await ResetTimeAsync(response, cancellationToken));
        await EnsureSuccessAsync(response, cancellationToken);
        using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
        var root = document.RootElement;
        if (!root.TryGetProperty("link", out var linkValue) || !Uri.TryCreate(linkValue.GetString(), UriKind.Absolute, out var link)
            || link.Scheme != Uri.UriSchemeHttps)
            throw new MetadataProviderException("OpenSubtitles did not return a download.", transient: true);
        int? remaining = root.TryGetProperty("remaining", out var left) && left.ValueKind == JsonValueKind.Number ? left.GetInt32() : null;
        var resets = root.TryGetProperty("reset_time_utc", out var reset) && reset.ValueKind == JsonValueKind.String
            && DateTimeOffset.TryParse(reset.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at) ? at : (DateTimeOffset?)null;

        using var file = await client.GetAsync(link, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!file.IsSuccessStatusCode)
            throw new MetadataProviderException("The subtitle file could not be downloaded.", transient: true);
        if (file.Content.Headers.ContentLength > MaximumBytes)
            throw new MetadataException("subtitle_too_large", "The subtitle file is too large.", StatusCodes.Status422UnprocessableEntity);
        await using var stream = await file.Content.ReadAsStreamAsync(cancellationToken);
        using var buffer = new MemoryStream();
        var chunk = new byte[16384];
        int read;
        while ((read = await stream.ReadAsync(chunk, cancellationToken)) > 0)
        {
            buffer.Write(chunk, 0, read);
            if (buffer.Length > MaximumBytes)
                throw new MetadataException("subtitle_too_large", "The subtitle file is too large.", StatusCodes.Status422UnprocessableEntity);
        }
        return new SubtitleFile(buffer.ToArray(), remaining, resets);
    }

    /// <summary>Parameters sorted by name with lowercase values, as the API asks, so it never redirects.</summary>
    public static string Query(SubtitleSearch search)
    {
        var values = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["languages"] = string.Join(',', search.Languages.Select(language => language.ToLowerInvariant()).Order(StringComparer.Ordinal)),
        };
        if (search.FileHash is { Length: 16 } hash) values["moviehash"] = hash.ToLowerInvariant();
        var hasTmdb = int.TryParse(search.TmdbId, NumberStyles.None, CultureInfo.InvariantCulture, out var tmdb);
        if (search.Kind == MediaKind.Episode)
        {
            values["type"] = "episode";
            if (search.SeasonNumber is { } season) values["season_number"] = season.ToString(CultureInfo.InvariantCulture);
            if (search.EpisodeNumber is { } episode) values["episode_number"] = episode.ToString(CultureInfo.InvariantCulture);
            if (hasTmdb) values["parent_tmdb_id"] = tmdb.ToString(CultureInfo.InvariantCulture);
        }
        else
        {
            values["type"] = "movie";
            if (hasTmdb) values["tmdb_id"] = tmdb.ToString(CultureInfo.InvariantCulture);
            if (search.Year is { } year) values["year"] = year.ToString(CultureInfo.InvariantCulture);
        }
        if (!hasTmdb) values["query"] = search.Title.Trim().ToLowerInvariant();
        return string.Join('&', values.Select(pair => pair.Key + "=" + Uri.EscapeDataString(pair.Value)));
    }

    public static IReadOnlyList<SubtitleCandidate> Candidates(JsonElement root)
    {
        var result = new List<SubtitleCandidate>();
        if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array) return result;
        foreach (var entry in data.EnumerateArray())
        {
            if (!entry.TryGetProperty("attributes", out var attributes) || attributes.ValueKind != JsonValueKind.Object) continue;
            if (!attributes.TryGetProperty("files", out var files) || files.ValueKind != JsonValueKind.Array) continue;
            var file = files.EnumerateArray().FirstOrDefault();
            if (file.ValueKind != JsonValueKind.Object || !file.TryGetProperty("file_id", out var fileId) || fileId.ValueKind != JsonValueKind.Number) continue;
            var language = String(attributes, "language");
            if (language is null) continue;
            result.Add(new SubtitleCandidate(
                fileId.GetInt64().ToString(CultureInfo.InvariantCulture),
                language.Split('-')[0].ToLowerInvariant(),
                String(attributes, "release"),
                Bool(attributes, "moviehash_match"),
                Bool(attributes, "hearing_impaired"),
                Bool(attributes, "foreign_parts_only"),
                Bool(attributes, "machine_translated") || Bool(attributes, "ai_translated"),
                attributes.TryGetProperty("download_count", out var count) && count.ValueKind == JsonValueKind.Number ? count.GetInt32() : 0,
                Bool(attributes, "from_trusted")));
        }
        return Rank(result);
    }

    /// <summary>Exact file matches first, then human translations from trusted uploaders, then the most downloaded.</summary>
    public static IReadOnlyList<SubtitleCandidate> Rank(IEnumerable<SubtitleCandidate> candidates) =>
        candidates
            .OrderByDescending(candidate => candidate.HashMatch)
            .ThenBy(candidate => candidate.MachineTranslated)
            .ThenBy(candidate => candidate.ForeignPartsOnly)
            .ThenByDescending(candidate => candidate.FromTrusted)
            .ThenByDescending(candidate => candidate.DownloadCount)
            .ToList();

    private async Task<string> LoginAsync(string apiKey, string accountName, string accountPassword, CancellationToken cancellationToken)
    {
        await LoginGate.WaitAsync(cancellationToken);
        try
        {
            var account = accountName + "\n" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(apiKey + "\n" + accountPassword)));
            if (login is { } current && current.Account == account && current.Expires > DateTimeOffset.UtcNow) return current.Token;
            using var response = await SendAsync(HttpMethod.Post, "login", apiKey, null,
                JsonContent.Create(new { username = accountName, password = accountPassword }), cancellationToken);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden or HttpStatusCode.BadRequest)
                throw new MetadataException("subtitle_account_rejected", "OpenSubtitles did not accept the user name and password.", StatusCodes.Status400BadRequest);
            await EnsureSuccessAsync(response, cancellationToken);
            var body = await response.Content.ReadFromJsonAsync<LoginResponse>(JsonOptions, cancellationToken);
            if (body?.Token is not { Length: > 0 } token)
                throw new MetadataProviderException("OpenSubtitles did not sign in.", transient: true);
            login = (account, token, DateTimeOffset.UtcNow.AddHours(12));
            return token;
        }
        finally { LoginGate.Release(); }
    }

    private async Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, string apiKey, string? token, HttpContent? content, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, new Uri(BaseAddress, path)) { Content = content };
        request.Headers.Add("Api-Key", apiKey);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        try
        {
            return await client.SendAsync(request, cancellationToken);
        }
        catch (HttpRequestException)
        {
            throw new MetadataProviderException("OpenSubtitles could not be reached.", transient: true);
        }
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (response.IsSuccessStatusCode) return;
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new MetadataProviderException("OpenSubtitles did not accept the API key.", transient: false, authenticationFailure: true);
        if (response.StatusCode == HttpStatusCode.TooManyRequests)
            throw new MetadataProviderException("OpenSubtitles is busy. Try again in a moment.", transient: true, retryAfter: response.Headers.RetryAfter?.Delta);
        _ = cancellationToken;
        throw new MetadataProviderException("OpenSubtitles could not answer right now.", transient: (int)response.StatusCode >= 500);
    }

    private static async Task<DateTimeOffset?> ResetTimeAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        try
        {
            using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
            return document.RootElement.TryGetProperty("reset_time_utc", out var reset) && reset.ValueKind == JsonValueKind.String
                && DateTimeOffset.TryParse(reset.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at) ? at : null;
        }
        catch (JsonException) { return null; }
    }

    private static string? String(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text ? text : null;

    private static bool Bool(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    private sealed record LoginResponse(string? Token);
}

/// <summary>
/// The OpenSubtitles file hash: the file size plus the 64-bit little-endian sums of the first and
/// last 64 KiB. It only reads those two blocks of the media file.
/// </summary>
public static class OpenSubtitlesHash
{
    private const int Block = 65536;

    public static string? Compute(Stream stream)
    {
        if (!stream.CanSeek || stream.Length < Block * 2) return null;
        var hash = unchecked((ulong)stream.Length);
        var buffer = new byte[Block];
        foreach (var offset in new[] { 0L, stream.Length - Block })
        {
            stream.Position = offset;
            stream.ReadExactly(buffer);
            for (var index = 0; index < Block; index += 8)
                hash = unchecked(hash + System.Buffers.Binary.BinaryPrimitives.ReadUInt64LittleEndian(buffer.AsSpan(index, 8)));
        }
        return hash.ToString("x16", CultureInfo.InvariantCulture);
    }
}
