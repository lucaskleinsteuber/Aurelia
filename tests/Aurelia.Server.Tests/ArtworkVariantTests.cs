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

    private static async Task<ArtworkAsset> SeedAsync(AureliaServerFactory factory, int width, int height, bool alpha)
    {
        var bytes = Image(width, height, alpha, SKColors.Red);
        var id = Guid.NewGuid();
        Directory.CreateDirectory(Path.Combine(factory.DataDirectory, "Artwork"));
        await File.WriteAllBytesAsync(Path.Combine(factory.DataDirectory, "Artwork", $"{id:N}.png"), bytes);
        await using var scope = factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", Path = "/synthetic/artwork", NormalizedPath = "/synthetic/artwork", Kind = LibraryKind.Movies, MonitoringEnabled = false };
        var movie = new MediaItem { Id = Guid.NewGuid(), LibraryRoot = library, Kind = MediaKind.Movie, SourcePath = "/synthetic/artwork/title.mkv", NormalizedSourcePath = "/synthetic/artwork/title.mkv", DetectedTitle = "Synthetic" };
        var metadata = new MediaMetadata { MediaItem = movie, MediaItemId = movie.Id };
        var artwork = new ArtworkAsset { Id = id, Metadata = metadata, MediaItemId = movie.Id, Kind = ArtworkKind.Poster, RelativeFilePath = $"{id:N}.png", ContentType = "image/png", ContentLength = bytes.Length, CreatedAt = DateTimeOffset.UtcNow };
        database.ArtworkAssets.Add(artwork);
        await database.SaveChangesAsync();
        return artwork;
    }

    private static byte[] Image(int width, int height, bool alpha, SKColor color)
    {
        using var bitmap = new SKBitmap(new SKImageInfo(width, height));
        using (var canvas = new SKCanvas(bitmap)) canvas.Clear(alpha ? color.WithAlpha(100) : color);
        using var image = SKImage.FromBitmap(bitmap);
        using var encoded = image.Encode(SKEncodedImageFormat.Png, 100);
        return encoded.ToArray();
    }
}
