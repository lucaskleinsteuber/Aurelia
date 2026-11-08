using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>Offline downloads with an invented title in a temporary folder; nothing is played or fetched.</summary>
public sealed class OfflineDownloadTests : IDisposable
{
    private static readonly JsonSerializerOptions WebJson = new(JsonSerializerDefaults.Web);
    private readonly string root = Path.Combine(Path.GetTempPath(), "aurelia-offline-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
    }

    private OfflineTitle Invented()
    {
        var id = Guid.NewGuid();
        var title = new OfflineTitle(id, FakeServer.ServerId, FakeLibrary.OwnerId, "Invented Film", "2024", MediaKind.Movie, "title.mkv",
            "video/x-matroska", 4, DateTimeOffset.UtcNow, 60_000, 600_000, false, null, false,
            [new OfflineSubtitle(1000, "de", "German", false, false, "subtitle-1000.vtt")]);
        var folder = Path.Combine(root, id.ToString("N"));
        Directory.CreateDirectory(folder);
        File.WriteAllBytes(Path.Combine(folder, "title.mkv"), [1, 2, 3, 4]);
        File.WriteAllText(Path.Combine(folder, "subtitle-1000.vtt"), "WEBVTT\n");
        File.WriteAllText(Path.Combine(root, "index.json"), JsonSerializer.Serialize(new[] { title }, WebJson));
        return title;
    }

    [Fact]
    public void FreeSpaceIsReadFromTheDriveThatHoldsTheFolder()
    {
        var free = OfflineDownloads.FreeSpace(Path.GetTempPath());
        Assert.True(free > 0);
        // Other tests write meanwhile, so the same drive only has to answer about the same.
        Assert.InRange(OfflineDownloads.FreeSpace(Path.Combine(Path.GetTempPath(), "not-yet-created", "deeper")), free - 1_000_000_000, free + 1_000_000_000);
    }

    [Fact]
    public void TheListOfDownloadsIsPrivateAndAFailedSaveIsReported()
    {
        if (OperatingSystem.IsWindows())
        {
            Assert.Skip("Unix permissions only.");
            return;
        }
        var title = Invented();
        var downloads = new OfflineDownloads(root);
        downloads.SaveProgress(title.Id, 120_000, 600_000, completed: false);
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(Path.Combine(root, "index.json")));
        // A directory in place of the temporary file makes the next save fail without throwing.
        Directory.CreateDirectory(Path.Combine(root, "index.json.tmp"));
        downloads.SaveProgress(title.Id, 180_000, 600_000, completed: false);
        Assert.NotNull(downloads.Error);
    }

    [Fact]
    public void OfflineProgressWinsWhileTheServerKeptItsRevisionWhateverTheClock()
    {
        var title = Invented() with { ServerRevision = 7, ProgressSavedAt = DateTimeOffset.UtcNow.AddHours(-2), ProgressDirty = true };
        // This computer's clock runs two hours behind: the server's time looks later.
        var unchanged = new PlaybackProgressResponse(title.Id, 0, 600_000, false, null, DateTimeOffset.UtcNow, Revision: 7);
        Assert.True(OfflineDownloads.OfflineIsNewer(title, unchanged));
        var watchedElsewhere = unchanged with { Revision = 8 };
        Assert.False(OfflineDownloads.OfflineIsNewer(title, watchedElsewhere));
        Assert.True(OfflineDownloads.OfflineIsNewer(title, watchedElsewhere with { UpdatedAt = DateTimeOffset.UtcNow.AddHours(-3) }));
    }

    [Fact]
    public void DownloadsAreKeptPerProfileAndForgottenWhenTheirFileIsGone()
    {
        var title = Invented();
        var downloads = new OfflineDownloads(root);
        Assert.Equal(title.Id, Assert.Single(downloads.For(FakeServer.ServerId, FakeLibrary.OwnerId)).Id);
        Assert.Empty(downloads.For(FakeServer.ServerId, Guid.NewGuid()));
        downloads.SaveProgress(title.Id, 120_000, 600_000, completed: false);
        var reopened = new OfflineDownloads(root);
        Assert.Equal(120_000, reopened.Find(title.Id)!.PositionMilliseconds);
        Assert.True(reopened.Find(title.Id)!.ProgressDirty);
        File.Delete(reopened.FileOf(title));
        Assert.Empty(new OfflineDownloads(root).Titles);
        Assert.Equal("mp4", OfflineDownloads.Extension("video/mp4"));
        Assert.Equal("mkv", OfflineDownloads.Extension("video/x-matroska"));
    }

    [Fact]
    public async Task ADownloadPlaysFromItsFileWithItsSubtitlesAndKeepsProgressOnThisComputer()
    {
        var title = Invented();
        var downloads = new OfflineDownloads(root);
        var engines = new SimulatedEngines();
        using var api = new AureliaApi(new FakeServer());
        var stored = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
            "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));
        var profile = new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
            "profile-token-synthetic-0000000000000000001", DateTimeOffset.UtcNow.AddHours(12));
        var library = new LibraryClient(api, stored, profile, ["library-state-v1"]);
        await using var controller = new PlaybackController(new PlaybackClient(api, library), engines, new MemorySettingsStore(), new ProgressOutbox(null),
            TimeProvider.System, action => action());

        await controller.StartOfflineAsync(title, downloads);
        Assert.True(controller.IsOffline);
        var engine = engines.Last;
        Assert.True(engine.OpenedUrl!.IsFile);
        Assert.Equal(downloads.FileOf(title), engine.OpenedUrl.LocalPath);
        Assert.Equal(60_000, engine.OpenedAt);
        Assert.Equal("subtitle-1000.vtt", Path.GetFileName(Assert.Single(engine.AddedSubtitles).LocalPath));

        engine.Seek(300_000);
        controller.PlayPause();
        await Task.Delay(50, TestContext.Current.CancellationToken);
        Assert.Equal(300_000, downloads.Find(title.Id)!.PositionMilliseconds);
        Assert.True(downloads.Find(title.Id)!.ProgressDirty);
    }
    [Fact]
    public async Task AnEarlierDownloadGetsItsPosterAndDescriptionFromTheLibrary()
    {
        var title = Invented();
        // The list as an earlier version wrote it, without any of the newer fields.
        var stored = JsonSerializer.Deserialize<System.Text.Json.Nodes.JsonArray>(File.ReadAllText(Path.Combine(root, "index.json")))!;
        foreach (var name in new[] { "overview", "year", "genres", "parentId", "parentTitle", "seasonNumber", "episodeNumber", "posterFile", "backdropFile", "seriesPosterFile" })
            stored[0]!.AsObject().Remove(name);
        File.WriteAllText(Path.Combine(root, "index.json"), stored.ToJsonString());
        var downloads = new OfflineDownloads(root);
        Assert.False(downloads.Find(title.Id)!.HasArtwork);

        var poster = new ArtworkSummary(Guid.NewGuid(), ArtworkKind.Poster, "poster.jpg", "image/jpeg", 4);
        var server = new FakeServer().Image($"/api/v1/artwork/{poster.Id}", [0x89, 0x50, 0x4E, 0x47]);
        using var api = new AureliaApi(server);
        var library = new LibraryClient(api, new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
                "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30)),
            new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
                "profile-token-synthetic-0000000000000000001", DateTimeOffset.UtcNow.AddHours(12)), ["library-state-v1"]);
        var item = new CatalogItemSummary(title.Id, MediaKind.Movie, "Invented Film", null, 2024, "An invented story.", ["Drama"], poster, null,
            MediaAvailability.Available, false, null, DateTimeOffset.UtcNow);

        await downloads.CompleteDetailsAsync(library, [item]);

        var completed = downloads.Find(title.Id)!;
        Assert.Equal("poster.image", completed.PosterFile);
        Assert.Equal("An invented story.", completed.Overview);
        Assert.Equal(2024, completed.Year);
        Assert.Equal(60_000, completed.PositionMilliseconds);
        Assert.Equal([0x89, 0x50, 0x4E, 0x47], File.ReadAllBytes(Path.Combine(downloads.Folder(title.Id), "poster.image")));
        Assert.Equal("poster.image", new OfflineDownloads(root).Find(title.Id)!.PosterFile);
    }
}
