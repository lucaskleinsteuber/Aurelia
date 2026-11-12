using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Aurelia.Server.Services.Segments;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// Intro and credits detection through the real server and ffmpeg, with an invented season whose
/// sound is generated here. Skipped where no ffmpeg is installed.
/// </summary>
[Collection(LiveConversionRuns.Name)]
public sealed class SegmentDetectionTests
{
    private const double EpisodeSeconds = 200;
    private const double IntroSeconds = 30;
    private const double CreditsSeconds = 25;
    private static readonly double[] ColdOpens = [5, 15, 25, 35];
    private static readonly double[] AfterCredits = [0, 0, 0, 10];

    [Fact]
    public async Task ASeasonGetsItsTimesFromSoundAndOnlyTimestampsAreStored()
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var parent = TestPaths.CreateDataDirectory();
        var root = Path.Combine(parent, "Invented Series");
        Directory.CreateDirectory(root);
        try
        {
            var paths = await MakeSeasonAsync(maker, root, chapters: null);
            var before = paths.Select(path => (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length)).ToArray();
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var (seriesId, episodes) = await AddSeasonAsync(factory, root, paths);
            var detection = factory.Services.GetRequiredService<SegmentDetectionService>();

            using (var capabilities = await client.GetAsync("/api/v1/capabilities"))
            {
                Assert.Contains(ServerFeatures.MediaSegments, (await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities)).Capabilities);
            }
            var status = await SettingsAsync(client, owner.Token);
            Assert.True(status is { Available: true, Enabled: true, PendingCount: 4, AnalyzedCount: 0 });

            var dataFiles = Files(factory.DataDirectory);
            var temporaryFiles = TemporaryVideoFiles();
            Assert.Equal(1, await detection.QueuePendingSeasonsAsync(CancellationToken.None));
            Assert.Equal(4, await detection.ProcessPendingAsync(CancellationToken.None));

            // Nothing but the database changed: no sound, fingerprint or other file anywhere.
            var newDataFiles = Files(factory.DataDirectory).Except(dataFiles).Where(file => !ServerBookkeeping(factory.DataDirectory, file)).ToList();
            Assert.True(newDataFiles.Count == 0, string.Join(", ", newDataFiles));
            Assert.Empty(TemporaryVideoFiles().Except(temporaryFiles));
            Assert.Equal(paths.Order(StringComparer.Ordinal), Directory.GetFiles(root).Order(StringComparer.Ordinal));
            Assert.Equal(before, paths.Select(path => (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length)).ToArray());

            for (var index = 0; index < episodes.Length; index++)
            {
                var times = await SegmentsAsync(client, owner.Token, episodes[index]);
                Assert.True(times is { Analyzed: true, CanAnalyze: true, IntroSource: MediaSegmentSource.Detected, CreditsSource: MediaSegmentSource.Detected });
                Assert.InRange(times.IntroStartMilliseconds!.Value, (ColdOpens[index] - 1) * 1000, (ColdOpens[index] + 1) * 1000);
                Assert.InRange(times.IntroEndMilliseconds!.Value, (ColdOpens[index] + IntroSeconds - 1) * 1000, (ColdOpens[index] + IntroSeconds + 1) * 1000);
                var credits = EpisodeSeconds - AfterCredits[index] - CreditsSeconds;
                Assert.InRange(times.CreditsStartMilliseconds!.Value, (credits - 1) * 1000, (credits + 1) * 1000);
                Assert.True(times.IntroConfidence >= SegmentRules.MinimumConfidence);
            }
            status = await SettingsAsync(client, owner.Token);
            Assert.True(status is { PendingCount: 0, AnalyzedCount: 4, NoResultCount: 0 });

            // The playback ticket carries the times, so players need no extra request.
            var first = await SegmentsAsync(client, owner.Token, episodes[0]);
            var playback = await PlaybackAsync(client, owner.Token, episodes[0]);
            Assert.Equal(new MediaSegmentsDto(first.IntroStartMilliseconds, first.IntroEndMilliseconds, first.CreditsStartMilliseconds), playback.Segments);

            // Nothing queued: every episode is current.
            Assert.Equal(0, await detection.QueuePendingSeasonsAsync(CancellationToken.None));

            // A correction by hand survives a new analysis; the untouched part follows detection.
            using (var invalid = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{episodes[0]}/segments", owner.Token,
                       new SetMediaSegmentsRequest(9_000, 4_000, first.CreditsStartMilliseconds)))
            using (var rejected = await ApiTestClient.SendAsync(client, invalid))
            {
                Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);
            }
            using (var outside = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{episodes[0]}/segments", owner.Token,
                       new SetMediaSegmentsRequest(1_000, 31_000, 900_000)))
            using (var rejected = await ApiTestClient.SendAsync(client, outside))
            {
                Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);
            }
            using (var anonymous = await client.GetAsync($"/api/v1/media/{episodes[0]}/segments"))
            {
                Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
            }
            using (var correct = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{episodes[0]}/segments", owner.Token,
                       new SetMediaSegmentsRequest(1_000, 31_000, first.CreditsStartMilliseconds)))
            using (var corrected = await ApiTestClient.SendAsync(client, correct))
            {
                corrected.EnsureSuccessStatusCode();
                var saved = await ApiTestClient.ReadAsync<MediaSegmentsResponse>(corrected);
                Assert.Equal((1_000L, 31_000L, MediaSegmentSource.Manual, MediaSegmentSource.Detected),
                    (saved.IntroStartMilliseconds, saved.IntroEndMilliseconds, saved.IntroSource, saved.CreditsSource));
            }
            using (var again = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/media-segments/reanalyze", owner.Token,
                       new ReanalyzeMediaSegmentsRequest(seriesId, 1)))
            using (var queued = await ApiTestClient.SendAsync(client, again))
            {
                queued.EnsureSuccessStatusCode();
                Assert.Equal(4, (await ApiTestClient.ReadAsync<MediaSegmentSettingsResponse>(queued)).PendingCount);
            }
            Assert.Equal(1, await detection.QueuePendingSeasonsAsync(CancellationToken.None));
            Assert.Equal(4, await detection.ProcessPendingAsync(CancellationToken.None));
            var kept = await SegmentsAsync(client, owner.Token, episodes[0]);
            Assert.Equal((1_000L, 31_000L, MediaSegmentSource.Manual), (kept.IntroStartMilliseconds, kept.IntroEndMilliseconds, kept.IntroSource));
            Assert.Equal((first.CreditsStartMilliseconds, MediaSegmentSource.Detected), (kept.CreditsStartMilliseconds, kept.CreditsSource));
            Assert.Equal(1_000, (await PlaybackAsync(client, owner.Token, episodes[0])).Segments!.IntroStartMilliseconds);

            // Removing the correction brings the automatic times back.
            using (var reset = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/media/{episodes[0]}/segments", owner.Token))
            using (var cleared = await ApiTestClient.SendAsync(client, reset))
            {
                cleared.EnsureSuccessStatusCode();
                Assert.False((await ApiTestClient.ReadAsync<MediaSegmentsResponse>(cleared)).Analyzed);
            }
            Assert.Equal(1, await detection.ProcessPendingAsync(CancellationToken.None));
            var restored = await SegmentsAsync(client, owner.Token, episodes[0]);
            Assert.Equal((first.IntroStartMilliseconds, first.IntroEndMilliseconds, MediaSegmentSource.Detected),
                (restored.IntroStartMilliseconds, restored.IntroEndMilliseconds, restored.IntroSource));

            // A changed file (as the next scan records it) is examined again, alone.
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var changed = await database.MediaItems.SingleAsync(item => item.Id == episodes[1]);
                changed.FileModifiedAt = changed.FileModifiedAt!.Value.AddSeconds(5);
                // The synthetic file changes on disk too, as the scan would have found it; opening it
                // to examine it reads the real time again.
                File.SetLastWriteTimeUtc(changed.SourcePath, changed.FileModifiedAt.Value.UtcDateTime);
                await database.SaveChangesAsync();
            }
            Assert.False((await SegmentsAsync(client, owner.Token, episodes[1])).Analyzed);
            Assert.Equal(1, await detection.QueuePendingSeasonsAsync(CancellationToken.None));
            Assert.Equal(1, await detection.ProcessPendingAsync(CancellationToken.None));
            Assert.True((await SegmentsAsync(client, owner.Token, episodes[1])).Analyzed);
            // The test's own change is undone; the check below proves the examination changed no file.
            File.SetLastWriteTimeUtc(paths[1], before[1].Item1);

            // With detection off only times set by hand are handed out, and nothing is examined.
            using (var disable = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/server/media-segments", owner.Token, new UpdateMediaSegmentSettingsRequest(false)))
            using (var disabled = await ApiTestClient.SendAsync(client, disable))
            {
                disabled.EnsureSuccessStatusCode();
                Assert.False((await ApiTestClient.ReadAsync<MediaSegmentSettingsResponse>(disabled)).Enabled);
            }
            Assert.Null((await PlaybackAsync(client, owner.Token, episodes[2])).Segments);
            Assert.Equal(0, await detection.QueuePendingSeasonsAsync(CancellationToken.None));

            // Times go when the title is removed from the library, and only then.
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                Assert.Equal(4, await database.MediaSegments.CountAsync());
                database.MediaItems.Remove(await database.MediaItems.SingleAsync(item => item.Id == episodes[3]));
                await database.SaveChangesAsync();
                Assert.Equal(3, await database.MediaSegments.CountAsync());
            }
            Assert.Equal(before, paths.Select(path => (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length)).ToArray());
        }
        finally
        {
            Directory.Delete(parent, recursive: true);
        }
    }

    [Fact]
    public async Task ChaptersNamedIntroAndCreditsTakePrecedenceOverSound()
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var parent = TestPaths.CreateDataDirectory();
        var root = Path.Combine(parent, "Invented Chapters");
        Directory.CreateDirectory(root);
        try
        {
            // The first episode's chapters deliberately differ from where the shared music sits.
            var paths = await MakeSeasonAsync(maker, root, chapters: [(0, 40, "Prologue"), (40, 71.5, "Intro"), (71.5, 160, "Episode"), (160, 200, "End Credits")]);
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var (_, episodes) = await AddSeasonAsync(factory, root, paths);
            var detection = factory.Services.GetRequiredService<SegmentDetectionService>();
            await detection.QueuePendingSeasonsAsync(CancellationToken.None);
            Assert.Equal(4, await detection.ProcessPendingAsync(CancellationToken.None));

            var named = await SegmentsAsync(client, owner.Token, episodes[0]);
            Assert.Equal((40_000L, 71_500L, MediaSegmentSource.Chapters, 1.0),
                (named.IntroStartMilliseconds, named.IntroEndMilliseconds, named.IntroSource, named.IntroConfidence));
            Assert.Equal((160_000L, MediaSegmentSource.Chapters), (named.CreditsStartMilliseconds, named.CreditsSource));
            Assert.Equal(MediaSegmentSource.Detected, (await SegmentsAsync(client, owner.Token, episodes[1])).IntroSource);
        }
        finally
        {
            Directory.Delete(parent, recursive: true);
        }
    }

    [Fact]
    public async Task CreditsWithoutSharedMusicAreFoundInPicturesWithoutWritingFiles()
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var parent = TestPaths.CreateDataDirectory();
        var root = Path.Combine(parent, "Invented Pictures");
        Directory.CreateDirectory(root);
        try
        {
            // Four episodes of 200 s: own scenes and own noise as sound, then 25 s of names on black
            // and 5 s of a logo. Nothing is shared in the sound, so only pictures can find the credits.
            var paths = new string[4];
            for (var index = 0; index < paths.Length; index++)
            {
                paths[index] = Path.Combine(root, $"Invented Pictures S01E0{index + 1}.mkv");
                await EncodePicturesAsync(maker, paths[index], seed: index);
            }
            var before = paths.Select(path => (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length)).ToArray();
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var (_, episodes) = await AddSeasonAsync(factory, root, paths);
            var detection = factory.Services.GetRequiredService<SegmentDetectionService>();
            var dataFiles = Files(factory.DataDirectory);
            var temporaryFiles = TemporaryVideoFiles();

            await detection.QueuePendingSeasonsAsync(CancellationToken.None);
            Assert.Equal(4, await detection.ProcessPendingAsync(CancellationToken.None));

            foreach (var episode in episodes)
            {
                var times = await SegmentsAsync(client, owner.Token, episode);
                Assert.Equal(MediaSegmentSource.Detected, times.CreditsSource);
                Assert.InRange(times.CreditsStartMilliseconds!.Value, 169_000, 171_000);
                Assert.Equal(MediaSegmentSource.None, times.IntroSource);
            }
            using (var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/media-segments/series", owner.Token))
            using (var response = await client.SendAsync(request))
            {
                response.EnsureSuccessStatusCode();
                var series = Assert.Single(await ApiTestClient.ReadAsync<MediaSegmentSeriesStatus[]>(response));
                Assert.Equal(("Invented Series", 4, 0, 4, 0), (series.Title, series.EpisodeCount, series.WithIntro, series.WithCredits, series.PendingCount));
            }
            var settings = await SettingsAsync(client, owner.Token);
            Assert.True(settings is { UsePictures: true, TotalCount: 4, PendingCount: 0, Running: false });

            // Without pictures the same season has no credits.
            using (var off = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/server/media-segments", owner.Token,
                       new UpdateMediaSegmentSettingsRequest(true, UsePictures: false)))
            using (var saved = await ApiTestClient.SendAsync(client, off))
            {
                saved.EnsureSuccessStatusCode();
                Assert.False((await ApiTestClient.ReadAsync<MediaSegmentSettingsResponse>(saved)).UsePictures);
            }
            await detection.ReanalyzeAsync(null, null, CancellationToken.None);
            await detection.QueuePendingSeasonsAsync(CancellationToken.None);
            Assert.Equal(4, await detection.ProcessPendingAsync(CancellationToken.None));
            Assert.Equal(MediaSegmentSource.None, (await SegmentsAsync(client, owner.Token, episodes[0])).CreditsSource);

            var newDataFiles = Files(factory.DataDirectory).Except(dataFiles).Where(file => !ServerBookkeeping(factory.DataDirectory, file)).ToList();
            Assert.True(newDataFiles.Count == 0, string.Join(", ", newDataFiles));
            Assert.Empty(TemporaryVideoFiles().Except(temporaryFiles));
            Assert.Equal(paths.Order(StringComparer.Ordinal), Directory.GetFiles(root).Order(StringComparer.Ordinal));
            Assert.Equal(before, paths.Select(path => (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length)).ToArray());
        }
        finally
        {
            Directory.Delete(parent, recursive: true);
        }
    }

    [Fact]
    public async Task AMoviesCreditsAreFoundInItsLastPicturesWithoutExaminingEpisodesAgain()
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var parent = TestPaths.CreateDataDirectory();
        var root = Path.Combine(parent, "Invented Movies");
        Directory.CreateDirectory(root);
        try
        {
            // 21 minutes: the film until 18:20, 130 s of names on black, 30 s of a scene after them.
            var path = Path.Combine(root, "Invented Movie (2026).mkv");
            await EncodeFramesAsync(maker, path, seconds: 1_260, second => second < 1_100
                ? SyntheticPictures.Scene(70_000 + second)
                : second < 1_230 ? SyntheticPictures.Credits(71_000 + second / 4) : SyntheticPictures.Scene(72_000 + second));
            var before = (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length);
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var movie = await AddMovieAsync(factory, root, path);
            // An episode already examined under the episode rules stays as it is.
            var episode = await AddExaminedEpisodeAsync(factory, root);
            var detection = factory.Services.GetRequiredService<SegmentDetectionService>();
            var dataFiles = Files(factory.DataDirectory);

            var waiting = await SettingsAsync(client, owner.Token);
            Assert.True(waiting is { MovieCount: 1, MoviesPendingCount: 1, MoviesWithCredits: 0, PendingCount: 0 });
            Assert.True((await SegmentsAsync(client, owner.Token, movie)) is { CanAnalyze: true, Analyzed: false });
            Assert.Equal(1, await detection.QueuePendingSeasonsAsync(CancellationToken.None));
            Assert.Equal(1, await detection.ProcessPendingAsync(CancellationToken.None));

            var times = await SegmentsAsync(client, owner.Token, movie);
            Assert.True(times is { Analyzed: true, CreditsSource: MediaSegmentSource.Detected, IntroSource: MediaSegmentSource.None }, times.ToString());
            Assert.InRange(times.CreditsStartMilliseconds!.Value, 1_099_000, 1_101_000);
            var done = await SettingsAsync(client, owner.Token);
            Assert.True(done is { MovieCount: 1, MoviesPendingCount: 0, MoviesWithCredits: 1, AnalyzedCount: 1 });
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                Assert.Equal(SegmentDetectionService.MovieAnalysisVersion, (await database.MediaSegments.SingleAsync(row => row.MediaItemId == movie)).AnalysisVersion);
                Assert.Equal(SegmentDetectionService.AnalysisVersion, (await database.MediaSegments.SingleAsync(row => row.MediaItemId == episode)).AnalysisVersion);
            }

            // Examining only the movies again leaves the episode alone; the result is the same.
            await detection.ReanalyzeAsync(null, null, CancellationToken.None, movies: true);
            Assert.Equal(1, await detection.QueuePendingSeasonsAsync(CancellationToken.None));
            Assert.Equal(1, await detection.ProcessPendingAsync(CancellationToken.None));
            Assert.InRange((await SegmentsAsync(client, owner.Token, movie)).CreditsStartMilliseconds!.Value, 1_099_000, 1_101_000);
            Assert.Equal(0, await detection.QueuePendingSeasonsAsync(CancellationToken.None));

            // A movie can be examined again from its own page.
            using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{movie}/segments/reanalyze", owner.Token))
            using (var response = await client.SendAsync(request))
            {
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            }

            var newDataFiles = Files(factory.DataDirectory).Except(dataFiles).Where(file => !ServerBookkeeping(factory.DataDirectory, file)).ToList();
            Assert.True(newDataFiles.Count == 0, string.Join(", ", newDataFiles));
            Assert.Equal(before, (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length));
        }
        finally
        {
            Directory.Delete(parent, recursive: true);
        }
    }

    /// <summary>Invented pictures at two a second with noise as sound.</summary>
    private static async Task EncodeFramesAsync(string ffmpeg, string path, int seconds, Func<int, byte[]> picture)
    {
        var start = new ProcessStartInfo(ffmpeg) { RedirectStandardInput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in new[]
        {
            "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "gray", "-s", "320x180", "-r", "2", "-i", "pipe:0",
            "-f", "lavfi", "-i", string.Create(System.Globalization.CultureInfo.InvariantCulture, $"anoisesrc=d={seconds}:c=pink:seed=3:a=0.1"),
            "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "8", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest", path,
        }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var errors = process.StandardError.ReadToEndAsync();
        for (var second = 0; second < seconds; second++)
        {
            var frame = picture(second);
            await process.StandardInput.BaseStream.WriteAsync(frame);
            await process.StandardInput.BaseStream.WriteAsync(frame);
        }
        process.StandardInput.Close();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == 0, await errors);
    }

    private static async Task<Guid> AddMovieAsync(AureliaServerFactory factory, string root, string path)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Invented Movie Library",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        var movie = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = "Invented Movie",
            Category = string.Empty,
            Extension = Path.GetExtension(path),
            FileSize = new FileInfo(path).Length,
            FileModifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero),
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        };
        database.MediaItems.Add(movie);
        await database.SaveChangesAsync();
        return movie.Id;
    }

    /// <summary>One episode whose times were stored under the current episode rules; it has no file.</summary>
    private static async Task<Guid> AddExaminedEpisodeAsync(AureliaServerFactory factory, string root)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = await database.LibraryRoots.FirstAsync();
        var seriesPath = Path.Combine(root, "Invented Show");
        var series = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Series,
            SourcePath = seriesPath,
            NormalizedSourcePath = MediaPath.Normalize(seriesPath),
            DetectedTitle = "Invented Show",
            Category = string.Empty,
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        };
        var episodePath = Path.Combine(seriesPath, "Invented Show S01E01.mkv");
        var episode = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Parent = series,
            ParentId = series.Id,
            Kind = MediaKind.Episode,
            SeasonNumber = 1,
            EpisodeNumber = 1,
            SourcePath = episodePath,
            NormalizedSourcePath = MediaPath.Normalize(episodePath),
            DetectedTitle = "Invented Show 1",
            Category = string.Empty,
            Extension = ".mkv",
            FileSize = 1,
            FileModifiedAt = now,
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        };
        database.MediaItems.AddRange(series, episode);
        database.MediaSegments.Add(new MediaSegment
        {
            MediaItemId = episode.Id,
            CreditsStartMilliseconds = 100_000,
            CreditsSource = MediaSegmentSource.Detected,
            CreditsConfidence = 0.9,
            AnalysisVersion = SegmentDetectionService.AnalysisVersion,
            AnalyzedFileSize = 1,
            AnalyzedFileModifiedAt = now,
            UpdatedAt = now,
        });
        await database.SaveChangesAsync();
        return episode.Id;
    }

    /// <summary>200 s of invented picture at two pictures a second and noise as sound.</summary>
    private static async Task EncodePicturesAsync(string ffmpeg, string path, int seed)
    {
        var start = new ProcessStartInfo(ffmpeg) { RedirectStandardInput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in new[]
        {
            "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "gray", "-s", "320x180", "-r", "2", "-i", "pipe:0",
            "-f", "lavfi", "-i", string.Create(System.Globalization.CultureInfo.InvariantCulture, $"anoisesrc=d=200:c=pink:seed={seed + 7}:a=0.1"),
            "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "8", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest", path,
        }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var errors = process.StandardError.ReadToEndAsync();
        for (var picture = 0; picture < 400; picture++)
        {
            var second = picture / 2;
            var frame = second < 170 ? SyntheticPictures.Scene(seed * 10_000 + second)
                : second < 195 ? (picture % 8 == 7 ? new byte[CreditsPictures.FrameBytes] : SyntheticPictures.Credits(seed * 100 + picture / 8))
                : SyntheticPictures.Scene(424_242);
            await process.StandardInput.BaseStream.WriteAsync(frame);
        }
        process.StandardInput.Close();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == 0, await errors);
    }

    [Fact]
    public void TheReaderAsksForOneShortStretchOfSoundOnStandardOutput()
    {
        var arguments = SegmentAudioReader.Arguments("/invented/episode.mkv", new ProbedAudio(2, "aac", null, 6, "eng", null, true), 1_200.5, 300);
        Assert.Equal("pipe:1", arguments[^1]);
        Assert.Equal(["-ss", "1200.5", "-t", "300", "-i", "file:/invented/episode.mkv", "-map", "0:2"],
            arguments.SkipWhile(argument => argument != "-ss").Take(8));
        Assert.Contains("s16le", arguments);
        Assert.Contains("-vn", arguments);
        Assert.DoesNotContain("-ss", SegmentAudioReader.Arguments("/invented/episode.mkv", new ProbedAudio(1, "aac", null, 2, null, null, true), 0, 300));
        // Only the input and standard output are named: no file is written.
        Assert.DoesNotContain(arguments, argument => argument.StartsWith('/') || argument.Contains("tmp", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void ChaptersAreReadFromTheHeaderDescription()
    {
        var probe = MediaProbe.Parse("""
            {"chapters":[{"start_time":"0.000000","end_time":"62.500000","tags":{"title":"Opening"}},
              {"start_time":"62.500000","end_time":"1300.000000"},{"start_time":"5","end_time":"2","tags":{"title":"Broken"}}],
             "streams":[],"format":{"format_name":"matroska,webm","duration":"1300.0"}}
            """);
        Assert.Equal([new ProbedChapter(0, 62.5, "Opening"), new ProbedChapter(62.5, 1300, null)], probe.Chapters);
        Assert.Contains("chapter=start_time,end_time", string.Join(' ', MediaProbe.Arguments("/invented.mkv")), StringComparison.Ordinal);
    }

    private static async Task<MediaSegmentsResponse> SegmentsAsync(HttpClient client, string token, Guid mediaId)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{mediaId}/segments", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<MediaSegmentsResponse>(response);
    }

    private static async Task<MediaSegmentSettingsResponse> SettingsAsync(HttpClient client, string token)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/media-segments", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<MediaSegmentSettingsResponse>(response);
    }

    private static async Task<PlaybackSourceResponse> PlaybackAsync(HttpClient client, string token, Guid mediaId)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{mediaId}/playback", token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<PlaybackSourceResponse>(response);
    }

    /// <summary>
    /// Four episodes of 200 s with only a sound track: a different opening scene each, the same
    /// 30 s theme, different scenes, the same 25 s of credits music, and after the last one a
    /// scene following the credits. The sound is generated here and encoded as AAC.
    /// </summary>
    private static async Task<string[]> MakeSeasonAsync(string ffmpeg, string root, (double Start, double End, string Title)[]? chapters)
    {
        var intro = SyntheticAudio.Music(seed: 31, seconds: IntroSeconds);
        var credits = SyntheticAudio.Music(seed: 32, seconds: CreditsSeconds);
        var paths = new string[ColdOpens.Length];
        for (var index = 0; index < paths.Length; index++)
        {
            var middle = EpisodeSeconds - ColdOpens[index] - IntroSeconds - CreditsSeconds - AfterCredits[index];
            var sound = SyntheticAudio.Join(
                SyntheticAudio.Music(seed: 3000 + index, seconds: ColdOpens[index]), intro,
                SyntheticAudio.Music(seed: 3100 + index, seconds: middle), credits,
                SyntheticAudio.Music(seed: 3200 + index, seconds: AfterCredits[index]));
            paths[index] = Path.Combine(root, $"Invented Series S01E0{index + 1}.mkv");
            await EncodeAsync(ffmpeg, sound, paths[index], index == 0 ? chapters : null);
        }
        return paths;
    }

    private static async Task EncodeAsync(string ffmpeg, short[] sound, string path, (double Start, double End, string Title)[]? chapters)
    {
        var start = new ProcessStartInfo(ffmpeg) { RedirectStandardInput = true, RedirectStandardError = true, UseShellExecute = false };
        var arguments = new List<string>
        {
            "-hide_banner", "-loglevel", "error", "-f", "s16le", "-ar", AudioFingerprint.SampleRate.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "-ac", "1", "-i", "pipe:0",
        };
        string? metadata = null;
        if (chapters is not null)
        {
            // The chapter list is an input of the test's own ffmpeg, kept outside the library folder.
            metadata = Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(path)!)!, "chapters.txt");
            await File.WriteAllTextAsync(metadata, ";FFMETADATA1\n" + string.Concat(chapters.Select(chapter => string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"[CHAPTER]\nTIMEBASE=1/1000\nSTART={(long)(chapter.Start * 1000)}\nEND={(long)(chapter.End * 1000)}\ntitle={chapter.Title}\n"))));
            arguments.AddRange(["-i", metadata, "-map_chapters", "1"]);
        }
        arguments.AddRange(["-map", "0:a", "-c:a", "aac", "-b:a", "96k", "-ar", "44100", path]);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var errors = process.StandardError.ReadToEndAsync();
        await process.StandardInput.BaseStream.WriteAsync(MemoryMarshal.AsBytes(sound.AsSpan()).ToArray());
        process.StandardInput.Close();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == 0, await errors);
        if (metadata is not null) File.Delete(metadata);
    }

    private static async Task<(Guid Series, Guid[] Episodes)> AddSeasonAsync(AureliaServerFactory factory, string root, string[] paths)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Invented Series Library",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.TvShows,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        var seriesPath = Path.Combine(root, "Invented Series");
        var series = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Series,
            SourcePath = seriesPath,
            NormalizedSourcePath = MediaPath.Normalize(seriesPath),
            DetectedTitle = "Invented Series",
            Category = string.Empty,
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        };
        database.MediaItems.Add(series);
        var episodes = paths.Select((path, index) => new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Parent = series,
            ParentId = series.Id,
            Kind = MediaKind.Episode,
            SeasonNumber = 1,
            EpisodeNumber = index + 1,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = $"Invented Episode {index + 1}",
            Category = string.Empty,
            Extension = Path.GetExtension(path),
            FileSize = new FileInfo(path).Length,
            FileModifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero),
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        }).ToArray();
        database.MediaItems.AddRange(episodes);
        await database.SaveChangesAsync();
        return (series.Id, [.. episodes.Select(episode => episode.Id)]);
    }

    private static string? Tools() =>
        Environment.GetEnvironmentVariable("AURELIA_TEST_FFMPEG") is { Length: > 0 } chosen ? chosen : null;

    private static string? Installed()
    {
        var directories = (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(Path.PathSeparator)
            .Concat(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]);
        return directories.Where(directory => directory.Length > 0)
            .Select(directory => Path.Combine(directory, "ffmpeg"))
            .FirstOrDefault(candidate => File.Exists(candidate) && File.Exists(Path.Combine(Path.GetDirectoryName(candidate)!, "ffprobe")));
    }

    private static AureliaServerFactory Factory(string ffmpeg) => new(configureServices: services =>
    {
        services.RemoveAll<LiveConversionService>();
        services.AddSingleton(provider => new LiveConversionService(
            new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Aurelia:Ffmpeg"] = ffmpeg }).Build(),
            provider.GetRequiredService<ServerRuntimeOptions>(),
            NullLogger<LiveConversionService>.Instance));
    });

    private static HashSet<string> Files(string directory) =>
        Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).ToHashSet(StringComparer.Ordinal);

    private static bool ServerBookkeeping(string dataDirectory, string file)
    {
        var relative = Path.GetRelativePath(dataDirectory, file);
        return relative.StartsWith("Backups" + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || relative.StartsWith("DataProtectionKeys" + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || relative.StartsWith("aurelia.db", StringComparison.Ordinal)
            || relative is "server-events.json" or "server.lock" or SegmentDetectionService.SettingsFileName;
    }

    private static HashSet<string> TemporaryVideoFiles() =>
        new[] { Path.GetTempPath(), "/tmp" }.Where(Directory.Exists)
            .SelectMany(directory => Directory.EnumerateFiles(directory))
            .Where(file => System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(file),
                @"ffmpeg|ffprobe|\.(mp4|m4s|m4v|mov|mkv|ts|aac|h264|hevc|pcm|wav|raw)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            .ToHashSet(StringComparer.Ordinal);
}
