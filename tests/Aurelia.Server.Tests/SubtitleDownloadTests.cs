using System.Net;
using System.Text;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// Subtitle downloads with an invented provider: settings, search, download into the data folder,
/// playback as a sidecar track, removal, and the automatic pass. The media file is never changed.
/// </summary>
public sealed class SubtitleDownloadTests
{
    private const string Srt = "1\r\n00:00:01,000 --> 00:00:03,500\r\nInvented line\r\n";

    [Fact]
    public void TheFileHashIsTheSizePlusBothEndBlocks()
    {
        var bytes = new byte[200_000];
        using (var empty = new MemoryStream(bytes)) Assert.Equal("0000000000030d40", OpenSubtitlesHash.Compute(empty));
        bytes[0] = 1;
        bytes[^8] = 2;
        using (var marked = new MemoryStream(bytes)) Assert.Equal("0000000000030d43", OpenSubtitlesHash.Compute(marked));
        using var small = new MemoryStream(new byte[1000]);
        Assert.Null(OpenSubtitlesHash.Compute(small));
    }

    [Fact]
    public void SearchesAreSortedAndPreferExactHumanSubtitles()
    {
        Assert.Equal("languages=de%2Cen&moviehash=00000000000abcde&tmdb_id=603&type=movie&year=1999",
            OpenSubtitlesClient.Query(new SubtitleSearch(MediaKind.Movie, "Invented", 1999, "603", null, null, "00000000000ABCDE", ["en", "de"])));
        Assert.Equal("episode_number=4&languages=de&parent_tmdb_id=77&season_number=2&type=episode",
            OpenSubtitlesClient.Query(new SubtitleSearch(MediaKind.Episode, "Invented Show", null, "77", 2, 4, null, ["de"])));
        Assert.Equal("languages=en&query=invented%20title&type=movie",
            OpenSubtitlesClient.Query(new SubtitleSearch(MediaKind.Movie, " Invented Title ", null, null, null, null, null, ["en"])));

        using var document = JsonDocument.Parse("""
        {"data":[
          {"attributes":{"language":"de","download_count":900,"machine_translated":true,"files":[{"file_id":1}]}},
          {"attributes":{"language":"de","download_count":10,"files":[{"file_id":2}],"release":"Invented.1080p"}},
          {"attributes":{"language":"pt-BR","download_count":5,"moviehash_match":true,"files":[{"file_id":3}]}},
          {"attributes":{"language":"de","files":[]}},
          {"attributes":{"files":[{"file_id":4}]}}
        ]}
        """);
        var candidates = OpenSubtitlesClient.Candidates(document.RootElement);
        Assert.Equal(["3", "2", "1"], candidates.Select(candidate => candidate.FileId));
        Assert.Equal("pt", candidates[0].Language);
        Assert.True(candidates[0].HashMatch);
        Assert.Equal("Invented.1080p", candidates[1].Release);
        Assert.True(candidates[2].MachineTranslated);
    }

    [Fact]
    public void LanguagesAreNormalizedAndBounded()
    {
        Assert.Equal(["de", "en"], SubtitleProviderSettingsStore.NormalizeLanguages(["DE", "en-US", "ger"]));
        Assert.Throws<MetadataException>(() => SubtitleProviderSettingsStore.NormalizeLanguages([]));
        Assert.Throws<MetadataException>(() => SubtitleProviderSettingsStore.NormalizeLanguages(["klingonisch"]));
        Assert.Throws<MetadataException>(() => SubtitleProviderSettingsStore.NormalizeLanguages(["de", "en", "fr", "es", "it", "nl"]));
    }

    [Fact]
    public async Task DownloadedSubtitlesPlayFromTheDataFolderAndCanBeRemoved()
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Invented Subtitle Downloads");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "Invented Film (2001).mkv");
        await File.WriteAllBytesAsync(path, Enumerable.Range(0, 300_000).Select(index => (byte)(index % 251)).ToArray());
        var before = (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length, Directory.GetFileSystemEntries(root).Length);
        var provider = new Provider();
        try
        {
            using var factory = Factory(provider);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMovieAsync(factory, root, path, "603");

            // Not set up yet: downloads say how to turn them on.
            using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{mediaId}/subtitles/search", owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, request))
                Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
            using (var request = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/metadata/subtitles", owner.Token,
                       new UpdateSubtitleProviderRequest(true, ["de"], false)))
            using (var response = await ApiTestClient.SendAsync(client, request))
                Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);

            SubtitleProviderStatus status;
            using (var request = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/metadata/subtitles", owner.Token,
                       new UpdateSubtitleProviderRequest(true, ["de", "en"], false, "InventedApiKey0123456789", "invented-user", "invented-password")))
            using (var response = await ApiTestClient.SendAsync(client, request))
            {
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
                status = await ApiTestClient.ReadAsync<SubtitleProviderStatus>(response);
                var body = await response.Content.ReadAsStringAsync();
                Assert.DoesNotContain("InventedApiKey", body, StringComparison.Ordinal);
                Assert.DoesNotContain("invented-password", body, StringComparison.Ordinal);
            }
            Assert.True(status is { Enabled: true, HasApiKey: true, HasAccount: true, AccountName: "invented-user" });
            Assert.Equal(["de", "en"], status.Languages);

            List<SubtitleCandidate> found;
            using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{mediaId}/subtitles/search?language=de", owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, request))
            {
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
                found = await ApiTestClient.ReadAsync<List<SubtitleCandidate>>(response);
            }
            var search = Assert.Single(provider.Searches);
            Assert.Equal("603", search.TmdbId);
            Assert.Equal(["de"], search.Languages);
            Assert.Equal(16, search.FileHash?.Length);
            Assert.Equal("101", found[0].FileId);

            DownloadedSubtitle downloaded;
            using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{mediaId}/subtitles", owner.Token,
                       new DownloadSubtitleRequest("101", "de", "Invented.Release", HearingImpaired: true)))
            using (var response = await ApiTestClient.SendAsync(client, request))
            {
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
                downloaded = await ApiTestClient.ReadAsync<DownloadedSubtitle>(response);
            }
            Assert.Equal("German (SDH) · Downloaded", downloaded.Title);
            Assert.Equal(("invented-user", "invented-password"), provider.Account);
            Assert.True(File.Exists(Path.Combine(factory.DataDirectory, "Subtitles", mediaId.ToString("N"), downloaded.Id.ToString("N") + ".srt")));
            Assert.Equal(before, (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length, Directory.GetFileSystemEntries(root).Length));

            var playback = await CreatePlaybackAsync(client, owner.Token, mediaId);
            List<LiveSubtitleTrack> tracks;
            using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"{playback.StreamPath}/subtitles", owner.Token))
            using (var response = await client.SendAsync(request))
            {
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
                tracks = await ApiTestClient.ReadAsync<List<LiveSubtitleTrack>>(response);
            }
            var track = Assert.Single(tracks);
            Assert.Equal(SubtitleDownloadService.DownloadedTrackBase, track.Index);
            Assert.True(track is { IsSidecar: true, Supported: true, IsSdh: true, Language: "de" });
            using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"{playback.StreamPath}/subtitles/{track.Index}", owner.Token))
            using (var response = await client.SendAsync(request))
            {
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
                var vtt = await response.Content.ReadAsStringAsync();
                Assert.StartsWith("WEBVTT", vtt, StringComparison.Ordinal);
                Assert.Contains("00:00:01.000 --> 00:00:03.500", vtt, StringComparison.Ordinal);
            }

            using (var request = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/media/{mediaId}/subtitles/{downloaded.Id}", owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, request))
                Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
            using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{mediaId}/subtitles", owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, request))
                Assert.Empty(await ApiTestClient.ReadAsync<List<DownloadedSubtitle>>(response));
            Assert.False(Directory.Exists(Path.Combine(factory.DataDirectory, "Subtitles", mediaId.ToString("N"))));

            // A used-up quota is reported plainly.
            provider.QuotaReached = true;
            using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{mediaId}/subtitles", owner.Token,
                       new DownloadSubtitleRequest("102", "en")))
            using (var response = await ApiTestClient.SendAsync(client, request))
                Assert.Equal(HttpStatusCode.TooManyRequests, response.StatusCode);
            Assert.Equal(before, (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length, Directory.GetFileSystemEntries(root).Length));
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(root)!, recursive: true);
        }
    }

    [Fact]
    public async Task ProfilesThatCannotManageTheServerCannotDownloadSubtitles()
    {
        var provider = new Provider();
        using var factory = Factory(provider);
        using var client = factory.CreateClient();
        await ApiTestClient.SetupOwnerAsync(client);
        using var anonymous = await client.GetAsync($"/api/v1/media/{Guid.NewGuid()}/subtitles");
        Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
    }

    [Fact]
    public async Task TheAutomaticPassFillsOnlyMissingLanguagesOnceAWeek()
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Invented Automatic Subtitles");
        Directory.CreateDirectory(root);
        var withGerman = Path.Combine(root, "Invented One.mkv");
        var without = Path.Combine(root, "Invented Two.mkv");
        await File.WriteAllBytesAsync(withGerman, new byte[150_000]);
        await File.WriteAllBytesAsync(without, new byte[160_000]);
        await File.WriteAllTextAsync(Path.Combine(root, "Invented One.de.srt"), Srt);
        var provider = new Provider();
        try
        {
            using var factory = Factory(provider);
            using var client = factory.CreateClient();
            await ApiTestClient.SetupOwnerAsync(client);
            var first = await AddMovieAsync(factory, root, withGerman, "1");
            var second = await AddMovieAsync(factory, root, without, "2");
            var unmatched = await AddMovieAsync(factory, root, without + ".unused", null, register: true);
            factory.Services.GetRequiredService<SubtitleProviderSettingsStore>().Save(
                new UpdateSubtitleProviderRequest(true, ["de"], true, "InventedApiKey0123456789"));

            async Task<int> RunAsync()
            {
                await using var scope = factory.Services.CreateAsyncScope();
                return await scope.ServiceProvider.GetRequiredService<SubtitleDownloadService>().AutomaticRunAsync(25, default);
            }

            Assert.Equal(1, await RunAsync());
            var search = Assert.Single(provider.Searches);
            Assert.Equal("2", search.TmdbId);
            var store = factory.Services.GetRequiredService<DownloadedSubtitleStore>();
            Assert.Empty(store.List(first));
            var downloaded = Assert.Single(store.List(second));
            Assert.True(downloaded.Automatic);
            Assert.Empty(store.List(unmatched));

            // Nothing is asked again within a week.
            Assert.Equal(0, await RunAsync());
            Assert.Single(provider.Searches);
            Assert.Null(provider.Account);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(root)!, recursive: true);
        }
    }

    private static AureliaServerFactory Factory(Provider provider) => new(configureServices: services =>
    {
        services.RemoveAll<IOpenSubtitlesClient>();
        services.AddSingleton<IOpenSubtitlesClient>(provider);
    });

    private static async Task<Guid> AddMovieAsync(AureliaServerFactory factory, string root, string path, string? tmdbId, bool register = false)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var normalized = MediaPath.Normalize(root);
        var library = await database.LibraryRoots.FirstOrDefaultAsync(candidate => candidate.NormalizedPath == normalized);
        if (library is null)
        {
            library = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Invented",
                Path = root,
                NormalizedPath = normalized,
                Kind = LibraryKind.Movies,
                Availability = LibraryAvailability.Available,
                CreatedAt = DateTimeOffset.UtcNow,
                MonitoringEnabled = false,
            };
            database.LibraryRoots.Add(library);
        }
        var exists = File.Exists(path);
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = Path.GetFileNameWithoutExtension(path),
            Category = string.Empty,
            Extension = ".mkv",
            FileSize = exists ? new FileInfo(path).Length : 1,
            FileModifiedAt = exists ? new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero) : DateTimeOffset.UtcNow,
            Availability = MediaAvailability.Available,
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
            Metadata = tmdbId is null ? null : new MediaMetadata
            {
                Provider = "tmdb",
                ProviderMediaId = tmdbId,
                ProviderMediaType = "movie",
                ProviderTitle = "Invented " + tmdbId,
                ReviewState = MetadataReviewState.Matched,
            },
        };
        _ = register;
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        return media.Id;
    }

    private static async Task<PlaybackSourceResponse> CreatePlaybackAsync(HttpClient client, string token, Guid mediaId)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{mediaId}/playback", token);
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        return await ApiTestClient.ReadAsync<PlaybackSourceResponse>(response);
    }

    private sealed class Provider : IOpenSubtitlesClient
    {
        public System.Collections.Concurrent.ConcurrentQueue<SubtitleSearch> Searches { get; } = [];
        public (string?, string?)? Account { get; private set; }
        public bool QuotaReached { get; set; }

        public Task<IReadOnlyList<SubtitleCandidate>> SearchAsync(string apiKey, SubtitleSearch search, CancellationToken cancellationToken)
        {
            Assert.Equal("InventedApiKey0123456789", apiKey);
            Searches.Enqueue(search);
            return Task.FromResult<IReadOnlyList<SubtitleCandidate>>(
            [
                new SubtitleCandidate("101", search.Languages[0], "Invented.Release", true, false, false, false, 10, true),
                new SubtitleCandidate("102", search.Languages[0], null, false, false, false, true, 99, false),
            ]);
        }

        public Task<SubtitleFile> DownloadAsync(string apiKey, string? accountName, string? accountPassword, string fileId, CancellationToken cancellationToken)
        {
            if (QuotaReached) throw new SubtitleQuotaException(DateTimeOffset.UtcNow.AddHours(3));
            if (accountName is not null) Account = (accountName, accountPassword);
            return Task.FromResult(new SubtitleFile(Encoding.UTF8.GetBytes(Srt), 4, null));
        }
    }
}
