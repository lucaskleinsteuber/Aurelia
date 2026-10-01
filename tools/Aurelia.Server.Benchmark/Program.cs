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
        creditsPerEntry = 8,
        clients = 2,
        requestsPerEndpoint = 20,
        methodology = "Same synthetic SQLite snapshot, 3 warmups, then 20 requests per endpoint in two concurrent clients. No videos, personal data, or artwork files. CPU is process CPU during measurement; RSS sampled every 20 ms. SQL counts use EF command logs (raw FTS commands are excluded). One local Mac run; not a throughput or production guarantee.",
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
    // Both versions start at the previous schema, with identical data and FTS.
    await database.GetService<IMigrator>().MigrateAsync("20260923135149_Build18TrailerImportReview");
    await new MediaSearchIndexService(database).RebuildAsync(CancellationToken.None);
    await database.Database.ExecuteSqlRawAsync("PRAGMA wal_checkpoint(TRUNCATE);");
}

static async Task<object> MeasureAsync(string executable, string seed, string directory)
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
    process.StartInfo.Environment["Logging__LogLevel__Microsoft.EntityFrameworkCore.Database.Command"] = "Information";
    var commands = 0L;
    var logTail = new Queue<string>();
    process.OutputDataReceived += (_, entry) => { if (entry.Data?.Contains("Executed DbCommand", StringComparison.Ordinal) == true) Interlocked.Increment(ref commands); };
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
        var measurements = new List<object>();
        foreach (var path in new[] { "/api/v1/catalog/items?kind=movie&offset=0&limit=100", "/api/v1/catalog/search?query=Synthetic&offset=0&limit=100", "/api/v1/home" })
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
