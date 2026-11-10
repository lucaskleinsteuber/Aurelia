using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Aurelia.Server.Services.Hls;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// Adaptive streaming: the box reader, the in-memory segment window, the playlists and the
/// sessions with invented ffmpeg output, then with an installed ffmpeg the real HLS stream of an
/// invented MKV, which must leave no file anywhere.
/// </summary>
public sealed partial class LiveConversionTests
{
    private static readonly ProbedVideo SmallPicture = new(0, "h264", "High", 30, 640, 360, "yuv420p", 8);

    [Fact]
    public async Task TheBoxReaderSplitsInitAndFragmentsAndPlacesThemInTitleTime()
    {
        var init = InventedInit(timescale: 12_800);
        var parsed = Fmp4.ParseInit(MakeBox("ftyp", Encoding.ASCII.GetBytes("isom\0\0\x02\0")), init);
        Assert.Equal((1u, 12_800u), (parsed.VideoTrackId, parsed.Timescale));
        Assert.Equal("ftyp", Encoding.ASCII.GetString(parsed.Data, 4, 4));
        Assert.NotEmpty(parsed.Descriptions);

        Assert.Equal(48.0, Fmp4.FragmentStart(InventedMoof(48 * 12_800L, version1: true), parsed));
        Assert.Equal(4.0, Fmp4.FragmentStart(InventedMoof(4 * 12_800L, version1: false), parsed));
        Assert.Null(Fmp4.FragmentStart(InventedMoof(0, version1: false, track: 2), parsed));

        using var stream = new MemoryStream([.. MakeBox("ftyp", [1, 2, 3, 4]), .. LargeBox("mdat", [9, 9])]);
        Assert.Equal("ftyp", (await Fmp4.ReadBoxAsync(stream, default))!.Type);
        var large = (await Fmp4.ReadBoxAsync(stream, default))!;
        Assert.Equal(("mdat", 18), (large.Type, large.Data.Length));
        Assert.Null(await Fmp4.ReadBoxAsync(stream, default));

        await Assert.ThrowsAsync<InvalidDataException>(() => Fmp4.ReadBoxAsync(new MemoryStream(MakeBox("mdat", new byte[64])[..40]), default));
        await Assert.ThrowsAsync<InvalidDataException>(() => Fmp4.ReadBoxAsync(new MemoryStream(MakeBox("mdat", new byte[64])), default, maximumBytes: 32));
        await Assert.ThrowsAsync<InvalidDataException>(() => Fmp4.ReadBoxAsync(new MemoryStream([0, 0, 0, 4, 0x6d, 0x64, 0x61, 0x74]), default));
        Assert.Throws<InvalidDataException>(() => Fmp4.ParseInit([], MakeBox("moov", [])));
    }

    [Fact]
    public void TheSegmentWindowKeepsWhatThePlayerNeedsAndDecidesBetweenWaitingAndSeeking()
    {
        var store = new SegmentStore(maximumBytes: 1000, ahead: 4, behind: 1);
        Assert.Equal(SegmentPlan.Restart, store.Request(0));
        store.BeginProducing(0);
        Assert.Equal(SegmentPlan.Wait, store.Request(0));
        store.Add(0, new byte[10]);
        store.Add(0, new byte[5]);
        Assert.Null(store.TryGet(0));             // still being written
        store.Add(1, new byte[10]);
        Assert.Equal(15, store.TryGet(0)!.Length); // both fragments, joined
        Assert.Equal(SegmentPlan.Ready, store.Request(0));
        Assert.Equal(SegmentPlan.Wait, store.Request(4));    // within reach of the conversion
        Assert.Equal(SegmentPlan.Restart, store.Request(30)); // a seek

        store.Request(1);
        for (var index = 2; index <= 6; index++) store.Add(index, new byte[10]);
        Assert.True(store.ShouldPause);  // more than four ahead of the player
        store.Request(4);
        Assert.False(store.ShouldPause);
        Assert.Null(store.TryGet(0));    // more than one behind the player is gone
        Assert.NotNull(store.TryGet(3));

        store.EndProducing(finished: true);
        Assert.Equal(SegmentPlan.Ready, store.Request(6));
        Assert.Null(store.Producing);

        store.BeginProducing(20);
        store.Add(20, new byte[700]);
        store.Add(21, new byte[700]);    // over the cap: the farthest ahead goes, never the open segment
        Assert.True(store.Bytes <= 1000 + 700);
        store.EndProducing(finished: false);
        Assert.Null(store.TryGet(21));   // an unfinished segment is dropped
        store.Clear();
        Assert.Equal(0, store.Bytes);
    }

    [Fact]
    public void PlaylistsListEveryQualityAndFourSecondSegmentsWithRelativeAddresses()
    {
        var steps = StreamingLadder.For(SmallPicture with { Width = 1920, Height = 1080 }).Take(2).ToList();
        Assert.Equal("""
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-STREAM-INF:BANDWIDTH=12160000,AVERAGE-BANDWIDTH=8160000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
            1080p/index.m3u8?audio=2
            #EXT-X-STREAM-INF:BANDWIDTH=6160000,AVERAGE-BANDWIDTH=4160000,RESOLUTION=1280x720,CODECS="avc1.64001F,mp4a.40.2"
            720p/index.m3u8?audio=2

            """.ReplaceLineEndings("\n"), HlsPlaylists.Master(steps, 2));
        Assert.Equal("""
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:4.000,
            0.m4s
            #EXTINF:4.000,
            1.m4s
            #EXTINF:2.500,
            2.m4s
            #EXT-X-ENDLIST

            """.ReplaceLineEndings("\n"), HlsPlaylists.Media(10.5, null));
        Assert.Equal(5, HlsPlaylists.SegmentCount(20));
        Assert.Equal(0, HlsPlaylists.SegmentCount(0));
        Assert.Equal(43_200, HlsPlaylists.SegmentCount(1e9));
        Assert.Equal(1, HlsPlaylists.SegmentFor(3.97));
        Assert.Equal(1, HlsPlaylists.SegmentFor(7.9));
        Assert.Equal(0, HlsPlaylists.SegmentFor(-1));
    }

    [Fact]
    public async Task ASessionConvertsOnDemandSeeksByStartingAgainAndEndsWhenIdle()
    {
        using var factory = Factory("off");
        var clock = new SteppingClock();
        var converter = new InventedConverter();
        await using var manager = Manager(factory, converter, clock);
        await using var opened = Session(manager, "360p", out var session);
        session = await manager.AddAsync(session);

        Assert.NotNull(await session.InitAsync(default));
        var first = await session.SegmentAsync(0, default);
        Assert.Equal(0.0, FragmentSeconds(first!));
        Assert.Equal(4.0, FragmentSeconds((await session.SegmentAsync(1, default))!));
        Assert.Equal([0], converter.Starts.Select(start => start.Segment));

        var later = await session.SegmentAsync(40, default);
        Assert.Equal(160.0, FragmentSeconds(later!));
        Assert.Equal([0, 40], converter.Starts.Select(start => start.Segment));
        Assert.All(converter.Starts, start => Assert.Equal((LiveVideoEncoder.Libx264, 4), (start.Options.Encoder!.Value, start.Options.SegmentSeconds!.Value)));
        Assert.Equal(360, converter.Starts[0].Options.Step!.Height);
        Assert.Null(await session.SegmentAsync(50, default)); // beyond the title

        clock.Advance(TimeSpan.FromSeconds(59));
        await manager.SweepAsync();
        Assert.Equal(1, manager.Count);
        clock.Advance(TimeSpan.FromSeconds(2));
        await manager.SweepAsync();
        Assert.Equal(0, manager.Count);
        Assert.False(session.IsProducing);
        Assert.Equal(0, session.Store.Bytes);
    }

    [Fact]
    public async Task AnotherQualityMakesTheFirstYieldAndRevokingTheProfileSessionEndsBoth()
    {
        using var factory = Factory("off");
        var converter = new InventedConverter { SegmentsPerRun = 40 };
        await using var manager = Manager(factory, converter, new SteppingClock());
        var profileSession = Guid.NewGuid();
        await using var firstFile = Session(manager, "720p", out var first, profileSession);
        await using var secondFile = Session(manager, "480p", out var second, profileSession);
        first = await manager.AddAsync(first);
        second = await manager.AddAsync(second);

        converter.Hold = true;
        var waiting = first.SegmentAsync(0, default);
        await WaitUntilAsync(() => first.IsProducing);
        converter.Hold = false;
        Assert.NotNull(await waiting);
        Assert.NotNull(await second.SegmentAsync(0, default));
        Assert.False(first.IsProducing);

        factory.Services.GetRequiredService<ActiveStreamRegistry>().RevokeSession(profileSession);
        await WaitUntilAsync(() => manager.Count == 0);
    }

    [Fact]
    public async Task AFailingChipHandsTheTitleToTheProcessorAndRestsForAWhile()
    {
        using var factory = Factory("off");
        var converter = new InventedConverter { FailsOnChip = true };
        await using var manager = Manager(factory, converter, new SteppingClock());
        var chip = new HardwareEncoder(LiveVideoEncoder.Vaapi, "/dev/dri/renderD128", true);
        var tools = new FfmpegTools("/invented/ffmpeg", "/invented/ffprobe", LiveVideoEncoder.Vaapi) { Hardware = chip, HasSoftwareEncoder = true };
        await using var opened = Session(manager, "360p", out var session, tools: tools);
        session = await manager.AddAsync(session);
        var live = factory.Services.GetRequiredService<LiveConversionService>();

        Assert.NotNull(await session.SegmentAsync(0, default));
        Assert.Equal([LiveVideoEncoder.Vaapi, LiveVideoEncoder.Libx264], converter.Starts.Select(start => start.Options.Encoder!.Value));
        Assert.True(live.Health.IsResting);
        Assert.Equal(LiveVideoEncoder.Libx264, session.Encoder);
    }

    [Fact]
    public async Task SixSessionsAtMostAndAConversionThatNeverWorksGivesUp()
    {
        using var factory = Factory("off");
        var converter = new InventedConverter { AlwaysFails = true };
        await using var manager = Manager(factory, converter, new SteppingClock());
        var files = new List<IAsyncDisposable>();
        try
        {
            for (var index = 0; index < HlsSessionManager.MaximumSessions; index++)
            {
                files.Add(Session(manager, "360p", out var session));
                await manager.AddAsync(session);
            }
            files.Add(Session(manager, "360p", out var extra));
            await Assert.ThrowsAsync<HlsBusyException>(() => manager.AddAsync(extra));

            var failing = manager.Sessions[0];
            Assert.Null(await failing.SegmentAsync(0, default));
            Assert.Null(await failing.InitAsync(default));
            Assert.InRange(converter.Starts.Count, 1, 3);
        }
        finally
        {
            foreach (var file in files) await file.DisposeAsync();
        }
    }

    [Fact]
    public async Task AnInventedMkvStreamsOverHlsInMemoryWithoutWritingFiles()
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Adaptive Streaming");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "Invented Film.mkv");
        try
        {
            await MakeMediaAsync(maker, path);
            var before = (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length);
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path);
            var live = factory.Services.GetRequiredService<LiveConversionService>();
            var sessions = factory.Services.GetRequiredService<HlsSessionManager>();

            using (var capabilities = await client.GetAsync("/api/v1/capabilities"))
                Assert.Contains(ServerFeatures.AdaptiveStreaming, (await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities)).Capabilities);
            var playback = await CreatePlaybackAsync(client, owner.Token, mediaId);
            var hls = $"{playback.StreamPath}/hls";
            var dataFiles = Files(factory.DataDirectory);
            var temporaryFiles = TemporaryVideoFiles();

            var master = await ReadTextAsync(client, owner.Token, $"{hls}/master.m3u8", HlsPlaylists.ContentType);
            Assert.Contains("RESOLUTION=640x360", master, StringComparison.Ordinal);
            Assert.Contains("360p/index.m3u8?audio=1", master, StringComparison.Ordinal);
            var media = await ReadTextAsync(client, owner.Token, $"{hls}/360p/index.m3u8?audio=1", HlsPlaylists.ContentType);
            Assert.Equal(5, media.Split('\n').Count(line => line.EndsWith(".m4s?audio=1", StringComparison.Ordinal)));

            var init = await ReadStreamAsync(client, owner.Token, $"{hls}/360p/init.mp4?audio=1");
            Assert.Equal(["ftyp", "moov"], TopLevelBoxes(init).Select(box => box.Type));
            var last = await ReadStreamAsync(client, owner.Token, $"{hls}/360p/4.m4s?audio=1");
            var first = await ReadStreamAsync(client, owner.Token, $"{hls}/360p/0.m4s?audio=1");
            var second = await ReadStreamAsync(client, owner.Token, $"{hls}/360p/1.m4s?audio=1");
            Assert.InRange(FirstFragmentSeconds([.. init, .. first]), 0, 0.1);
            Assert.InRange(FirstFragmentSeconds([.. init, .. second]), 3.9, 4.1);
            Assert.InRange(FirstFragmentSeconds([.. init, .. last]), 15.9, 16.1);
            // Each segment begins with a key frame and decodes with the one init segment.
            foreach (var segment in new[] { first, second, last })
                Assert.Equal("1", await FirstFrameIsKeyAsync(maker, [.. init, .. segment]));

            using (var outside = ApiTestClient.Authorized(HttpMethod.Get, $"{hls}/360p/5.m4s?audio=1", owner.Token))
            using (var missing = await client.SendAsync(outside))
                Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
            using (var wrong = ApiTestClient.Authorized(HttpMethod.Get, $"{hls}/2160p/index.m3u8", owner.Token))
            using (var notOffered = await client.SendAsync(wrong))
                Assert.Equal(HttpStatusCode.NotFound, notOffered.StatusCode);
            using (var odd = ApiTestClient.Authorized(HttpMethod.Get, $"{hls}/..%2F..%2Findex.m3u8", owner.Token))
            using (var refused = await client.SendAsync(odd))
                Assert.Equal(HttpStatusCode.NotFound, refused.StatusCode);
            using (var anonymous = await client.GetAsync($"{hls}/master.m3u8"))
                Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);

            // The media rule: nothing converted lands in the data folder, the temporary folder or the media folder.
            var newDataFiles = Files(factory.DataDirectory).Except(dataFiles).Where(file => !ServerBookkeeping(factory.DataDirectory, file)).ToList();
            Assert.True(newDataFiles.Count == 0, string.Join(", ", newDataFiles));
            Assert.Empty(TemporaryVideoFiles().Except(temporaryFiles));
            Assert.Equal([path], Directory.GetFiles(root));
            Assert.Empty(Directory.EnumerateFileSystemEntries(Path.Combine(factory.DataDirectory, "Converter")));
            Assert.Equal(before, (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length));

            using (var revoke = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/playback/{playback.Id}", owner.Token))
            using (var revoked = await ApiTestClient.SendAsync(client, revoke))
                revoked.EnsureSuccessStatusCode();
            using (var stale = ApiTestClient.Authorized(HttpMethod.Get, $"{hls}/360p/0.m4s?audio=1", owner.Token))
            using (var gone = await client.SendAsync(stale))
                Assert.Equal(HttpStatusCode.NotFound, gone.StatusCode);

            Assert.Equal(1, sessions.Count);
            await sessions.DisposeAsync();
            Assert.Equal(0, sessions.Count);
            await WaitUntilAsync(() => live.Running == 0);
        }
        finally { Directory.Delete(Path.GetDirectoryName(root)!, recursive: true); }
    }

    private static async Task<string> ReadTextAsync(HttpClient client, string token, string address, string contentType)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, address, token);
        using var response = await client.SendAsync(request);
        var text = await response.Content.ReadAsStringAsync();
        Assert.True(response.StatusCode == HttpStatusCode.OK, text);
        Assert.Equal(contentType, response.Content.Headers.ContentType?.MediaType);
        Assert.Contains("no-store", response.Headers.CacheControl?.ToString(), StringComparison.Ordinal);
        return text;
    }

    /// <summary>ffprobe's key-frame flag of the first picture in the bytes, read from its standard input.</summary>
    private static async Task<string> FirstFrameIsKeyAsync(string ffmpeg, byte[] data)
    {
        var start = new ProcessStartInfo(Path.Combine(Path.GetDirectoryName(ffmpeg)!, "ffprobe"))
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var argument in new[]
        {
            "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=key_frame", "-read_intervals", "%+#1", "-of", "csv=p=0", "pipe:0",
        }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        await process.StandardInput.BaseStream.WriteAsync(data);
        process.StandardInput.Close();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == 0, await errors);
        return (await output).Split('\n')[0].Trim().TrimEnd(',');
    }

    private static HlsSessionManager Manager(AureliaServerFactory factory, IHlsConverter converter, TimeProvider clock) =>
        new(factory.Services.GetRequiredService<LiveConversionService>(), factory.Services.GetRequiredService<ActiveStreamRegistry>(),
            NullLogger<HlsSessionManager>.Instance, clock, converter);

    /// <summary>A session over an invented 200-second title in a file of its own; the returned owner deletes the file.</summary>
    private static InventedFile Session(HlsSessionManager manager, string step, out HlsSession session, Guid? profileSession = null, FfmpegTools? tools = null)
    {
        var file = new InventedFile();
        var quality = StreamingLadder.Find(SmallPicture with { Width = 1920, Height = 1080 }, null, step)!;
        var key = new HlsSessionKey(Guid.NewGuid(), profileSession ?? Guid.NewGuid(), Guid.Empty, step, 1);
        if (profileSession is not null) key = key with { UserId = Guid.Empty };
        session = manager.Create(key, file.Stream, file.Stream, file.Path, "Invented", 200, quality, SmallPicture,
            new ProbedAudio(1, "aac", null, 2, null, null, true), HdrToneMapping.Unavailable,
            tools ?? new FfmpegTools("/invented/ffmpeg", "/invented/ffprobe", LiveVideoEncoder.Libx264) { HasSoftwareEncoder = true });
        return file;
    }

    private sealed class InventedFile : IAsyncDisposable
    {
        public InventedFile()
        {
            var directory = TestPaths.CreateDataDirectory();
            Directory.CreateDirectory(directory);
            Path = System.IO.Path.Combine(directory, "invented.mkv");
            File.WriteAllBytes(Path, [1, 2, 3]);
            Stream = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read);
        }

        public string Path { get; }
        public FileStream Stream { get; }

        public async ValueTask DisposeAsync()
        {
            await Stream.DisposeAsync();
            Directory.Delete(System.IO.Path.GetDirectoryName(Path)!, recursive: true);
        }
    }

    /// <summary>Writes an invented init segment and a fragment per segment from where it starts, as ffmpeg would.</summary>
    private sealed class InventedConverter : IHlsConverter
    {
        public List<(int Segment, LiveStreamOptions Options)> Starts { get; } = [];
        public int SegmentsPerRun { get; init; } = 8;
        public bool FailsOnChip { get; init; }
        public bool AlwaysFails { get; init; }
        public volatile bool Hold;

        public IHlsRun Start(HlsSession session, LiveStreamOptions options, Action<double> speed)
        {
            var segment = (int)Math.Round(options.Start / HlsPlaylists.SegmentSeconds);
            lock (Starts) Starts.Add((segment, options));
            if (AlwaysFails || (FailsOnChip && options.Hardware is not null)) return new Run(new MemoryStream(), 1);
            var output = new MemoryStream();
            output.Write(MakeBox("ftyp", Encoding.ASCII.GetBytes("isom\0\0\x02\0")));
            output.Write(InventedInit(timescale: 1000));
            for (var index = segment; index < Math.Min(segment + SegmentsPerRun, session.SegmentCount); index++)
            {
                output.Write(InventedMoof(index * 4000L, version1: false));
                output.Write(MakeBox("mdat", new byte[256]));
            }
            output.Position = 0;
            speed(4.5);
            return new Run(Hold ? new HeldStream(output, this) : output, null);
        }

        private sealed class Run(Stream output, int? exit) : IHlsRun
        {
            public Stream Output => output;
            public int? ExitCode => exit;
            public Task<string> ErrorsAsync() => Task.FromResult(exit is null ? string.Empty : "invented failure");
            public void Dispose() => output.Dispose();
        }

        /// <summary>Gives nothing until the test lets go, like an ffmpeg still starting.</summary>
        private sealed class HeldStream(Stream inner, InventedConverter owner) : Stream
        {
            public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            {
                while (owner.Hold) await Task.Delay(10, cancellationToken);
                return await inner.ReadAsync(buffer, cancellationToken);
            }

            public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
            public override bool CanRead => true;
            public override bool CanSeek => false;
            public override bool CanWrite => false;
            public override long Length => throw new NotSupportedException();
            public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
            public override void Flush() { }
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
            public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
            protected override void Dispose(bool disposing)
            {
                if (disposing) inner.Dispose();
                base.Dispose(disposing);
            }
        }
    }

    private sealed class SteppingClock : TimeProvider
    {
        private DateTimeOffset now = new(2026, 11, 10, 21, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan by) => now += by;
    }

    /// <summary>The start of the first fragment in invented output, whose picture track counts in milliseconds.</summary>
    private static double FragmentSeconds(byte[] segment)
    {
        var init = Fmp4.ParseInit([], InventedInit(timescale: 1000));
        var moofSize = (int)BinaryPrimitives.ReadUInt32BigEndian(segment);
        return Fmp4.FragmentStart(segment[..moofSize], init)!.Value;
    }

    private static byte[] MakeBox(string type, byte[] payload)
    {
        var box = new byte[8 + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(box, (uint)box.Length);
        Encoding.ASCII.GetBytes(type, box.AsSpan(4));
        payload.CopyTo(box, 8);
        return box;
    }

    private static byte[] LargeBox(string type, byte[] payload)
    {
        var box = new byte[16 + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(box, 1);
        Encoding.ASCII.GetBytes(type, box.AsSpan(4));
        BinaryPrimitives.WriteUInt64BigEndian(box.AsSpan(8), (ulong)box.Length);
        payload.CopyTo(box, 16);
        return box;
    }

    private static byte[] FullBox(string type, byte version, byte[] payload) => MakeBox(type, [version, 0, 0, 0, .. payload]);

    private static byte[] U32(uint value)
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(bytes, value);
        return bytes;
    }

    private static byte[] U64(ulong value)
    {
        var bytes = new byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(bytes, value);
        return bytes;
    }

    /// <summary>A moov with a picture track (id 1) and a sound track (id 2).</summary>
    private static byte[] InventedInit(uint timescale)
    {
        byte[] Track(uint id, string handler, uint scale, byte[] description) => MakeBox("trak", [
            .. FullBox("tkhd", 0, [.. U32(0), .. U32(0), .. U32(id), .. new byte[72]]),
            .. MakeBox("mdia", [
                .. FullBox("mdhd", 0, [.. U32(0), .. U32(0), .. U32(scale), .. U32(0), 0x55, 0xc4, 0, 0]),
                .. FullBox("hdlr", 0, [.. U32(0), .. Encoding.ASCII.GetBytes(handler), .. new byte[13]]),
                .. MakeBox("minf", MakeBox("stbl", FullBox("stsd", 0, [.. U32(1), .. description]))),
            ]),
        ]);
        return MakeBox("moov", [
            .. FullBox("mvhd", 0, new byte[96]),
            .. Track(2, "soun", 48_000, MakeBox("mp4a", new byte[20])),
            .. Track(1, "vide", timescale, MakeBox("avc1", new byte[24])),
        ]);
    }

    private static byte[] InventedMoof(long time, bool version1, uint track = 1) => MakeBox("moof", [
        .. FullBox("mfhd", 0, U32(1)),
        .. MakeBox("traf", [
            .. FullBox("tfhd", 0, U32(track)),
            .. (version1 ? FullBox("tfdt", 1, U64((ulong)time)) : FullBox("tfdt", 0, U32((uint)time))),
        ]),
    ]);
}
