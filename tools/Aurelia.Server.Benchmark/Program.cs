using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

if (args.Length != 3) throw new ArgumentException("Arguments: baseline executable, candidate executable, output report path.");
var baseline = Path.GetFullPath(args[0]);
var candidate = Path.GetFullPath(args[1]);
var report = Path.GetFullPath(args[2]);
var root = Path.Combine(Path.GetDirectoryName(report)!, ".benchmark-" + Guid.NewGuid().ToString("N"));
PrivateFilePermissions.CreatePrivateDirectory(root);
try
{
    var seed = Path.Combine(root, "seed");
    PrivateFilePermissions.CreatePrivateDirectory(seed);
    await SeedAsync(seed);
    var before = await MeasureAsync(baseline, seed, Path.Combine(root, "baseline"));
    var after = await MeasureAsync(candidate, seed, Path.Combine(root, "candidate"));
    var result = new
    {
        formatVersion = 1,
        createdAt = DateTimeOffset.UtcNow,
        entries = 10000,
        series = 50,
        episodesPerSeries = 30,
        progressRows = 300,
        creditsPerEntry = 8,
        clients = 2,
        requestsPerEndpoint = 20,
        methodology = "Same synthetic SQLite snapshot, PIN-unlocked owner profile session, 3 warmups, then 20 requests per endpoint in two concurrent clients. No videos, personal data, or artwork files. CPU is process CPU during measurement; RSS sampled every 20 ms. SQL counts use EF command logs (raw FTS commands are excluded). One local Mac run; not a throughput or production guarantee.",
        baseline = before,
        candidate = after,
    };
    await File.WriteAllTextAsync(report, JsonSerializer.Serialize(result, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
    Console.WriteLine("Synthetic benchmark report: " + report);
}
finally
{
    Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
    Directory.Delete(root, true);
}

static async Task SeedAsync(string directory)
{
    var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite($"Data Source={Path.Combine(directory, "aurelia.db")};Pooling=False").Options;
    await using var database = new AureliaDbContext(options);
    await database.Database.MigrateAsync();
    var now = DateTimeOffset.UtcNow;
    var owner = new ServerUser { Id = Guid.NewGuid(), Username = "benchmark-owner", NormalizedUsername = "BENCHMARK-OWNER", PasswordHash = "", Role = UserRole.Owner, CreatedAt = now };
    owner.PasswordHash = new PasswordHasher<ServerUser>().HashPassword(owner, "synthetic-benchmark-password");
    owner.PinHash = new PasswordHasher<ServerUser>().HashPassword(owner, "5682");
    database.AdministrationCredentials.Add(new ServerAdministrationCredential { PasswordHash = owner.PasswordHash });
    var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", Path = Path.Combine(directory, "Storage"), NormalizedPath = Path.Combine(directory, "Storage"), Kind = LibraryKind.Movies, Availability = LibraryAvailability.Available, MonitoringEnabled = false, CreatedAt = now };
    Directory.CreateDirectory(library.Path);
    database.Users.Add(owner);
    database.LibraryRoots.Add(library);
    database.ServerIdentities.Add(new ServerIdentity { Id = 1, ServerId = Guid.NewGuid(), CreatedAt = now });
    await database.SaveChangesAsync();
    for (var start = 0; start < 10000; start += 500)
    {
        for (var index = start; index < start + 500; index++)
        {
            var title = "Synthetic Film " + index.ToString("D5", CultureInfo.InvariantCulture);
            var path = Path.Combine(library.Path, title + ".mkv");
            var item = new MediaItem { Id = Guid.NewGuid(), LibraryRootId = library.Id, Kind = MediaKind.Movie, DetectedTitle = title, Year = 2020, Availability = MediaAvailability.Available, SourcePath = path, NormalizedSourcePath = path, Extension = ".mkv", CreatedAt = now.AddSeconds(index), UpdatedAt = now };
            item.Metadata = new MediaMetadata { MediaItemId = item.Id, MediaItem = item, ProviderTitle = title, ProviderOverview = "Synthetic benchmark overview.", ProviderGenresJson = "[\"Drama\"]", UpdatedAt = now, ReviewState = MetadataReviewState.Matched };
            for (var credit = 0; credit < 8; credit++)
                item.Metadata.Credits.Add(new MediaCredit { Id = Guid.NewGuid(), MediaItemId = item.Id, Metadata = item.Metadata, Name = "Synthetic Person " + credit.ToString(CultureInfo.InvariantCulture), Department = "Acting", SortOrder = credit });
            database.MediaItems.Add(item);
        }
        await database.SaveChangesAsync();
        database.ChangeTracker.Clear();
    }
    // Series with episodes and in-progress titles, as browsed from the Apple TV.
    var shows = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic Shows", Path = Path.Combine(directory, "Shows"), NormalizedPath = Path.Combine(directory, "Shows"), Kind = LibraryKind.TvShows, Availability = LibraryAvailability.Available, MonitoringEnabled = false, CreatedAt = now };
    Directory.CreateDirectory(shows.Path);
    database.LibraryRoots.Add(shows);
    var progressTargets = new List<Guid>();
    for (var show = 0; show < 50; show++)
    {
        var name = "Synthetic Show " + show.ToString("D3", CultureInfo.InvariantCulture);
        var folder = Path.Combine(shows.Path, name);
        var series = new MediaItem { Id = Guid.NewGuid(), LibraryRootId = shows.Id, Kind = MediaKind.Series, DetectedTitle = name, Year = 2018, Availability = MediaAvailability.Available, SourcePath = folder, NormalizedSourcePath = folder, Extension = "", CreatedAt = now.AddSeconds(20000 + show), UpdatedAt = now };
        series.Metadata = new MediaMetadata { MediaItemId = series.Id, MediaItem = series, ProviderTitle = name, ProviderOverview = "Synthetic series.", ProviderGenresJson = "[\"Crime\"]", UpdatedAt = now, ReviewState = MetadataReviewState.Matched };
        database.MediaItems.Add(series);
        for (var season = 1; season <= 3; season++)
        {
            for (var number = 1; number <= 10; number++)
            {
                var title = $"{name} S{season:D2}E{number:D2}";
                var path = Path.Combine(folder, title + ".mkv");
                var episode = new MediaItem { Id = Guid.NewGuid(), LibraryRootId = shows.Id, ParentId = series.Id, Kind = MediaKind.Episode, DetectedTitle = title, SeasonNumber = season, EpisodeNumber = number, Year = 2018, Availability = MediaAvailability.Available, SourcePath = path, NormalizedSourcePath = path, Extension = ".mkv", CreatedAt = now.AddSeconds(30000 + show * 30 + season * 10 + number), UpdatedAt = now };
                episode.Metadata = new MediaMetadata { MediaItemId = episode.Id, MediaItem = episode, ProviderTitle = title, ProviderOverview = "Synthetic episode.", ProviderGenresJson = "[]", UpdatedAt = now, ReviewState = MetadataReviewState.Matched };
                database.MediaItems.Add(episode);
                if (season == 2 && number == 3) progressTargets.Add(episode.Id);
            }
        }
    }
    await database.SaveChangesAsync();
    progressTargets.AddRange(await database.MediaItems.Where(item => item.Kind == MediaKind.Movie).OrderBy(item => item.CreatedAt).Take(250).Select(item => item.Id).ToListAsync());
    var ownerEntity = await database.Users.SingleAsync(user => user.Id == owner.Id);
    var played = 0;
    foreach (var target in progressTargets)
    {
        var media = await database.MediaItems.SingleAsync(item => item.Id == target);
        database.Add(new PlaybackProgress { Id = Guid.NewGuid(), MediaItemId = target, MediaItem = media, UserId = owner.Id, User = ownerEntity, PositionMilliseconds = 600_000, DurationMilliseconds = 2_700_000, LastPlayedAt = now.AddMinutes(-played), UpdatedAt = now, Revision = 1 });
        played++;
    }
    await database.SaveChangesAsync();
    database.ChangeTracker.Clear();
    // Synthetic provider-size posters (2000x3000 JPEG with gradient and noise) for
    // the artwork scenario. They live beside the database like the real cache.
    var artworkDirectory = Path.Combine(directory, "Artwork");
    PrivateFilePermissions.CreatePrivateDirectory(artworkDirectory);
    var random = new Random(42);
    var posterTargets = await database.MediaItems.Where(item => item.Kind == MediaKind.Movie)
        .OrderBy(item => item.CreatedAt).Take(48).Select(item => item.Id).ToListAsync();
    foreach (var mediaId in posterTargets)
    {
        using var bitmap = new SkiaSharp.SKBitmap(2000, 3000);
        using (var canvas = new SkiaSharp.SKCanvas(bitmap))
        {
            using var paint = new SkiaSharp.SKPaint
            {
                Shader = SkiaSharp.SKShader.CreateLinearGradient(new SkiaSharp.SKPoint(0, 0), new SkiaSharp.SKPoint(2000, 3000),
                    [new SkiaSharp.SKColor((byte)random.Next(256), 40, 90), new SkiaSharp.SKColor(20, (byte)random.Next(256), 160)], SkiaSharp.SKShaderTileMode.Clamp),
            };
            canvas.DrawRect(0, 0, 2000, 3000, paint);
            using var noise = new SkiaSharp.SKPaint();
            for (var dot = 0; dot < 40_000; dot++)
            {
                noise.Color = new SkiaSharp.SKColor((byte)random.Next(256), (byte)random.Next(256), (byte)random.Next(256));
                canvas.DrawRect(random.Next(2000), random.Next(3000), 6, 6, noise);
            }
        }
        using var image = SkiaSharp.SKImage.FromBitmap(bitmap);
        using var encoded = image.Encode(SkiaSharp.SKEncodedImageFormat.Jpeg, 90);
        var fileName = Guid.NewGuid().ToString("N") + ".jpg";
        await File.WriteAllBytesAsync(Path.Combine(artworkDirectory, fileName), encoded.ToArray());
        database.ArtworkAssets.Add(new ArtworkAsset { Id = Guid.NewGuid(), MediaItemId = mediaId, Kind = ArtworkKind.Poster, ProviderPath = "/synthetic/" + fileName, RelativeFilePath = fileName, ContentType = "image/jpeg", ContentLength = encoded.Size, CreatedAt = now });
    }
    await database.SaveChangesAsync();
    database.ChangeTracker.Clear();
    await new MediaSearchIndexService(database).RebuildAsync(CancellationToken.None);
    await database.Database.ExecuteSqlRawAsync("PRAGMA wal_checkpoint(TRUNCATE);");
}

static async Task<object> MeasureAsync(string executable, string seed, string directory)
{
    PrivateFilePermissions.CreatePrivateDirectory(directory);
    File.Copy(Path.Combine(seed, "aurelia.db"), Path.Combine(directory, "aurelia.db"));
    PrivateFilePermissions.CreatePrivateDirectory(Path.Combine(directory, "Artwork"));
    foreach (var file in Directory.EnumerateFiles(Path.Combine(seed, "Artwork")))
        File.Copy(file, Path.Combine(directory, "Artwork", Path.GetFileName(file)));
    using var reservation = new TcpListener(IPAddress.Loopback, 0);
    reservation.Start();
    var port = ((IPEndPoint)reservation.LocalEndpoint).Port;
    reservation.Stop();
    using var process = new Process { StartInfo = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, WorkingDirectory = directory } };
    process.StartInfo.ArgumentList.Add("run"); process.StartInfo.ArgumentList.Add("--data-dir"); process.StartInfo.ArgumentList.Add(directory);
    process.StartInfo.ArgumentList.Add("--urls"); process.StartInfo.ArgumentList.Add("http://127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture));
    process.StartInfo.Environment["AURELIA_LAN_ENABLED"] = "false";
    process.StartInfo.Environment["Logging__LogLevel__Default"] = "Warning";
    process.StartInfo.Environment["Logging__LogLevel__Microsoft.EntityFrameworkCore.Database.Command"] = "Information";
    var commands = 0L;
    var logTail = new Queue<string>();
    // Optional diagnostics: AURELIA_BENCHMARK_SQL_LOG names a file that receives the
    // timed EF command lines (synthetic data only) for investigating slow endpoints.
    var sqlLog = Environment.GetEnvironmentVariable("AURELIA_BENCHMARK_SQL_LOG");
    var sqlLines = new System.Collections.Concurrent.ConcurrentQueue<string>();
    string? pendingCommand = null;
    process.OutputDataReceived += (_, entry) =>
    {
        if (entry.Data?.Contains("Executed DbCommand", StringComparison.Ordinal) == true)
        {
            Interlocked.Increment(ref commands);
            pendingCommand = entry.Data;
        }
        else if (sqlLog is not null && pendingCommand is not null && entry.Data is { } text && text.TrimStart().StartsWith("SELECT", StringComparison.Ordinal))
        {
            sqlLines.Enqueue(pendingCommand.Trim() + " :: " + text.Trim()[..Math.Min(text.Trim().Length, 160)]);
            pendingCommand = null;
        }
    };
    process.ErrorDataReceived += (_, entry) => { lock (logTail) { if (entry.Data is { } text) logTail.Enqueue(text); while (logTail.Count > 10) logTail.Dequeue(); } };
    process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
    try
    {
        using var client = new HttpClient { BaseAddress = new Uri("http://127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture)), Timeout = TimeSpan.FromSeconds(30) };
        var ready = false;
        for (var attempt = 0; attempt < 150; attempt++)
        {
            if (process.HasExited) throw new InvalidOperationException("Synthetic server exited: " + string.Join('\n', logTail));
            try { using var response = await client.GetAsync("/api/v1/server/info"); ready = response.IsSuccessStatusCode; } catch (HttpRequestException) { }
            if (ready) break;
            await Task.Delay(100);
        }
        if (!ready) throw new TimeoutException("Synthetic server did not become ready.");
        using var login = await client.PostAsJsonAsync("/api/v1/auth/login", new { username = "benchmark-owner", password = "synthetic-benchmark-password", deviceName = "Synthetic benchmark" });
        login.EnsureSuccessStatusCode();
        using var authentication = JsonDocument.Parse(await login.Content.ReadAsStringAsync());
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", authentication.RootElement.GetProperty("token").GetString());
        // Viewing endpoints require an unlocked profile session, as on the Apple TV.
        using var picker = JsonDocument.Parse(await client.GetStringAsync("/api/v1/profiles"));
        var profileId = picker.RootElement.GetProperty("profiles")[0].GetProperty("id").GetString();
        using var unlock = await client.PostAsJsonAsync($"/api/v1/profiles/{profileId}/unlock", new { pin = "5682" });
        unlock.EnsureSuccessStatusCode();
        using var profile = JsonDocument.Parse(await unlock.Content.ReadAsStringAsync());
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", profile.RootElement.GetProperty("token").GetString());
        using var seriesPage = JsonDocument.Parse(await client.GetStringAsync("/api/v1/catalog/items?kind=series&offset=0&limit=1"));
        var seriesId = seriesPage.RootElement.GetProperty("items")[0].GetProperty("id").GetString();
        using var moviePage = JsonDocument.Parse(await client.GetStringAsync("/api/v1/catalog/items?kind=movie&offset=0&limit=1"));
        var movieId = moviePage.RootElement.GetProperty("items")[0].GetProperty("id").GetString();
        var measurements = new List<object>();
        foreach (var path in new[]
        {
            "/api/v1/catalog/items?kind=movie&offset=0&limit=60", "/api/v1/catalog/items?kind=series&offset=0&limit=60",
            "/api/v1/catalog/search?query=Synthetic&offset=0&limit=60", "/api/v1/home",
            $"/api/v1/catalog/items/{seriesId}", $"/api/v1/media/{seriesId}/playback-plan",
            $"/api/v1/catalog/items/{movieId}/summary",
        })
        {
            for (var warmup = 0; warmup < 3; warmup++) { using var response = await client.GetAsync(path); response.EnsureSuccessStatusCode(); }
            process.Refresh(); var cpuStart = process.TotalProcessorTime; var queryStart = Interlocked.Read(ref commands);
            var peakRss = process.WorkingSet64;
            using var sampling = new CancellationTokenSource();
            var sampler = Task.Run(async () => { while (!sampling.IsCancellationRequested) { process.Refresh(); peakRss = Math.Max(peakRss, process.WorkingSet64); await Task.Delay(20); } });
            var watch = Stopwatch.StartNew();
            var timings = await Task.WhenAll(Enumerable.Range(0, 2).Select(async _ =>
            {
                var times = new List<double>();
                for (var request = 0; request < 10; request++)
                {
                    var elapsed = Stopwatch.StartNew();
                    using var response = await client.GetAsync(path);
                    response.EnsureSuccessStatusCode();
                    await response.Content.ReadAsByteArrayAsync();
                    times.Add(elapsed.Elapsed.TotalMilliseconds);
                }
                return times;
            }));
            watch.Stop(); sampling.Cancel(); await sampler;
            process.Refresh(); var ordered = timings.SelectMany(value => value).Order().ToArray();
            measurements.Add(new { endpoint = path, p50Ms = ordered[9], p95Ms = ordered[18], wallMs = watch.Elapsed.TotalMilliseconds, cpuMs = (process.TotalProcessorTime - cpuStart).TotalMilliseconds, peakRssBytes = peakRss, efCommands = Interlocked.Read(ref commands) - queryStart });
        }
        // Artwork: 48 posters at the TV's poster width, six requests in flight like the
        // Apple TV pipeline. Cold generates every variant; warm serves cached files.
        var artworkIds = new List<string>();
        using (var posters = JsonDocument.Parse(await client.GetStringAsync("/api/v1/catalog/items?kind=movie&offset=0&limit=200&sort=dateAdded")))
            foreach (var item in posters.RootElement.GetProperty("items").EnumerateArray())
                if (item.TryGetProperty("poster", out var poster) && poster.ValueKind == JsonValueKind.Object)
                    artworkIds.Add(poster.GetProperty("id").GetString()!);
        if (artworkIds.Count != 48) throw new InvalidOperationException($"Expected 48 synthetic posters, found {artworkIds.Count}.");
        foreach (var phase in new[] { "artwork-640-cold", "artwork-640-warm" })
        {
            process.Refresh(); var cpuStart = process.TotalProcessorTime;
            var queue = new System.Collections.Concurrent.ConcurrentQueue<string>(artworkIds);
            var times = new System.Collections.Concurrent.ConcurrentBag<double>();
            var watch = Stopwatch.StartNew();
            await Task.WhenAll(Enumerable.Range(0, 6).Select(async _ =>
            {
                while (queue.TryDequeue(out var id))
                {
                    var elapsed = Stopwatch.StartNew();
                    using var response = await client.GetAsync($"/api/v1/artwork/{id}?width=640");
                    response.EnsureSuccessStatusCode();
                    await response.Content.ReadAsByteArrayAsync();
                    times.Add(elapsed.Elapsed.TotalMilliseconds);
                }
            }));
            watch.Stop(); process.Refresh();
            var ordered = times.Order().ToArray();
            measurements.Add(new { endpoint = phase, p50Ms = ordered[ordered.Length / 2], p95Ms = ordered[(int)(ordered.Length * 0.95)], wallMs = watch.Elapsed.TotalMilliseconds, cpuMs = (process.TotalProcessorTime - cpuStart).TotalMilliseconds, peakRssBytes = process.WorkingSet64, efCommands = 0L });
        }
        if (sqlLog is not null) await File.AppendAllLinesAsync(sqlLog, sqlLines);
        using var information = JsonDocument.Parse(await client.GetStringAsync("/api/v1/server/info"));
        await using var binary = File.OpenRead(executable);
        var binaryHash = Convert.ToHexString(await System.Security.Cryptography.SHA256.HashDataAsync(binary));
        return new { serverVersion = information.RootElement.GetProperty("version").GetString(), binarySha256 = binaryHash, results = measurements };
    }
    finally
    {
        if (!process.HasExited)
        {
            using var terminate = Process.Start(new ProcessStartInfo("/bin/kill") { ArgumentList = { "-TERM", process.Id.ToString(CultureInfo.InvariantCulture) }, UseShellExecute = false });
            if (terminate is not null) await terminate.WaitForExitAsync();
            using var shutdown = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            try { await process.WaitForExitAsync(shutdown.Token); } catch (OperationCanceledException) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
        }
    }
}
