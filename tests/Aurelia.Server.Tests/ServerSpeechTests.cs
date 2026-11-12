using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Runtime.InteropServices;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Aurelia.Server.Services.Speech;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// Speech recognition on the server: the subtitle rules, whisper.cpp's output, Sync to Speech and
/// a whole job through the real server and ffmpeg with an invented recognizer (no real model).
/// </summary>
[Collection(LiveConversionRuns.Name)]
public sealed class ServerSpeechTests
{
    [Fact]
    public void WordsBecomeSubtitlesWithTheMacsRules()
    {
        SpeechWord[] words =
        [
            new("Where", 1.0, 1.3), new("were", 1.35, 1.5), new("you", 1.55, 1.8), new("last", 1.85, 2.1), new("night?", 2.15, 2.5),
            new("At", 4.0, 4.1), new("home,", 4.15, 4.5), new("watching", 4.55, 4.9), new("the", 4.95, 5.0), new("whole", 5.05, 5.3),
            new("season", 5.35, 5.7), new("again", 5.75, 6.0), new("with", 6.05, 6.2), new("everyone.", 6.25, 6.7),
        ];
        var cues = SubtitleCueBuilder.Cues(words);
        Assert.Equal(2, cues.Count);
        Assert.Equal(["Where were you last night?"], cues[0].Lines);
        Assert.Equal(2.9, cues[0].End, 3);
        Assert.Equal(2, cues[1].Lines.Count);
        Assert.Equal("At home, watching the whole", cues[1].Lines[0]);
        Assert.Equal(["So we waited outside,", "the rain kept falling all night long"], SubtitleCueBuilder.Lines("So we waited outside, the rain kept falling all night long"));
        var subRip = SubtitleCueBuilder.SubRip(cues);
        Assert.StartsWith("1\n00:00:01,000 --> 00:00:02,900\nWhere were you last night?\n\n2\n00:00:04,000 -->", subRip, StringComparison.Ordinal);
        Assert.Equal("01:02:03,450", SubtitleCueBuilder.Timestamp(3723.45));
    }

    [Fact]
    public void WhisperOutputBecomesWordsAndSoundGoesInAsWav()
    {
        const string output = "[00:00:01.000 --> 00:00:01.400]   Hello\n[00:00:01.400 --> 00:00:01.420]  ,\n[00:00:01.500 --> 00:00:01.900]   world\n"
            + "[00:00:02.000 --> 00:00:04.000]   [Music]\nwhisper_print_timings: total time\n[00:01:00,250 --> 00:01:00,750]  again\n";
        var words = WhisperRecognizer.Parse(output);
        Assert.Equal(["Hello,", "world", "again"], words.Select(word => word.Text));
        Assert.Equal(60.25, words[2].Start, 3);
        var wav = WhisperRecognizer.Wav(new short[] { 1, -2, 3 });
        Assert.Equal(50, wav.Length);
        Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(wav, 0, 4));
        Assert.Equal(16_000, BitConverter.ToInt32(wav, 24));
        Assert.Equal(-2, BitConverter.ToInt16(wav, 46));
        var arguments = WhisperRecognizer.Arguments("/models/ggml-base.bin", "de", 3);
        Assert.Equal(["-m", "/models/ggml-base.bin", "-f", "-", "-l", "de", "-t", "3", "-ml", "1", "-sow", "-np"], arguments);
    }

    private static (List<TimeSpan2> Speech, List<TimeSpan2> Cues) Dialogue(double shift, double scale = 1, int seed = 3)
    {
        var random = new Random(seed);
        var speech = new List<TimeSpan2>();
        var at = 5.0;
        while (at < 2400)
        {
            var length = 0.8 + random.NextDouble() * 3;
            speech.Add(new TimeSpan2(at, at + length));
            at += length + 0.5 + random.NextDouble() * 6;
        }
        var cues = speech.Select(span => new TimeSpan2((span.Start - shift) / scale, (span.End + 0.3 - shift) / scale)).Where(cue => cue.Start >= 0).ToList();
        return (speech, cues);
    }

    [Fact]
    public void SyncFindsAnOffsetAndLeavesFittingSubtitlesAlone()
    {
        var (speech, late) = Dialogue(shift: 3.2);
        var shifted = SubtitleSync.Find(speech, late);
        Assert.Equal(SubtitleSyncVerdict.Shifted, shifted.Verdict);
        Assert.InRange(shifted.Timing.Segments[0].Offset, 3.0, 3.4);
        Assert.Equal(1, shifted.Timing.Scale);
        Assert.True(shifted.FitAfter > shifted.FitBefore);
        Assert.Contains("later", SubtitleSync.Summary(shifted), StringComparison.Ordinal);

        var (speech2, fitting) = Dialogue(shift: 0);
        Assert.Equal(SubtitleSyncVerdict.AlreadyInSync, SubtitleSync.Find(speech2, fitting).Verdict);

        var (_, other) = Dialogue(shift: 0, seed: 99);
        Assert.Equal(SubtitleSyncVerdict.NoMatch, SubtitleSync.Find(speech, other).Verdict);
    }

    [Fact]
    public void SyncCorrectsSubtitlesMadeForAnotherFrameRate()
    {
        var (speech, cues) = Dialogue(shift: 1.5, scale: 25 / 23.976);
        var result = SubtitleSync.Find(speech, cues);
        Assert.Equal(SubtitleSyncVerdict.Shifted, result.Verdict);
        Assert.Equal(25 / 23.976, result.Timing.Scale, 6);
    }

    [Fact]
    public void WebVttBecomesCuesWithoutVoiceTags()
    {
        var cues = SubtitleText.Cues("WEBVTT\n\n00:00:01.000 --> 00:00:02.500 align:start\n<v Anna>Hi <i>there</i></v>\n\n02:03.450 --> 02:04.000\nTom &amp; Jerry\n");
        Assert.Equal(2, cues.Count);
        Assert.Equal(["Hi <i>there</i>"], cues[0].Lines);
        Assert.Equal(123.45, cues[1].Start, 3);
        Assert.Equal(["Tom & Jerry"], cues[1].Lines);
    }

    [Fact]
    public void SoundIsHandedOverInStretchesCutAtAQuietMoment()
    {
        var chunker = new SpeechChunker(chunk: 1000, search: 400, sampleRate: 1000);
        var loud = Enumerable.Repeat((short)8000, 1200).ToArray();
        var quiet = Enumerable.Repeat((short)0, 300).ToArray();
        var samples = loud.Concat(quiet).Concat(Enumerable.Repeat((short)8000, 500)).ToArray();
        var bytes = MemoryMarshal.AsBytes(samples.AsSpan()).ToArray();
        Assert.Equal(samples.Length, chunker.Add(bytes.AsSpan(0, 1001)) + chunker.Add(bytes.AsSpan(1001)));
        var first = chunker.TakeReady();
        Assert.NotNull(first);
        Assert.InRange(first.Samples.Length, 1100, 1400);
        Assert.Equal(0, first.StartSeconds);
        var rest = chunker.TakeRest();
        Assert.NotNull(rest);
        Assert.Equal(samples.Length, first.Samples.Length + rest.Samples.Length);
        Assert.Equal(first.Samples.Length / 1000.0, rest.StartSeconds, 3);
    }

    /// <summary>Hears one word every two seconds of sound it is given.</summary>
    private sealed class InventedRecognizer : ISpeechRecognizer
    {
        public bool Available => true;

        public int Calls { get; private set; }

        public Task<IReadOnlyList<SpeechWord>> RecognizeAsync(short[] samples, string language, string modelPath, CancellationToken cancellationToken)
        {
            Calls++;
            var seconds = samples.Length / 16_000.0;
            var words = new List<SpeechWord>();
            for (var at = 0.5; at + 1 < seconds; at += 2) words.Add(new SpeechWord(words.Count % 3 == 2 ? "word." : "word", at, at + 0.6));
            return Task.FromResult<IReadOnlyList<SpeechWord>>(words);
        }
    }

    [Fact]
    public async Task AJobWritesSubtitlesFromSpeechAndStoresNothingElse()
    {
        if (Installed() is not { } ffmpeg) return;
        var parent = TestPaths.CreateDataDirectory();
        var root = Path.Combine(parent, "Invented Films");
        Directory.CreateDirectory(root);
        try
        {
            var video = Path.Combine(root, "Invented Film (2024).mkv");
            await EncodeAsync(ffmpeg, SyntheticAudio.Music(seed: 77, seconds: 40), video);
            var before = (File.GetLastWriteTimeUtc(video), new FileInfo(video).Length);
            var recognizer = new InventedRecognizer();
            using var factory = new AureliaServerFactory(configureServices: services =>
            {
                services.RemoveAll<LiveConversionService>();
                services.AddSingleton(provider => new LiveConversionService(
                    new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Aurelia:Ffmpeg"] = ffmpeg }).Build(),
                    provider.GetRequiredService<ServerRuntimeOptions>(), NullLogger<LiveConversionService>.Instance));
                services.RemoveAll<ISpeechRecognizer>();
                services.AddSingleton<ISpeechRecognizer>(recognizer);
            });
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", owner.Token);
            var filmId = await AddFilmAsync(factory, root, video);

            using (var capabilities = await client.GetAsync("/api/v1/capabilities"))
                Assert.Contains(ServerFeatures.ServerSpeech, (await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities)).Capabilities);
            var state = await client.GetFromJsonAsync<MediaSpeechResponse>($"/api/v1/media/{filmId}/speech", ApiTestClient.JsonOptions);
            Assert.True(state is { Available: true, ModelReady: false, Job: null });
            using (var refused = await client.PostAsJsonAsync($"/api/v1/media/{filmId}/speech", new StartSpeechJobRequest(SpeechJobKind.Create, "en"), ApiTestClient.JsonOptions))
                Assert.Equal(HttpStatusCode.Conflict, refused.StatusCode);

            // An invented model file in the server's data folder, where the owner's download goes.
            var models = Path.Combine(factory.DataDirectory, SpeechModelStore.FolderName);
            Directory.CreateDirectory(models);
            await File.WriteAllBytesAsync(Path.Combine(models, "ggml-base.bin"), [0x6c, 0x6d, 0x67, 0x67, 0, 0, 0, 0]);
            var settings = await client.GetFromJsonAsync<ServerSpeechSettings>("/api/v1/server/speech", ApiTestClient.JsonOptions);
            Assert.True(settings is { Available: true, Model: "base", ModelBytes: 8 });

            var dataFiles = Files(factory.DataDirectory);
            using (var started = await client.PostAsJsonAsync($"/api/v1/media/{filmId}/speech", new StartSpeechJobRequest(SpeechJobKind.Create, "en"), ApiTestClient.JsonOptions))
            {
                Assert.Equal(HttpStatusCode.OK, started.StatusCode);
                Assert.Equal(SpeechJobState.Waiting, (await ApiTestClient.ReadAsync<MediaSpeechResponse>(started)).Job?.State);
            }
            await factory.Services.GetRequiredService<SpeechJobService>().RunNextAsync(CancellationToken.None);
            var done = await client.GetFromJsonAsync<MediaSpeechResponse>($"/api/v1/media/{filmId}/speech", ApiTestClient.JsonOptions);
            Assert.True(done?.Job is { State: SpeechJobState.Done, Progress: 1, SubtitleId: not null }, done?.Job?.Message);
            Assert.True(recognizer.Calls >= 1);

            // Only the finished subtitles were stored: no sound, words or other files.
            var added = Files(factory.DataDirectory).Except(dataFiles)
                .Where(file => !Path.GetRelativePath(factory.DataDirectory, file).StartsWith("aurelia.db", StringComparison.Ordinal)).ToList();
            // The subtitles and their folder's list, nothing else.
            Assert.All(added, file => Assert.StartsWith("Subtitles" + Path.DirectorySeparatorChar, Path.GetRelativePath(factory.DataDirectory, file), StringComparison.Ordinal));
            Assert.Single(added, file => file.EndsWith(".srt", StringComparison.OrdinalIgnoreCase));
            Assert.All(added, file => Assert.True(file.EndsWith(".srt", StringComparison.OrdinalIgnoreCase) || Path.GetFileName(file) == "index.json", file));
            var text = await File.ReadAllTextAsync(added.Single(file => file.EndsWith(".srt", StringComparison.OrdinalIgnoreCase)));
            Assert.Contains("00:00:00,500 --> ", text, StringComparison.Ordinal);
            Assert.Contains("\nword.\n", text, StringComparison.Ordinal);
            Assert.Equal([video], Directory.GetFiles(root));
            Assert.Equal(before, (File.GetLastWriteTimeUtc(video), new FileInfo(video).Length));

            // Sync to Speech: subtitles beside the video, two seconds early, are saved as a moved copy.
            var sidecar = Path.Combine(root, "Invented Film (2024).en.srt");
            var early = SubtitleCueBuilder.Cues(Enumerable.Range(0, 19).Select(index => new SpeechWord(index % 3 == 2 ? "word." : "word", 0.5 + index * 2 - 2.0, 1.1 + index * 2 - 2.0)).Where(word => word.Start >= 0));
            await File.WriteAllTextAsync(sidecar, SubtitleCueBuilder.SubRip(early));
            using (var sync = await client.PostAsJsonAsync($"/api/v1/media/{filmId}/speech", new StartSpeechJobRequest(SpeechJobKind.Sync, "en", SubtitleIndex: 1000), ApiTestClient.JsonOptions))
                Assert.Equal(HttpStatusCode.OK, sync.StatusCode);
            await factory.Services.GetRequiredService<SpeechJobService>().RunNextAsync(CancellationToken.None);
            var synced = await client.GetFromJsonAsync<MediaSpeechResponse>($"/api/v1/media/{filmId}/speech", ApiTestClient.JsonOptions);
            Assert.True(synced?.Job is { State: SpeechJobState.Done or SpeechJobState.AlreadyInSync or SpeechJobState.Failed }, synced?.Job?.Message);
            Assert.NotNull(synced?.Job?.Message);

            using (var cleared = await client.DeleteAsync("/api/v1/server/speech/model"))
                Assert.Equal(HttpStatusCode.OK, cleared.StatusCode);
            Assert.Empty(Directory.GetFiles(models));
        }
        finally
        {
            Directory.Delete(parent, recursive: true);
        }
    }

    private static async Task<Guid> AddFilmAsync(AureliaServerFactory factory, string root, string path)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Invented Films",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        var film = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = "Invented Film",
            Category = string.Empty,
            Extension = Path.GetExtension(path),
            FileSize = new FileInfo(path).Length,
            FileModifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero),
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        };
        database.MediaItems.Add(film);
        await database.SaveChangesAsync();
        return film.Id;
    }

    private static async Task EncodeAsync(string ffmpeg, short[] sound, string path)
    {
        var start = new ProcessStartInfo(ffmpeg) { RedirectStandardInput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in new[] { "-hide_banner", "-loglevel", "error", "-f", "s16le", "-ar", "11025", "-ac", "1", "-i", "pipe:0", "-c:a", "aac", "-b:a", "96k", path })
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var errors = process.StandardError.ReadToEndAsync();
        await process.StandardInput.BaseStream.WriteAsync(MemoryMarshal.AsBytes(sound.AsSpan()).ToArray());
        process.StandardInput.Close();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == 0, await errors);
    }

    private static HashSet<string> Files(string directory) =>
        Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).ToHashSet(StringComparer.Ordinal);

    private static string? Installed()
    {
        if (Environment.GetEnvironmentVariable("AURELIA_TEST_FFMPEG") is { Length: > 0 } chosen) return chosen;
        var directories = (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(Path.PathSeparator)
            .Concat(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]);
        return directories.Where(directory => directory.Length > 0)
            .Select(directory => Path.Combine(directory, "ffmpeg"))
            .FirstOrDefault(candidate => File.Exists(candidate) && File.Exists(Path.Combine(Path.GetDirectoryName(candidate)!, "ffprobe")));
    }
}
