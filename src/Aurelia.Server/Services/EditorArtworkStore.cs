using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;
using SkiaSharp;

namespace Aurelia.Server.Services;

public sealed class EditorArtworkStore(ServerRuntimeOptions runtime) : IDisposable
{
    public const long MaximumUploadBytes = 20 * 1024 * 1024;
    public const long MaximumPixels = 24_000_000;
    private readonly SemaphoreSlim decodeGate = new(1, 1);
    private readonly string drafts = Path.Combine(runtime.DataDirectory, "EditorUploads");
    private readonly string images = Path.Combine(runtime.DataDirectory, "Artwork");
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private sealed record Receipt(Guid MediaId, Guid UserId, Guid SessionId, DateTimeOffset ExpiresAt);
    public void Dispose() => decodeGate.Dispose();

    public async Task<EditorUploadSummary> UploadAsync(Guid mediaId, Guid userId, Guid sessionId, Stream input, CancellationToken token)
    {
        await decodeGate.WaitAsync(token);
        try
        {
            PruneDrafts();
            if (Directory.EnumerateFiles(drafts, "*.json").Count() >= 512)
                throw new AccountException("artwork_draft_limit", "Too many unfinished image uploads. Save or cancel existing editors first.", 429);
            using var bytes = new MemoryStream();
            var buffer = new byte[65_536];
            while (true)
            {
                var read = await input.ReadAsync(buffer, token);
                if (read == 0) break;
                if (bytes.Length + read > MaximumUploadBytes) throw new AccountException("artwork_too_large", "Images must be no larger than 20 MB.", 413);
                bytes.Write(buffer, 0, read);
            }
            using var bitmap = Decode(bytes.ToArray());
            using var oriented = Orient(bitmap.Image, bitmap.Origin);
            var data = Encode(oriented);
            var id = Guid.NewGuid();
            await WriteAsync(Path.Combine(drafts, id.ToString("N") + ".png"), data, token);
            try
            {
                await WriteAsync(Path.Combine(drafts, id.ToString("N") + ".json"),
                    JsonSerializer.SerializeToUtf8Bytes(new Receipt(mediaId, userId, sessionId, DateTimeOffset.UtcNow.AddHours(24)), Json), token);
            }
            catch { File.Delete(Path.Combine(drafts, id.ToString("N") + ".png")); throw; }
            return new(id, $"/api/v1/media/{mediaId}/editor/uploads/{id}", oriented.Width, oriented.Height);
        }
        finally { decodeGate.Release(); }
    }

    public string DraftPath(Guid id, Guid mediaId, Guid userId, Guid sessionId)
    {
        var name = id.ToString("N");
        var receiptPath = Path.Combine(drafts, name + ".json");
        if (!File.Exists(receiptPath) || new FileInfo(receiptPath).LinkTarget is not null)
            throw new AccountException("artwork_draft_missing", "The image draft expired. Import the image again.", 404);
        var receipt = JsonSerializer.Deserialize<Receipt>(File.ReadAllBytes(receiptPath), Json);
        if (receipt is null || receipt.MediaId != mediaId || receipt.UserId != userId || receipt.SessionId != sessionId
            || receipt.ExpiresAt <= DateTimeOffset.UtcNow)
            throw new AccountException("artwork_draft_missing", "The image draft is unavailable.", 404);
        return SafeImagePath(drafts, name + ".png");
    }

    public string OriginalPath(ArtworkAsset asset) => SafeImagePath(images, asset.OriginalFilePath ?? asset.RelativeFilePath);

    public void Discard(Guid id, Guid mediaId, Guid userId, Guid sessionId)
    {
        _ = DraftPath(id, mediaId, userId, sessionId);
        File.Delete(Path.Combine(drafts, id.ToString("N") + ".png"));
        File.Delete(Path.Combine(drafts, id.ToString("N") + ".json"));
    }

    public async Task<ArtworkAsset?> MaterializeAsync(AureliaDbContext database, Guid mediaId, Guid userId, Guid sessionId,
        EditorArtwork? selection, ArtworkKind kind, CancellationToken token)
    {
        if (selection is null) return null;
        if (selection.UploadId is not null && selection.AssetId is not null)
            throw new AccountException("invalid_artwork", "Choose one image source.", 400);
        ArtworkAsset? existing = null;
        if (selection.AssetId is { } assetId)
            existing = await database.ArtworkAssets.SingleOrDefaultAsync(asset => asset.Id == assetId && asset.MediaItemId == mediaId, token)
                ?? throw new AccountException("artwork_not_found", "The image was not found for this title.", 404);
        var crop = selection.Crop;
        ValidateCrop(crop);
        if (existing?.IsManual == true && existing.Kind == kind && JsonSerializer.Serialize(crop, Json) == (existing.CropJson ?? "null"))
            return existing;
        var sourcePath = selection.UploadId is { } upload ? DraftPath(upload, mediaId, userId, sessionId)
            : existing is not null ? OriginalPath(existing) : throw new AccountException("invalid_artwork", "Choose an image source.", 400);
        await decodeGate.WaitAsync(token);
        try
        {
            var info = new FileInfo(sourcePath);
            if (info.Length > MaximumUploadBytes) throw new AccountException("artwork_too_large", "The image exceeds the editing limit.", 413);
            using var decoded = Decode(await File.ReadAllBytesAsync(sourcePath, token), allowProviderWebP: existing?.IsManual == false);
            using var oriented = Orient(decoded.Image, decoded.Origin);
            using var rotated = Rotate(oriented, crop?.Rotation ?? 0);
            var id = Guid.NewGuid();
            var originalName = id.ToString("N") + ".original.png";
            var renderedName = id.ToString("N") + ".png";
            var sourceRect = crop is null ? new SKRect(0, 0, rotated.Width, rotated.Height)
                : new SKRect((float)(crop.X * rotated.Width), (float)(crop.Y * rotated.Height),
                    (float)((crop.X + crop.Width) * rotated.Width), (float)((crop.Y + crop.Height) * rotated.Height));
            var ratio = kind switch { ArtworkKind.Poster => 2d / 3, ArtworkKind.Profile => 1d, _ => 16d / 9 };
            // No requested crop uses a centered aspect-fit crop, not a stretched image.
            if (crop is null)
            {
                var width = Math.Min(rotated.Width, rotated.Height * ratio);
                var height = width / ratio;
                sourceRect = new SKRect((float)((rotated.Width - width) / 2), (float)((rotated.Height - height) / 2),
                    (float)((rotated.Width + width) / 2), (float)((rotated.Height + height) / 2));
            }
            else if (Math.Abs(sourceRect.Width / sourceRect.Height - ratio) > ratio * 0.015)
                throw new AccountException("invalid_crop", "The crop does not match this artwork's aspect ratio.", 400);
            var maxWidth = kind switch { ArtworkKind.Poster => 1200, ArtworkKind.Profile => 800, _ => 2560 };
            var outputWidth = Math.Max(1, (int)Math.Min(sourceRect.Width, maxWidth));
            var outputHeight = Math.Max(1, (int)Math.Round(outputWidth / ratio));
            using var result = new SKBitmap(outputWidth, outputHeight);
            using (var canvas = new SKCanvas(result)) canvas.DrawBitmap(rotated, sourceRect, new SKRect(0, 0, outputWidth, outputHeight), new SKSamplingOptions(SKFilterMode.Linear));
            var original = Encode(oriented);
            var rendered = Encode(result);
            PrivateFilePermissions.CreatePrivateDirectory(images);
            await WriteAsync(Path.Combine(images, originalName), original, token);
            try { await WriteAsync(Path.Combine(images, renderedName), rendered, token); }
            catch { File.Delete(Path.Combine(images, originalName)); throw; }
            var asset = new ArtworkAsset
            {
                Id = id,
                MediaItemId = mediaId,
                Kind = kind,
                IsManual = true,
                ProviderPath = "manual/" + id.ToString("N"),
                RelativeFilePath = renderedName,
                OriginalFilePath = originalName,
                CropJson = JsonSerializer.Serialize(crop, Json),
                ContentType = "image/png",
                ContentLength = rendered.Length,
                CreatedAt = DateTimeOffset.UtcNow
            };
            database.ArtworkAssets.Add(asset);
            return asset;
        }
        finally { decodeGate.Release(); }
    }

    internal sealed record DecodedImage(SKBitmap Image, SKEncodedOrigin Origin, bool IsJpeg = false) : IDisposable
    { public void Dispose() => Image.Dispose(); }
    /// <param name="minimumWidth">When set, a JPEG is decoded at the smallest DCT scale
    /// (1/2, 1/4 or 1/8) whose displayed width still covers it; other formats and
    /// smaller sources decode at full size.</param>
    internal static DecodedImage Decode(byte[] bytes, bool allowProviderWebP = false, int? minimumWidth = null)
    {
        using var stream = new SKMemoryStream(bytes);
        using var codec = SKCodec.Create(stream);
        if (codec is null || (codec.EncodedFormat is not SKEncodedImageFormat.Jpeg and not SKEncodedImageFormat.Png
                && !(allowProviderWebP && codec.EncodedFormat == SKEncodedImageFormat.Webp))
            || codec.Info.Width < 1 || codec.Info.Height < 1 || (long)codec.Info.Width * codec.Info.Height > MaximumPixels
            || codec.FrameCount > 1)
            throw new AccountException("invalid_image", "Use a valid, non-animated JPEG or PNG image of at most 24 megapixels.", 400);
        var isJpeg = codec.EncodedFormat == SKEncodedImageFormat.Jpeg;
        var size = new SKSizeI(codec.Info.Width, codec.Info.Height);
        if (isJpeg && minimumWidth is > 0)
        {
            var swapped = codec.EncodedOrigin is SKEncodedOrigin.LeftTop or SKEncodedOrigin.RightTop
                or SKEncodedOrigin.RightBottom or SKEncodedOrigin.LeftBottom;
            foreach (var scale in new[] { 0.125f, 0.25f, 0.5f })
            {
                var scaled = codec.GetScaledDimensions(scale);
                if ((swapped ? scaled.Height : scaled.Width) >= minimumWidth) { size = scaled; break; }
            }
        }
        var bitmap = new SKBitmap(new SKImageInfo(size.Width, size.Height, SKColorType.Rgba8888, SKAlphaType.Premul));
        if (codec.GetPixels(bitmap.Info, bitmap.GetPixels()) != SKCodecResult.Success)
        { bitmap.Dispose(); throw new AccountException("invalid_image", "The image could not be decoded completely.", 400); }
        return new(bitmap, codec.EncodedOrigin, isJpeg);
    }
    internal static void ValidateStoredImage(string path)
    {
        using var image = Decode(File.ReadAllBytes(path));
    }
    internal static SKBitmap Orient(SKBitmap source, SKEncodedOrigin origin)
    {
        var swap = origin is SKEncodedOrigin.LeftTop or SKEncodedOrigin.RightTop or SKEncodedOrigin.RightBottom or SKEncodedOrigin.LeftBottom;
        var result = new SKBitmap(swap ? source.Height : source.Width, swap ? source.Width : source.Height);
        using var canvas = new SKCanvas(result);
        switch (origin)
        {
            case SKEncodedOrigin.TopRight: canvas.Translate(source.Width, 0); canvas.Scale(-1, 1); break;
            case SKEncodedOrigin.BottomRight: canvas.Translate(source.Width, source.Height); canvas.RotateDegrees(180); break;
            case SKEncodedOrigin.BottomLeft: canvas.Translate(0, source.Height); canvas.Scale(1, -1); break;
            case SKEncodedOrigin.LeftTop: canvas.RotateDegrees(90); canvas.Scale(1, -1); break;
            case SKEncodedOrigin.RightTop: canvas.Translate(source.Height, 0); canvas.RotateDegrees(90); break;
            case SKEncodedOrigin.RightBottom: canvas.Translate(source.Height, source.Width); canvas.RotateDegrees(90); canvas.Scale(-1, 1); break;
            case SKEncodedOrigin.LeftBottom: canvas.Translate(0, source.Width); canvas.RotateDegrees(270); break;
        }
        canvas.DrawBitmap(source, 0, 0, new SKSamplingOptions(SKFilterMode.Linear));
        return result;
    }
    private static SKBitmap Rotate(SKBitmap source, int rotation) => Orient(source, rotation switch
    { 90 => SKEncodedOrigin.RightTop, 180 => SKEncodedOrigin.BottomRight, 270 => SKEncodedOrigin.LeftBottom, _ => SKEncodedOrigin.TopLeft });
    private static byte[] Encode(SKBitmap bitmap)
    {
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        if (data.Size > MaximumUploadBytes) throw new AccountException("artwork_too_large", "The decoded image is too large. Choose a smaller image.", 413);
        return data.ToArray();
    }
    private static void ValidateCrop(ArtworkCrop? crop)
    {
        if (crop is not null && (!double.IsFinite(crop.X) || !double.IsFinite(crop.Y) || !double.IsFinite(crop.Width)
            || !double.IsFinite(crop.Height) || crop.X < 0 || crop.Y < 0 || crop.Width <= 0 || crop.Height <= 0
            || crop.X + crop.Width > 1.000001 || crop.Y + crop.Height > 1.000001 || crop.Rotation is not 0 and not 90 and not 180 and not 270))
            throw new AccountException("invalid_crop", "The crop is outside the source image.", 400);
    }
    internal static string SafeImagePath(string directory, string name)
    {
        if (name != Path.GetFileName(name)) throw new IOException("Invalid managed image path.");
        var path = Path.Combine(directory, name);
        if (!File.Exists(path) || new FileInfo(path).LinkTarget is not null) throw new IOException("The image is unavailable.");
        return path;
    }
    private static async Task WriteAsync(string path, byte[] data, CancellationToken token)
    {
        await using var output = PrivateFilePermissions.OpenNewPrivateFile(path);
        await output.WriteAsync(data, token);
    }
    public async Task PruneDraftsAsync(CancellationToken token)
    {
        await decodeGate.WaitAsync(token);
        try { PruneDrafts(); } finally { decodeGate.Release(); }
    }

    public async Task<IReadOnlyList<string>> MediaDraftFilesAsync(IReadOnlyCollection<Guid> mediaIds, CancellationToken token)
    {
        await decodeGate.WaitAsync(token);
        try
        {
            var files = new List<string>();
            PrivateFilePermissions.CreatePrivateDirectory(drafts);
            foreach (var path in Directory.EnumerateFiles(drafts, "*.json"))
            {
                var receipt = JsonSerializer.Deserialize<Receipt>(File.ReadAllBytes(path), Json);
                if (receipt is null || !mediaIds.Contains(receipt.MediaId)) continue;
                files.Add("EditorUploads/" + Path.GetFileName(path));
                files.Add("EditorUploads/" + Path.GetFileName(Path.ChangeExtension(path, ".png")));
            }
            return files;
        }
        finally { decodeGate.Release(); }
    }

    private void PruneDrafts()
    {
        PrivateFilePermissions.CreatePrivateDirectory(drafts);
        foreach (var file in Directory.EnumerateFiles(drafts))
            if (new FileInfo(file).LastWriteTimeUtc < DateTime.UtcNow.AddHours(-24)) File.Delete(file);
    }
}
