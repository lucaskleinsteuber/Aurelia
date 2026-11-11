using System.Net;
using System.Security.Cryptography;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using SkiaSharp;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ArtworkVariantTests
{
    [Theory]
    [InlineData(false, 160, 80, 160, 80, "image/jpeg")]
    [InlineData(true, 640, 480, 320, 240, "image/png")]
    public async Task VariantsPreserveGeometryAndAlphaWithoutChangingOriginal(bool alpha, int width, int height,
        int expectedWidth, int expectedHeight, string contentType)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var asset = await SeedAsync(factory, width, height, alpha);
        var source = Path.Combine(factory.DataDirectory, "Artwork", asset.RelativeFilePath);
        var before = SHA256.HashData(await File.ReadAllBytesAsync(source));
        var requests = Enumerable.Range(0, 5).Select(async _ =>
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width=320", owner.Token);
            using var response = await client.SendAsync(request);
            response.EnsureSuccessStatusCode();
            Assert.Equal(contentType, response.Content.Headers.ContentType?.MediaType);
            using var decoded = SKBitmap.Decode(await response.Content.ReadAsByteArrayAsync());
            Assert.Equal(expectedWidth, decoded.Width);
            Assert.Equal(expectedHeight, decoded.Height);
            if (alpha) Assert.True(decoded.GetPixel(0, 0).Alpha < 255);
        });
        await Task.WhenAll(requests);
        Assert.Equal(before, SHA256.HashData(await File.ReadAllBytesAsync(source)));
        Assert.Single(Directory.GetFiles(Path.Combine(factory.DataDirectory, "ArtworkVariants")));
        using var badWidth = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width=321", owner.Token);
        using var badResponse = await client.SendAsync(badWidth);
        Assert.Equal(HttpStatusCode.BadRequest, badResponse.StatusCode);
        using var anonymous = await client.GetAsync($"/api/v1/artwork/{asset.Id}?width=320");
        Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
    }

    [Fact]
    public async Task AnAddressWithTheCurrentRevisionMayBeKeptForGood()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var asset = await SeedAsync(factory, 640, 320, false);
        foreach (var (query, kept) in new[]
        {
            ($"?width=320&rev={asset.Revision}", true),
            ($"?rev={asset.Revision}", true),
            ($"?width=320&rev={asset.Revision + 1}", false),
            ("?width=320", false),
        })
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}{query}", owner.Token);
            using var response = await client.SendAsync(request);
            response.EnsureSuccessStatusCode();
            var cache = response.Headers.CacheControl!;
            Assert.True(cache.Private, query);
            Assert.True(kept == (cache.MaxAge == TimeSpan.FromDays(365)), query);
            Assert.True(kept != cache.NoCache, query);
        }
    }

    [Fact]
    public async Task CachedVariantsAndUnchangedRepliesDoNotOpenTheOriginal()
    {
        if (OperatingSystem.IsWindows()) return;
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var asset = await SeedAsync(factory, 640, 320, false);
        using var firstRequest = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width=320", owner.Token);
        using var first = await client.SendAsync(firstRequest);
        first.EnsureSuccessStatusCode();
        var bytes = await first.Content.ReadAsByteArrayAsync();
        var etag = Assert.IsType<System.Net.Http.Headers.EntityTagHeaderValue>(first.Headers.ETag);
        var source = Path.Combine(factory.DataDirectory, "Artwork", asset.RelativeFilePath);
        // An unreadable original proves that cached and unchanged replies never open it.
        File.SetUnixFileMode(source, UnixFileMode.None);
        try
        {
            using var cachedRequest = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width=320", owner.Token);
            using var cached = await client.SendAsync(cachedRequest);
            cached.EnsureSuccessStatusCode();
            Assert.Equal(bytes, await cached.Content.ReadAsByteArrayAsync());
            Assert.Equal(etag, cached.Headers.ETag);

            using var conditionalRequest = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width=320", owner.Token);
            conditionalRequest.Headers.IfNoneMatch.Add(etag);
            using var conditional = await client.SendAsync(conditionalRequest);
            Assert.Equal(HttpStatusCode.NotModified, conditional.StatusCode);
            Assert.Equal(etag, conditional.Headers.ETag);
            Assert.Empty(await conditional.Content.ReadAsByteArrayAsync());

            using var originalRequest = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}", owner.Token);
            using var original = await client.SendAsync(originalRequest);
            Assert.Equal(HttpStatusCode.NotFound, original.StatusCode);
        }
        finally
        {
            File.SetUnixFileMode(source, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }

    [Fact]
    public async Task RevisionInvalidatesETagAndCachedVariantForSameArtworkID()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var asset = await SeedAsync(factory, 640, 320, false);
        using var firstRequest = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width=320", owner.Token);
        using var first = await client.SendAsync(firstRequest);
        first.EnsureSuccessStatusCode();
        var etag = first.Headers.ETag;
        var oldBytes = await first.Content.ReadAsByteArrayAsync();
        using (var unchangedRequest = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width=320", owner.Token))
        {
            unchangedRequest.Headers.IfNoneMatch.Add(etag!);
            using var unchanged = await client.SendAsync(unchangedRequest);
            Assert.Equal(HttpStatusCode.NotModified, unchanged.StatusCode);
        }
        await using (var scope = factory.Services.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var updated = await database.ArtworkAssets.SingleAsync(value => value.Id == asset.Id);
            var bytes = Image(640, 320, false, SKColors.Blue);
            updated.RelativeFilePath = $"{asset.Id:N}-r2.png";
            updated.ContentLength = bytes.Length;
            updated.Revision = 2;
            await File.WriteAllBytesAsync(Path.Combine(factory.DataDirectory, "Artwork", updated.RelativeFilePath), bytes);
            await database.SaveChangesAsync();
        }
        using var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width=320", owner.Token);
        request.Headers.IfNoneMatch.Add(etag!);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        Assert.NotEqual(etag, response.Headers.ETag);
        Assert.NotEqual(oldBytes, await response.Content.ReadAsByteArrayAsync());
    }

    [Fact]
    public async Task LargeJpegUsesScaledDecodeAndKeepsExactGeometry()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var asset = await SeedAsync(factory, 2000, 1000, false, jpeg: true);
        foreach (var (width, height) in new[] { (640, 320), (1280, 640), (1920, 960), (320, 160) })
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width={width}", owner.Token);
            using var response = await client.SendAsync(request);
            response.EnsureSuccessStatusCode();
            Assert.Equal("image/jpeg", response.Content.Headers.ContentType?.MediaType);
            using var decoded = SKBitmap.Decode(await response.Content.ReadAsByteArrayAsync());
            Assert.Equal(width, decoded.Width);
            Assert.Equal(height, decoded.Height);
            // The synthetic source is solid red; scaled decoding must not shift colors.
            var pixel = decoded.GetPixel(width / 2, height / 2);
            Assert.True(pixel.Red > 200 && pixel.Green < 60 && pixel.Blue < 60);
        }
    }

    [Fact]
    public async Task DifferentVariantsGenerateConcurrentlyWithOneFileEach()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var assets = new List<ArtworkAsset>();
        for (var index = 0; index < 12; index++) assets.Add(await SeedAsync(factory, 800, 400, index % 3 == 0, jpeg: index % 3 != 0));
        await Task.WhenAll(assets.SelectMany(asset => Enumerable.Range(0, 2).Select(async _ =>
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width=320", owner.Token);
            using var response = await client.SendAsync(request);
            response.EnsureSuccessStatusCode();
            using var decoded = SKBitmap.Decode(await response.Content.ReadAsByteArrayAsync());
            Assert.Equal(320, decoded.Width);
            Assert.Equal(160, decoded.Height);
        })));
        Assert.Equal(12, Directory.GetFiles(Path.Combine(factory.DataDirectory, "ArtworkVariants")).Length);
    }

    [Fact]
    public async Task WarmerPreparesTelevisionWidthsOncePerArtworkKind()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        await ApiTestClient.SetupOwnerAsync(client);
        var poster = await SeedAsync(factory, 1000, 1500, false, jpeg: true);
        var backdrop = await SeedAsync(factory, 2400, 1350, false, jpeg: true, kind: ArtworkKind.Backdrop);
        var profile = await SeedAsync(factory, 600, 900, false, jpeg: true, kind: ArtworkKind.Profile);
        var variants = factory.Services.GetRequiredService<Aurelia.Server.Services.ArtworkVariantStore>();
        var warmer = new Aurelia.Server.Services.ArtworkVariantWarmer(
            factory.Services.GetRequiredService<IServiceScopeFactory>(),
            factory.Services.GetRequiredService<Aurelia.Server.Services.ArtworkStore>(), variants,
            Microsoft.Extensions.Logging.Abstractions.NullLogger<Aurelia.Server.Services.ArtworkVariantWarmer>.Instance);
        Assert.Equal(4, await warmer.WarmAsync(TimeSpan.Zero, CancellationToken.None));
        Assert.True(variants.IsCached(poster.Id, poster.Revision, 640));
        Assert.True(variants.IsCached(backdrop.Id, backdrop.Revision, 1280));
        Assert.True(variants.IsCached(backdrop.Id, backdrop.Revision, 1920));
        Assert.True(variants.IsCached(profile.Id, profile.Revision, 320));
        Assert.False(variants.IsCached(poster.Id, poster.Revision, 1920));
        Assert.Equal(0, await warmer.WarmAsync(TimeSpan.Zero, CancellationToken.None));
    }

    [Fact]
    public async Task CacheEvictsOldFilesAndIsNotBackupState()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var asset = await SeedAsync(factory, 640, 320, false);
        var cache = Path.Combine(factory.DataDirectory, "ArtworkVariants");
        Directory.CreateDirectory(cache);
        var stale = Path.Combine(cache, "old.jpg");
        await using (var file = File.Create(stale)) file.SetLength(257L * 1024 * 1024);
        using var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/artwork/{asset.Id}?width=320", owner.Token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        Assert.False(File.Exists(stale));
        Assert.True(Directory.GetFiles(cache).Sum(path => new FileInfo(path).Length) <= 256L * 1024 * 1024);
        Assert.False(Aurelia.Server.Services.EncryptedBackupContainer.AllowedName("ArtworkVariants/test.jpg"));
    }

    private static async Task<ArtworkAsset> SeedAsync(AureliaServerFactory factory, int width, int height, bool alpha,
        bool jpeg = false, ArtworkKind kind = ArtworkKind.Poster)
    {
        var bytes = Image(width, height, alpha, SKColors.Red, jpeg);
        var id = Guid.NewGuid();
        var extension = jpeg ? "jpg" : "png";
        Directory.CreateDirectory(Path.Combine(factory.DataDirectory, "Artwork"));
        await File.WriteAllBytesAsync(Path.Combine(factory.DataDirectory, "Artwork", $"{id:N}.{extension}"), bytes);
        await using var scope = factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        // Unique synthetic paths, so one test can seed several titles.
        var root = $"/synthetic/artwork-{id:N}";
        var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", Path = root, NormalizedPath = root, Kind = LibraryKind.Movies, MonitoringEnabled = false };
        var movie = new MediaItem { Id = Guid.NewGuid(), LibraryRoot = library, Kind = MediaKind.Movie, SourcePath = root + "/title.mkv", NormalizedSourcePath = root + "/title.mkv", DetectedTitle = "Synthetic" };
        var metadata = new MediaMetadata { MediaItem = movie, MediaItemId = movie.Id };
        var artwork = new ArtworkAsset { Id = id, Metadata = metadata, MediaItemId = movie.Id, Kind = kind, RelativeFilePath = $"{id:N}.{extension}", ContentType = jpeg ? "image/jpeg" : "image/png", ContentLength = bytes.Length, CreatedAt = DateTimeOffset.UtcNow };
        database.ArtworkAssets.Add(artwork);
        await database.SaveChangesAsync();
        return artwork;
    }

    private static byte[] Image(int width, int height, bool alpha, SKColor color, bool jpeg = false)
    {
        using var bitmap = new SKBitmap(new SKImageInfo(width, height));
        using (var canvas = new SKCanvas(bitmap)) canvas.Clear(alpha ? color.WithAlpha(100) : color);
        using var image = SKImage.FromBitmap(bitmap);
        using var encoded = image.Encode(jpeg ? SKEncodedImageFormat.Jpeg : SKEncodedImageFormat.Png, jpeg ? 90 : 100);
        return encoded.ToArray();
    }
}
