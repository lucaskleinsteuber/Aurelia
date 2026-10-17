using System.Diagnostics;
using System.Globalization;
using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Serialization;
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
    if (Environment.GetEnvironmentVariable("AURELIA_BENCHMARK_STARTUP_ONLY") == "1")
    {
        // Alternate repeated cold starts so first-launch checks and caches affect both binaries alike.
        var startups = new Dictionary<string, List<double>> { ["baseline"] = [], ["candidate"] = [] };
        for (var round = 0; round < 6; round++)
            foreach (var (name, executable) in new[] { ("baseline", baseline), ("candidate", candidate) })
                startups[name].Add(await StartupAsync(executable, seed, Path.Combine(root, $"{name}-start-{round}")));
        await File.WriteAllTextAsync(report, JsonSerializer.Serialize(new
        {
            formatVersion = 1, createdAt = DateTimeOffset.UtcNow, entries = 10000,
            methodology = "Process start until /api/v1/server/info answers, six alternating starts each on a copy of the same synthetic database; the first start of each binary is reported separately.",
            baseline = new { first = startups["baseline"][0], medianOfRest = startups["baseline"].Skip(1).Order().ElementAt(2), all = startups["baseline"] },
            candidate = new { first = startups["candidate"][0], medianOfRest = startups["candidate"].Skip(1).Order().ElementAt(2), all = startups["candidate"] },
        }, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
        Console.WriteLine("Synthetic startup report: " + report);
        return;
    }
    var before = await MeasureAsync(baseline, seed, Path.Combine(root, "baseline"));
    var after = await MeasureAsync(candidate, seed, Path.Combine(root, "candidate"));
    var beforeIdle = await MeasureIdleAsync(baseline, seed, Path.Combine(root, "baseline-idle"));
    var afterIdle = await MeasureIdleAsync(candidate, seed, Path.Combine(root, "candidate-idle"));
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
        methodology = "Same synthetic SQLite snapshot, PIN-unlocked owner profile session, 3 warmups, then 20 requests per endpoint in two concurrent clients. No videos or personal data; 48 synthetic posters. CPU is process CPU during measurement; RSS sampled every 20 ms. SQL counts use EF command logs (raw FTS commands are excluded). Startup is process start until /server/info answers. Full catalog loads page through every item like the clients. Idle runs a fresh process, waits 60 s for startup work and artwork preparation, then measures 30 s without requests. The functional sweep calls a broad set of endpoints and fails on any non-success. One local Mac run; not a throughput or production guarantee.",
        baseline = before,
        candidate = after,
        baselineIdle = beforeIdle,
        candidateIdle = afterIdle,
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
    var started = Stopwatch.StartNew();
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
        var startupMs = started.Elapsed.TotalMilliseconds;
        using var login = await client.PostAsJsonAsync("/api/v1/auth/login", new { username = "benchmark-owner", password = "synthetic-benchmark-password", deviceName = "Synthetic benchmark" });
        login.EnsureSuccessStatusCode();
        using var authentication = JsonDocument.Parse(await login.Content.ReadAsStringAsync());
        var deviceToken = authentication.RootElement.GetProperty("token").GetString()!;
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", deviceToken);
        // Viewing endpoints require an unlocked profile session, as on the Apple TV.
        using var picker = JsonDocument.Parse(await client.GetStringAsync("/api/v1/profiles"));
        var profileId = picker.RootElement.GetProperty("profiles")[0].GetProperty("id").GetString();
        using var unlock = await client.PostAsJsonAsync($"/api/v1/profiles/{profileId}/unlock", new { pin = "5682" });
        unlock.EnsureSuccessStatusCode();
        using var profile = JsonDocument.Parse(await unlock.Content.ReadAsStringAsync());
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", profile.RootElement.GetProperty("token").GetString());
        var firstHome = Stopwatch.StartNew();
        using (var home = await client.GetAsync("/api/v1/home")) home.EnsureSuccessStatusCode();
        var firstHomeMs = firstHome.Elapsed.TotalMilliseconds;
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
        // The server admits 600 requests per minute and address; let each block start fresh.
        static Task NextRequestWindowAsync() => Task.Delay(TimeSpan.FromSeconds(61));
        await NextRequestWindowAsync();
        // Clients load the whole catalog page by page; larger pages need fewer round trips.
        using var capabilityDocument = JsonDocument.Parse(await client.GetStringAsync("/api/v1/capabilities"));
        var largePages = capabilityDocument.RootElement.GetProperty("capabilities").EnumerateArray()
            .Any(value => value.GetString() == "catalog-pages-500-v1");
        var catalogLoads = new List<object>();
        foreach (var pageSize in largePages ? new[] { 100, 500 } : new[] { 100 })
        {
            var watch = Stopwatch.StartNew();
            var requests = 0; long items = 0; long bytes = 0; long compressedBytes = 0;
            for (var offset = 0; ; offset += pageSize)
            {
                using var plain = await client.GetAsync($"/api/v1/catalog/items?offset={offset}&limit={pageSize}");
                plain.EnsureSuccessStatusCode();
                var body = await plain.Content.ReadAsByteArrayAsync();
                requests++; bytes += body.Length;
                using var page = JsonDocument.Parse(body);
                var count = page.RootElement.GetProperty("items").GetArrayLength();
                items += count;
                using var compressedRequest = new HttpRequestMessage(HttpMethod.Get, $"/api/v1/catalog/items?offset={offset}&limit={pageSize}");
                compressedRequest.Headers.AcceptEncoding.ParseAdd("br");
                using var compressed = await client.SendAsync(compressedRequest);
                compressed.EnsureSuccessStatusCode();
                compressedBytes += (await compressed.Content.ReadAsByteArrayAsync()).Length;
                if (offset + count >= page.RootElement.GetProperty("total").GetInt64()) break;
            }
            watch.Stop();
            catalogLoads.Add(new { pageSize, requests, items, jsonBytes = bytes, brotliBytes = compressedBytes, wallMsIncludingCompressedCopy = watch.Elapsed.TotalMilliseconds });
        }
        await NextRequestWindowAsync();
        var timedLoads = new List<object>();
        foreach (var pageSize in largePages ? new[] { 100, 500 } : new[] { 100 })
        {
            var times = new List<double>();
            for (var run = 0; run < 3; run++)
            {
                var watch = Stopwatch.StartNew();
                for (var offset = 0; ; offset += pageSize)
                {
                    using var response = await client.GetAsync($"/api/v1/catalog/items?offset={offset}&limit={pageSize}");
                    response.EnsureSuccessStatusCode();
                    using var page = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync());
                    if (offset + page.RootElement.GetProperty("items").GetArrayLength() >= page.RootElement.GetProperty("total").GetInt64()) break;
                }
                times.Add(watch.Elapsed.TotalMilliseconds);
            }
            timedLoads.Add(new { pageSize, medianMs = times.Order().ElementAt(1) });
        }
        await NextRequestWindowAsync();
        var sweep = await SweepAsync(client, deviceToken, movieId!, seriesId!, largePages);
        if (sqlLog is not null) await File.AppendAllLinesAsync(sqlLog, sqlLines);
        using var information = JsonDocument.Parse(await client.GetStringAsync("/api/v1/server/info"));
        await using var binary = File.OpenRead(executable);
        var binaryHash = Convert.ToHexString(await System.Security.Cryptography.SHA256.HashDataAsync(binary));
        process.Refresh();
        return new
        {
            serverVersion = information.RootElement.GetProperty("version").GetString(), binarySha256 = binaryHash,
            startupMs, firstHomeMs, finalRssBytes = process.WorkingSet64, threads = process.Threads.Count,
            results = measurements, catalogLoads, timedCatalogLoads = timedLoads, functionalSweep = sweep,
        };
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

static async Task<object> MeasureIdleAsync(string executable, string seed, string directory)
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
    process.OutputDataReceived += (_, _) => { };
    process.ErrorDataReceived += (_, _) => { };
    process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
    try
    {
        using var client = new HttpClient { BaseAddress = new Uri("http://127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture)), Timeout = TimeSpan.FromSeconds(30) };
        var ready = false;
        for (var attempt = 0; attempt < 150 && !ready; attempt++)
        {
            if (process.HasExited) throw new InvalidOperationException("Synthetic idle server exited.");
            try { using var response = await client.GetAsync("/api/v1/server/info"); ready = response.IsSuccessStatusCode; } catch (HttpRequestException) { }
            if (!ready) await Task.Delay(100);
        }
        if (!ready) throw new TimeoutException("Synthetic idle server did not become ready.");
        await Task.Delay(TimeSpan.FromSeconds(60));
        process.Refresh();
        var cpuStart = process.TotalProcessorTime;
        var peakRss = process.WorkingSet64;
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < TimeSpan.FromSeconds(30))
        {
            await Task.Delay(500);
            process.Refresh();
            peakRss = Math.Max(peakRss, process.WorkingSet64);
        }
        process.Refresh();
        return new
        {
            idleSeconds = 30, cpuMs = (process.TotalProcessorTime - cpuStart).TotalMilliseconds,
            rssBytes = process.WorkingSet64, peakRssBytes = peakRss, threads = process.Threads.Count,
        };
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

// Broad black-box coverage of the published binary (for example a trimmed build):
// any endpoint that fails here fails the benchmark. Synthetic data only.
static async Task<object> SweepAsync(HttpClient client, string deviceToken, string movieId, string seriesId, bool largePages)
{
    const string password = "synthetic-benchmark-password";
    var json = new JsonSerializerOptions(JsonSerializerDefaults.Web);
    json.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
    var checks = new List<string>();
    async Task<JsonDocument> SendAsync(HttpMethod method, string path, object? body = null, bool approval = false, string? token = null, string? encoding = null)
    {
        var payload = body is null ? [] : JsonSerializer.SerializeToUtf8Bytes(body, json);
        using var request = new HttpRequestMessage(method, path);
        if (body is not null) request.Content = new ByteArrayContent(payload) { Headers = { ContentType = new MediaTypeHeaderValue("application/json") } };
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (encoding is not null) request.Headers.AcceptEncoding.ParseAdd(encoding);
        if (approval)
        {
            using var grant = await SendAsync(HttpMethod.Post, "/api/v1/management/approval",
                new AdministrationApprovalRequest(method.Method + " " + path, AdministrationApprovalStore.Hash(payload), password));
            request.Headers.Add("X-Aurelia-Approval", grant.RootElement.GetProperty("token").GetString());
        }
        using var response = await client.SendAsync(request);
        var bytes = await response.Content.ReadAsByteArrayAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Functional sweep: {method} {path} returned {(int)response.StatusCode}: {System.Text.Encoding.UTF8.GetString(bytes)[..Math.Min(bytes.Length, 300)]}");
        if (response.Content.Headers.ContentEncoding.Contains("br"))
        {
            using var decoded = new MemoryStream();
            await using (var brotli = new BrotliStream(new MemoryStream(bytes), CompressionMode.Decompress)) await brotli.CopyToAsync(decoded);
            bytes = decoded.ToArray();
            checks.Add("brotli " + path.Split('?')[0]);
        }
        checks.Add($"{method} {path.Split('?')[0]} {(int)response.StatusCode}");
        return bytes.Length == 0 ? JsonDocument.Parse("{}") : JsonDocument.Parse(bytes);
    }

    using (await SendAsync(HttpMethod.Get, "/api/v1/auth/me")) { }
    using (await SendAsync(HttpMethod.Get, "/api/v1/profiles", token: deviceToken)) { }
    using (var page = await SendAsync(HttpMethod.Get, $"/api/v1/catalog/items?offset=0&limit={(largePages ? 500 : 200)}", encoding: "br"))
        if (page.RootElement.GetProperty("items").GetArrayLength() != (largePages ? 500 : 200)) throw new InvalidOperationException("Functional sweep: short catalog page.");
    foreach (var path in new[]
    {
        "/api/v1/home", "/api/v1/catalog/movies?offset=0&limit=50", "/api/v1/catalog/series?offset=0&limit=50",
        $"/api/v1/catalog/series/{seriesId}", $"/api/v1/catalog/items/{movieId}", "/api/v1/catalog/collections",
        "/api/v1/catalog/search?query=Synthetic&offset=0&limit=20", $"/api/v1/media/{movieId}/playback-plan",
        "/api/v1/sync/changes?after=0&waitSeconds=0",
    })
        using (await SendAsync(HttpMethod.Get, path, encoding: "br, gzip")) { }
    using (await SendAsync(HttpMethod.Put, $"/api/v1/media/{movieId}/favorite", new SetFavoriteRequest(true))) { }
    using (await SendAsync(HttpMethod.Put, $"/api/v1/media/{movieId}/favorite", new SetFavoriteRequest(false))) { }
    using (await SendAsync(HttpMethod.Put, $"/api/v1/media/{movieId}/progress", new UpdatePlaybackProgressRequest(60_000, 7_200_000, false))) { }
    using (await SendAsync(HttpMethod.Get, $"/api/v1/media/{movieId}/progress")) { }
    using (var state = await SendAsync(HttpMethod.Get, $"/api/v1/media/{movieId}/watch-state"))
    {
        var response = state.Deserialize<WatchStateResponse>(json)!;
        using (await SendAsync(HttpMethod.Put, $"/api/v1/media/{movieId}/watch-state",
            new SetWatchStateRequest(true, response.Scope, response.SeasonNumber, response.StateToken, Guid.NewGuid()))) { }
    }
    using (await SendAsync(HttpMethod.Put, $"/api/v1/media/{movieId}/notes/{Guid.NewGuid()}", new SaveSceneNoteRequest(1_000, null, "Synthetic note", 0))) { }
    using (await SendAsync(HttpMethod.Get, $"/api/v1/media/{movieId}/notes")) { }

    using (await SendAsync(HttpMethod.Post, "/api/v1/management/unlock", new UnlockManagementRequest(password))) { }
    foreach (var path in new[]
    {
        "/api/v1/server/status", "/api/v1/server/users", "/api/v1/server/diagnostics", "/api/v1/server/diagnostics/export",
        "/api/v1/server/jobs", "/api/v1/server/capabilities", "/api/v1/libraries", "/api/v1/metadata/provider",
        "/api/v1/metadata/jobs", "/api/v1/auth/sessions", "/api/v1/users",
    })
        using (await SendAsync(HttpMethod.Get, path)) { }
    using (var settings = await SendAsync(HttpMethod.Get, "/api/v1/server/settings"))
    {
        var stored = settings.RootElement.GetProperty("stored").Deserialize<JsonElement>();
        using (await SendAsync(HttpMethod.Put, "/api/v1/server/settings", stored, approval: true)) { }
    }
    using (await SendAsync(HttpMethod.Post, "/api/v1/server/backups/database", approval: true)) { }
    using (var backups = await SendAsync(HttpMethod.Get, "/api/v1/server/backups"))
    {
        var name = backups.RootElement.EnumerateArray().First().GetProperty("name").GetString();
        using (await SendAsync(HttpMethod.Post, $"/api/v1/server/backups/{name}/verify", approval: true)) { }
    }
    using (var created = await SendAsync(HttpMethod.Post, "/api/v1/users",
        new CreateUserRequest("sweep-viewer", null, UserRole.User, "2468", true, ProfileAccessMode.EntireLibrary), approval: true))
    {
        var id = created.RootElement.TryGetProperty("user", out var user) ? user.GetProperty("id").GetString() : created.RootElement.GetProperty("id").GetString();
        using (await SendAsync(HttpMethod.Delete, $"/api/v1/users/{id}", approval: true)) { }
    }
    using (var collection = await SendAsync(HttpMethod.Post, "/api/v1/collections", new SaveCollectionRequest("Sweep", [Guid.Parse(movieId), Guid.Parse(seriesId)])))
        using (await SendAsync(HttpMethod.Delete, $"/api/v1/collections/{collection.RootElement.GetProperty("id").GetString()}")) { }
    return checks;
}

static async Task<double> StartupAsync(string executable, string seed, string directory)
{
    PrivateFilePermissions.CreatePrivateDirectory(directory);
    File.Copy(Path.Combine(seed, "aurelia.db"), Path.Combine(directory, "aurelia.db"));
    using var reservation = new TcpListener(IPAddress.Loopback, 0);
    reservation.Start();
    var port = ((IPEndPoint)reservation.LocalEndpoint).Port;
    reservation.Stop();
    using var process = new Process { StartInfo = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, WorkingDirectory = directory } };
    process.StartInfo.ArgumentList.Add("run"); process.StartInfo.ArgumentList.Add("--data-dir"); process.StartInfo.ArgumentList.Add(directory);
    process.StartInfo.ArgumentList.Add("--urls"); process.StartInfo.ArgumentList.Add("http://127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture));
    process.StartInfo.Environment["AURELIA_LAN_ENABLED"] = "false";
    process.StartInfo.Environment["Logging__LogLevel__Default"] = "Warning";
    process.OutputDataReceived += (_, _) => { };
    process.ErrorDataReceived += (_, _) => { };
    var watch = Stopwatch.StartNew();
    process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
    try
    {
        using var client = new HttpClient { BaseAddress = new Uri("http://127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture)), Timeout = TimeSpan.FromSeconds(5) };
        while (watch.Elapsed < TimeSpan.FromSeconds(60))
        {
            if (process.HasExited) throw new InvalidOperationException("Synthetic server exited during startup.");
            try { using var response = await client.GetAsync("/api/v1/server/info"); if (response.IsSuccessStatusCode) return watch.Elapsed.TotalMilliseconds; }
            catch (HttpRequestException) { }
            await Task.Delay(20);
        }
        throw new TimeoutException("Synthetic server did not start.");
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
