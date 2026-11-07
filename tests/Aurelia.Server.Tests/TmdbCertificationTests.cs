using System.Net;
using System.Text;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>The apps show the German FSK rating; TMDB's US rating is only the fallback.</summary>
public sealed class TmdbCertificationTests
{
    private const string Credits = "\"credits\":{\"cast\":[],\"crew\":[]}";

    [Theory]
    [InlineData("""[{"iso_3166_1":"US","release_dates":[{"certification":"R"}]},{"iso_3166_1":"DE","release_dates":[{"certification":""},{"certification":"16"}]}]""", "FSK 16")]
    [InlineData("""[{"iso_3166_1":"DE","release_dates":[{"certification":"FSK 12"}]}]""", "FSK 12")]
    [InlineData("""[{"iso_3166_1":"DE","release_dates":[{"certification":"unknown"}]},{"iso_3166_1":"US","release_dates":[{"certification":"PG-13"}]}]""", "PG-13")]
    [InlineData("""[{"iso_3166_1":"GB","release_dates":[{"certification":"15"}]}]""", null)]
    public async Task MoviesPreferTheGermanRating(string countries, string? expected)
    {
        var metadata = await Details("movie", $$$"""{"id":1,"title":"Synthetic Movie",{{{Credits}}},"release_dates":{"results":{{{countries}}}}}""");
        Assert.Equal(expected, metadata.ContentRating);
        Assert.Equal(expected is { } value && value.StartsWith("FSK", StringComparison.Ordinal) ? int.Parse(value[4..], System.Globalization.CultureInfo.InvariantCulture) : null,
            MetadataPresentation.ParseFsk(metadata.ContentRating));
    }

    [Theory]
    [InlineData("""[{"iso_3166_1":"US","rating":"TV-MA"},{"iso_3166_1":"DE","rating":"18"}]""", "FSK 18")]
    [InlineData("""[{"iso_3166_1":"US","rating":"TV-14"}]""", "TV-14")]
    public async Task ShowsPreferTheGermanRating(string countries, string expected)
    {
        var metadata = await Details("tv", $$$"""{"id":2,"name":"Synthetic Show",{{{Credits}}},"content_ratings":{"results":{{{countries}}}}}""");
        Assert.Equal(expected, metadata.ContentRating);
    }

    private static async Task<TmdbMetadata> Details(string mediaType, string json)
    {
        using var handler = new JsonHandler(json);
        using var client = new HttpClient(handler);
        return await new TmdbClient(client).GetAsync("synthetic-secret", "en-US", mediaType, "7", default);
    }

    private sealed class JsonHandler(string json) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") });
    }
}
