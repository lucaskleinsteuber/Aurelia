using System.Diagnostics;
using System.Net;
using Tarven.Contracts;
using Tarven.Server.Data;
using Tarven.Server.Services;
using Tarven.Server.Services.Hls;
using Tarven.Server.Services.Speech;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Tarven.Server.Tests;

/// <summary>
/// Regression tests for P3 playback, HLS concurrency, preview limits, scrub previews, speech
/// pausing/model downloads, metadata refresh resume, and segment failure backoff
/// (audit SRV-PLAY-005..009, SRV-BG-009..013, SRV-LIB-008).
/// </summary>
public sealed class PlaybackAndBackgroundP3Tests
{
    [Fact]
    public async Task DisposingHlsSessionConcurrentlyThrowsSessionEndedWithoutLeakingSlots()
    {
        using var factory = new TarvenServerFactory();
        var live = factory.Services.GetRequiredService<LiveConversionService>();
        var streams = factory.Services.GetRequiredService<ActiveStreamRegistry>();
        var converter = new HoldingConverter();
        await using var manager = new HlsSessionManager(live, streams, NullLogger<HlsSessionManager>.Instance, converter: converter);

        var dir = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, "hls-race.mkv");
        await File.WriteAllBytesAsync(file, [0, 1, 2, 3]);
        try
        {
            var stream = File.OpenRead(file);
            var key = new HlsSessionKey(Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), "360p", 1);
            var video = new ProbedVideo(0, "h264", "High", 30, 640, 360, "yuv420p", 8);
            var quality = StreamingLadder.Find(video, null, "360p")!;
            var tools = new FfmpegTools("/invented/ffmpeg", "/invented/ffprobe", LiveVideoEncoder.Libx264) { HasSoftwareEncoder = true };
            var session = await manager.AddAsync(manager.Create(
                key, stream, stream, file, "Race", 40, quality, video,
                new ProbedAudio(1, "aac", null, 2, null, null, true), HdrToneMapping.Unavailable, tools));

            // Request a segment while DisposeAsync tears down the session concurrently.
            var requestTask = session.SegmentAsync(0, CancellationToken.None);
            await converter.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await manager.EndAsync(key);

            await Assert.ThrowsAsync<HlsSessionEndedException>(() => requestTask);
            // Calling InitAsync/SegmentAsync on an already-disposed session also throws HlsSessionEndedException, never ObjectDisposedException.
            await Assert.ThrowsAsync<HlsSessionEndedException>(() => session.InitAsync(CancellationToken.None));
            await Assert.ThrowsAsync<HlsSessionEndedException>(() => session.SegmentAsync(0, CancellationToken.None));

            // No video encoding slot may be leaked.
            Assert.False(live.VideoPlacesTaken);
            Assert.Equal(0, live.Running);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(file)!, recursive: true);
        }
    }

    [Fact]
    public async Task WhisperWaitForExitWithPauseSuspendsAndResumesChildProcess()
    {
        if (OperatingSystem.IsWindows()) return;

        var start = new ProcessStartInfo("/bin/sleep")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add("1");
        using var process = Process.Start(start)!;
        var paused = true;
        var transitions = new List<bool>();
        var waitTask = WhisperRecognizer.WaitForExitWithPauseAsync(
            process,
            shouldPause: () => Volatile.Read(ref paused),
            onPausedChanged: state => transitions.Add(state),
            pollInterval: TimeSpan.FromMilliseconds(50),
            CancellationToken.None);

        // Give the monitor time to suspend the process.
        await Task.Delay(200);
        Assert.Contains(true, transitions);
        Assert.False(process.HasExited);

        // Resume and let it complete cleanly.
        Volatile.Write(ref paused, false);
        await waitTask.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(process.HasExited);
        Assert.Contains(false, transitions);
    }

    [Fact]
    public async Task SpeechModelDownloadUsesUniquePartialsAndTimesOutOnStall()
    {
        var dir = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dir);
        try
        {
            var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", dir]);
            using var stallingHandler = new StallingHttpHandler();
            using var http = new HttpClient(stallingHandler) { Timeout = Timeout.InfiniteTimeSpan };
            var store = new SpeechModelStore(runtime, NullLogger<SpeechModelStore>.Instance, http, readInactivityTimeout: TimeSpan.FromMilliseconds(150));

            // Two rapid downloads must not fail by unlinking each other's .partial path; the second
            // one stalls and hits the inactivity timeout cleanly.
            store.StartDownload("base");
            store.StartDownload("base");

            var deadline = DateTimeOffset.UtcNow.AddSeconds(5);
            while (store.Download is not null && DateTimeOffset.UtcNow < deadline)
                await Task.Delay(25);

            Assert.Null(store.Download);
            Assert.NotNull(store.DownloadError);
            Assert.Contains("timed out", store.DownloadError, StringComparison.OrdinalIgnoreCase);

            var modelsDir = Path.Combine(dir, SpeechModelStore.FolderName);
            if (Directory.Exists(modelsDir))
                Assert.Empty(Directory.EnumerateFiles(modelsDir, "*.partial"));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task DeleteSpeechModelReturns409WhileSpeechJobIsRunning()
    {
        var blocking = new BlockingRecognizer();
        using var factory = new TarvenServerFactory(configureServices: services =>
        {
            services.RemoveAll<ISpeechRecognizer>();
            services.AddSingleton<ISpeechRecognizer>(blocking);
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        // Place a dummy model file so ModelReady is true.
        var modelsDir = Path.Combine(factory.DataDirectory, SpeechModelStore.FolderName);
        Directory.CreateDirectory(modelsDir);
        var modelPath = Path.Combine(modelsDir, "ggml-base.bin");
        await File.WriteAllBytesAsync(modelPath, [0x6c, 0x6d, 0x67, 0x67]);

        var mediaDir = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaDir);
        var mediaPath = Path.Combine(mediaDir, "SpeechTest.mkv");
        await File.WriteAllBytesAsync(mediaPath, [1, 2, 3, 4]);
        try
        {
            Guid mediaId;
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
                var now = DateTimeOffset.UtcNow;
                var library = new LibraryRoot
                {
                    Id = Guid.NewGuid(),
                    Name = "Speech Lib",
                    Path = mediaDir,
                    NormalizedPath = MediaPath.Normalize(mediaDir),
                    Kind = LibraryKind.Movies,
                    Availability = LibraryAvailability.Available,
                    CreatedAt = now,
                };
                var item = new MediaItem
                {
                    Id = Guid.NewGuid(),
                    LibraryRoot = library,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Movie,
                    SourcePath = mediaPath,
                    NormalizedSourcePath = MediaPath.Normalize(mediaPath),
                    DetectedTitle = "Speech Test",
                    Category = string.Empty,
                    Extension = ".mkv",
                    FileSize = 4,
                    FileModifiedAt = now,
                    Availability = MediaAvailability.Available,
                    CreatedAt = now,
                    UpdatedAt = now,
                };
                database.MediaItems.Add(item);
                await database.SaveChangesAsync();
                mediaId = item.Id;
            }

            // Start a speech job so HasActiveJobs is true, then try to delete the model.
            using (var startReq = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{mediaId}/speech", owner.Token,
                new StartSpeechJobRequest(SpeechJobKind.Create, "en", null, null)))
            using (var startRes = await ApiTestClient.SendAsync(client, startReq))
                startRes.EnsureSuccessStatusCode();

            using (var delReq = ApiTestClient.Authorized(HttpMethod.Delete, "/api/v1/server/speech/model", owner.Token))
            using (var delRes = await ApiTestClient.SendAsync(client, delReq))
            {
                Assert.Equal(HttpStatusCode.Conflict, delRes.StatusCode);
                var problem = await ApiTestClient.ReadAsync<ApiProblem>(delRes);
                Assert.Equal("speech_job_running", problem.Code);
            }
            Assert.True(File.Exists(modelPath));

            // Cancel job, then removal succeeds.
            using (var cancelReq = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/media/{mediaId}/speech", owner.Token))
            using (var cancelRes = await ApiTestClient.SendAsync(client, cancelReq))
                cancelRes.EnsureSuccessStatusCode();

            using (var delReq2 = ApiTestClient.Authorized(HttpMethod.Delete, "/api/v1/server/speech/model", owner.Token))
            using (var delRes2 = await ApiTestClient.SendAsync(client, delReq2))
                delRes2.EnsureSuccessStatusCode();
            Assert.False(File.Exists(modelPath));
        }
        finally
        {
            Directory.Delete(mediaDir, recursive: true);
        }
    }

    [Fact]
    public async Task ContentRatingAndCreditRefreshesResumeFromProgressWithoutRefetchingCompletedTitles()
    {
        var fakeTmdb = new FlakyTmdbClient();
        using var factory = new TarvenServerFactory(configureServices: services =>
        {
            services.RemoveAll<ITmdbClient>();
            services.AddSingleton<ITmdbClient>(fakeTmdb);
        });
        using var client = factory.CreateClient();
        _ = await ApiTestClient.SetupOwnerAsync(client);

        // Configure TMDB token so refresh runs.
        using (var scope = factory.Services.CreateScope())
        {
            var settingsStore = scope.ServiceProvider.GetRequiredService<MetadataProviderSettingsStore>();
            settingsStore.Save(new UpdateMetadataProviderRequest(true, "en-US", "test-tmdb-bearer-token-0123456789abcdef"));

            var database = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
            var now = DateTimeOffset.UtcNow;
            var libDir = TestPaths.CreateDataDirectory();
            Directory.CreateDirectory(libDir);
            var library = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Refresh Lib",
                Path = libDir,
                NormalizedPath = MediaPath.Normalize(libDir),
                Kind = LibraryKind.Movies,
                Availability = LibraryAvailability.Available,
                CreatedAt = now,
            };
            database.LibraryRoots.Add(library);
            for (var i = 1; i <= 3; i++)
            {
                var id = new Guid(i, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);
                var item = new MediaItem
                {
                    Id = id,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Movie,
                    SourcePath = Path.Combine(libDir, $"Movie{i}.mkv"),
                    NormalizedSourcePath = MediaPath.Normalize(Path.Combine(libDir, $"Movie{i}.mkv")),
                    DetectedTitle = $"Movie {i}",
                    Category = string.Empty,
                    Extension = ".mkv",
                    Availability = MediaAvailability.Available,
                    CreatedAt = now,
                    UpdatedAt = now,
                };
                database.MediaItems.Add(item);
                database.MediaMetadata.Add(new MediaMetadata
                {
                    MediaItemId = id,
                    Provider = "tmdb",
                    ProviderMediaId = i.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    ProviderMediaType = "movie",
                    ProviderTitle = $"Movie {i}",
                    UpdatedAt = now,
                });
            }
            await database.SaveChangesAsync();
        }

        // Fail on title "2" on the first run; title "1" succeeds and is recorded in progress.
        fakeTmdb.FailOnceForId = "2";
        var ratingRefresh = new ContentRatingRefresh(
            factory.Services.GetRequiredService<IServiceScopeFactory>(),
            factory.Services.GetRequiredService<ServerRuntimeOptions>(),
            NullLogger<ContentRatingRefresh>.Instance);

        Assert.False(await ratingRefresh.RunAsync(TimeSpan.Zero, CancellationToken.None));
        Assert.Equal(["1", "2"], fakeTmdb.RequestedIds);

        // Second run must skip title "1" and finish "2" and "3" without re-querying "1".
        Assert.True(await ratingRefresh.RunAsync(TimeSpan.Zero, CancellationToken.None));
        Assert.Equal(["1", "2", "2", "3"], fakeTmdb.RequestedIds);
        Assert.True(File.Exists(Path.Combine(factory.DataDirectory, ContentRatingRefresh.MarkerName)));
        Assert.False(File.Exists(Path.Combine(factory.DataDirectory, ContentRatingRefresh.MarkerName + ".progress")));

        // Verify CreditRefresh also resumes from progress without re-querying completed titles.
        fakeTmdb.RequestedIds.Clear();
        fakeTmdb.FailOnceForId = "3";
        var creditRefresh = new CreditRefresh(
            factory.Services.GetRequiredService<IServiceScopeFactory>(),
            factory.Services.GetRequiredService<ServerRuntimeOptions>(),
            NullLogger<CreditRefresh>.Instance);

        Assert.False(await creditRefresh.RunAsync(TimeSpan.Zero, CancellationToken.None));
        Assert.Equal(["1", "2", "3"], fakeTmdb.RequestedIds);

        Assert.True(await creditRefresh.RunAsync(TimeSpan.Zero, CancellationToken.None));
        Assert.Equal(["1", "2", "3", "3"], fakeTmdb.RequestedIds);
        Assert.True(File.Exists(Path.Combine(factory.DataDirectory, CreditRefresh.MarkerName)));
        Assert.False(File.Exists(Path.Combine(factory.DataDirectory, CreditRefresh.MarkerName + ".progress")));
    }

    [FfmpegFact]
    public async Task SegmentDetectionBacksOffOfflineEpisodesAndDoesNotRequeueOrCountPending()
    {
        var ffmpeg = FfmpegTestTools.RequireInstalled();
        var mediaDir = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaDir);
        try
        {
            using var factory = new TarvenServerFactory(configureServices: services =>
            {
                services.RemoveAll<LiveConversionService>();
                services.AddSingleton(provider => new LiveConversionService(
                    new ConfigurationBuilder()
                        .AddInMemoryCollection(new Dictionary<string, string?> { ["Tarven:Ffmpeg"] = ffmpeg })
                        .Build(),
                    provider.GetRequiredService<ServerRuntimeOptions>(),
                    NullLogger<LiveConversionService>.Instance));
            });
            using var client = factory.CreateClient();
            _ = await ApiTestClient.SetupOwnerAsync(client);

            var seriesId = Guid.NewGuid();
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
                var now = DateTimeOffset.UtcNow;
                var library = new LibraryRoot
                {
                    Id = Guid.NewGuid(),
                    Name = "Offline Season",
                    Path = mediaDir,
                    NormalizedPath = MediaPath.Normalize(mediaDir),
                    Kind = LibraryKind.TvShows,
                    Availability = LibraryAvailability.Available,
                    CreatedAt = now,
                };
                database.LibraryRoots.Add(library);
                var series = new MediaItem
                {
                    Id = seriesId,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Series,
                    SourcePath = mediaDir,
                    NormalizedSourcePath = MediaPath.Normalize(mediaDir),
                    DetectedTitle = "Missing Show",
                    Category = string.Empty,
                    Extension = string.Empty,
                    Availability = MediaAvailability.Available,
                    CreatedAt = now,
                    UpdatedAt = now,
                };
                database.MediaItems.Add(series);
                // Two episodes whose files do not exist on disk (offline/unreadable).
                for (var ep = 1; ep <= 2; ep++)
                {
                    var epPath = Path.Combine(mediaDir, $"Missing.S01E0{ep}.mkv");
                    database.MediaItems.Add(new MediaItem
                    {
                        Id = Guid.NewGuid(),
                        LibraryRootId = library.Id,
                        ParentId = seriesId,
                        Kind = MediaKind.Episode,
                        SeasonNumber = 1,
                        EpisodeNumber = ep,
                        SourcePath = epPath,
                        NormalizedSourcePath = MediaPath.Normalize(epPath),
                        DetectedTitle = $"Episode {ep}",
                        Category = string.Empty,
                        Extension = ".mkv",
                        FileSize = 1024,
                        FileModifiedAt = now,
                        Availability = MediaAvailability.Available,
                        CreatedAt = now,
                        UpdatedAt = now,
                    });
                }
                await database.SaveChangesAsync();
            }

            var detector = factory.Services.GetRequiredService<SegmentDetectionService>();
            Assert.Equal(1, await detector.QueuePendingSeasonsAsync(CancellationToken.None));
            Assert.Equal(0, await detector.ProcessPendingAsync(CancellationToken.None));

            // Subsequent scan must NOT re-queue the offline season or count its episodes as pending.
            Assert.Equal(0, await detector.QueuePendingSeasonsAsync(CancellationToken.None));
            var status = await detector.ReadSettingsAsync(CancellationToken.None);
            Assert.Equal(0, status.PendingCount);
        }
        finally
        {
            Directory.Delete(mediaDir, recursive: true);
        }
    }

    [Fact]
    public void BackgroundPriorityThreadScopeEntersAndRestoresCleanly()
    {
        var before = Thread.CurrentThread.Priority;
        using (BackgroundPriority.EnterCurrentThread())
        {
            // Entering background priority must not throw on macOS, Linux, or Windows.
        }
        Assert.Equal(before, Thread.CurrentThread.Priority);
    }

    [FfmpegFact]
    public async Task ClassicLiveVideoConversionPausesRunningConvertedDownloadSession()
    {
        var ffmpeg = FfmpegTestTools.RequireInstalled();
        var mediaDir = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaDir);
        var mediaPath = Path.Combine(mediaDir, "YieldTest.mkv");
        try
        {
            var start = new ProcessStartInfo(ffmpeg) { RedirectStandardError = true, UseShellExecute = false };
            foreach (var arg in new[]
            {
                "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "10",
                "-c:v", "libx264", "-preset", "ultrafast", "-g", "48", "-pix_fmt", "yuv420p", "-c:a", "aac", mediaPath,
            }) start.ArgumentList.Add(arg);
            using (var make = Process.Start(start)!)
            {
                var err = await make.StandardError.ReadToEndAsync();
                await make.WaitForExitAsync();
                Assert.True(make.ExitCode == 0, err);
            }

            var converter = new HoldingConverter();
            using var factory = new TarvenServerFactory(configureServices: services =>
            {
                services.RemoveAll<LiveConversionService>();
                services.AddSingleton(provider => new LiveConversionService(
                    new ConfigurationBuilder()
                        .AddInMemoryCollection(new Dictionary<string, string?> { ["Tarven:Ffmpeg"] = ffmpeg })
                        .Build(),
                    provider.GetRequiredService<ServerRuntimeOptions>(),
                    NullLogger<LiveConversionService>.Instance));
                services.RemoveAll<HlsSessionManager>();
                services.AddSingleton(provider => new HlsSessionManager(
                    provider.GetRequiredService<LiveConversionService>(),
                    provider.GetRequiredService<ActiveStreamRegistry>(),
                    NullLogger<HlsSessionManager>.Instance,
                    converter: converter));
            });
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            Guid mediaId;
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
                var now = DateTimeOffset.UtcNow;
                var library = new LibraryRoot
                {
                    Id = Guid.NewGuid(),
                    Name = "Yield Lib",
                    Path = mediaDir,
                    NormalizedPath = MediaPath.Normalize(mediaDir),
                    Kind = LibraryKind.Movies,
                    Availability = LibraryAvailability.Available,
                    CreatedAt = now,
                };
                var item = new MediaItem
                {
                    Id = Guid.NewGuid(),
                    LibraryRoot = library,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Movie,
                    SourcePath = mediaPath,
                    NormalizedSourcePath = MediaPath.Normalize(mediaPath),
                    DetectedTitle = "Yield Test",
                    Category = string.Empty,
                    Extension = ".mkv",
                    FileSize = new FileInfo(mediaPath).Length,
                    FileModifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(mediaPath), TimeSpan.Zero),
                    Availability = MediaAvailability.Available,
                    CreatedAt = now,
                    UpdatedAt = now,
                };
                database.MediaItems.Add(item);
                await database.SaveChangesAsync();
                mediaId = item.Id;
            }

            // Start a converted download session and occupy any remaining video slots (e.g. VideoToolbox has 2).
            var manager = factory.Services.GetRequiredService<HlsSessionManager>();
            var live = factory.Services.GetRequiredService<LiveConversionService>();
            var downloadStream = File.OpenRead(mediaPath);
            var video = new ProbedVideo(0, "h264", "High", 30, 640, 360, "yuv420p", 8);
            var quality = StreamingLadder.Find(video, null, "360p")!;
            var tools = (await live.ToolsAsync())!;
            var downloadSession = await manager.AddAsync(manager.Create(
                new HlsSessionKey(owner.User.Id, Guid.NewGuid(), mediaId, "360p", 1, Download: true),
                downloadStream, downloadStream, mediaPath, "Yield", 10, quality, video,
                new ProbedAudio(1, "aac", null, 2, null, null, true), HdrToneMapping.Unavailable, tools));
            var downloadTask = downloadSession.SegmentAsync(0, CancellationToken.None);
            await converter.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.True(downloadSession.IsProducing);
            var extraSlots = new List<IDisposable>();
            try
            {
                while (!live.VideoPlacesTaken)
                {
                    var extra = await live.EnterAsync(encodesVideo: true, CancellationToken.None);
                    if (extra is null) break;
                    extraSlots.Add(extra);
                }
                Assert.True(live.VideoPlacesTaken);

                // Classic /live?video=h264 viewer must pause the download session and stream 200 OK (audit SRV-PLAY-007).
                using var pbReq = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{mediaId}/playback", owner.Token);
                using var pbRes = await ApiTestClient.SendAsync(client, pbReq);
                pbRes.EnsureSuccessStatusCode();
                var playback = await ApiTestClient.ReadAsync<PlaybackSourceResponse>(pbRes);

                using (var liveReq = ApiTestClient.Authorized(HttpMethod.Get, $"{playback.StreamPath}/live?video=h264", owner.Token))
                using (var liveRes = await client.SendAsync(liveReq, HttpCompletionOption.ResponseHeadersRead))
                {
                    Assert.Equal(HttpStatusCode.OK, liveRes.StatusCode);
                    Assert.False(downloadSession.IsProducing);
                }
            }
            finally
            {
                foreach (var extra in extraSlots) extra.Dispose();
                await manager.DisposeAsync();
                try { await downloadTask; } catch (Exception) { }
            }
        }
        finally
        {
            Directory.Delete(mediaDir, recursive: true);
        }
    }

    private sealed class HoldingConverter : IHlsConverter
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public IHlsRun Start(HlsSession session, LiveStreamOptions options, Action<double> speed)
        {
            Started.TrySetResult();
            return new BlockingRun();
        }

        private sealed class BlockingRun : IHlsRun
        {
            private readonly BlockingStream output = new();
            public Stream Output => output;
            public Task<string> ErrorsAsync() => Task.FromResult(string.Empty);
            public int? ExitCode => null;
            public void Dispose() => output.Dispose();
        }

        private sealed class BlockingStream : Stream
        {
            private readonly TaskCompletionSource closed = new(TaskCreationOptions.RunContinuationsAsynchronously);
            public override bool CanRead => true;
            public override bool CanSeek => false;
            public override bool CanWrite => false;
            public override long Length => 0;
            public override long Position { get => 0; set => throw new NotSupportedException(); }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count) => 0;
            public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            {
                await closed.Task.WaitAsync(cancellationToken);
                return 0;
            }
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
            public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
            protected override void Dispose(bool disposing)
            {
                closed.TrySetResult();
                base.Dispose(disposing);
            }
        }
    }

    private sealed class StallingHttpHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StreamContent(new NeverEndingStream()),
            };
            response.Content.Headers.ContentLength = 1024;
            return Task.FromResult(response);
        }

        private sealed class NeverEndingStream : Stream
        {
            public override bool CanRead => true;
            public override bool CanSeek => false;
            public override bool CanWrite => false;
            public override long Length => 1024;
            public override long Position { get => 0; set => throw new NotSupportedException(); }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count) => 0;
            public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                return 0;
            }
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
            public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        }
    }

    private sealed class BlockingRecognizer : ISpeechRecognizer
    {
        public bool Available => true;
        public async Task<IReadOnlyList<SpeechWord>> RecognizeAsync(short[] samples, string language, string modelPath, CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return [];
        }
    }

    private sealed class FlakyTmdbClient : ITmdbClient
    {
        public List<string> RequestedIds { get; } = [];
        public string? FailOnceForId { get; set; }

        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(string token, string language, MediaKind kind, string title, int? year, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<MetadataCandidateSummary>>([]);

        public Task<TmdbMetadata> GetAsync(string token, string language, string mediaType, string providerId, CancellationToken cancellationToken)
        {
            RequestedIds.Add(providerId);
            if (FailOnceForId == providerId)
            {
                FailOnceForId = null;
                throw new MetadataProviderException("TMDB temporary failure", transient: true);
            }
            return Task.FromResult(new TmdbMetadata(
                providerId,
                mediaType,
                $"Title {providerId}",
                null,
                null,
                "2024-01-01",
                120,
                7.5,
                "PG-13",
                [],
                [],
                [],
                null,
                null,
                [],
                null,
                []));
        }

        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(string token, string language, string seriesProviderId, int seasonNumber, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>([]);

        public Task<byte[]> DownloadImageAsync(string token, string providerPath, string size, CancellationToken cancellationToken) =>
            Task.FromResult(Array.Empty<byte>());
    }
}
