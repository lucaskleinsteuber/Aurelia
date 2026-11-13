using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Aurelia.Contracts;
using Microsoft.AspNetCore.Routing;

namespace Aurelia.Server.Services;

/// <summary>
/// Measures the server itself (Settings › Server Health › Performance): response times per
/// endpoint in hourly buckets and the slowest database queries, kept seven days. It stores route
/// templates and SQL without values only: never URLs with their contents, parameters, bodies,
/// titles or file paths. Saved in <c>server-performance.json</c> in the data folder.
/// </summary>
public sealed partial class ServerPerformanceStore(
    ServerRuntimeOptions runtime,
    TimeProvider? timeProvider = null) : BackgroundService
{
    public const int SlowRequestMilliseconds = 500;
    public const int SlowQueryMilliseconds = 100;
    public static readonly TimeSpan Retention = TimeSpan.FromDays(7);
    public static readonly TimeSpan WarmUp = TimeSpan.FromSeconds(60);
    internal const int MaximumEndpoints = 400;
    internal const int MaximumSlowQueries = 200;
    internal const int MaximumStatementLength = 400;
    internal const string QueryCountItem = "Aurelia.QueryCount";

    // Upper edges of the timing buckets in milliseconds; the last bucket is everything slower.
    internal static readonly double[] Edges = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 30000];

    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly object gate = new();
    private readonly Dictionary<(string Key, long Hour), Bucket> buckets = [];
    private readonly LinkedList<ServerSlowQuery> slowQueries = new();
    private readonly SemaphoreSlim flushGate = new(1, 1);
    private DateTimeOffset since = DateTimeOffset.MinValue;
    private DateTimeOffset started = DateTimeOffset.MinValue;
    private bool dirty;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private string PathName => Path.Combine(runtime.DataDirectory, "server-performance.json");

    internal sealed class Bucket
    {
        public long Count { get; set; }
        public long Errors { get; set; }
        public long Slow { get; set; }
        public double MaxMilliseconds { get; set; }
        public long Queries { get; set; }
        public long[] Histogram { get; set; } = new long[Edges.Length + 1];
    }

    private sealed record Saved(DateTimeOffset Since, List<SavedBucket> Buckets, List<ServerSlowQuery> SlowQueries);
    private sealed record SavedBucket(string Key, long Hour, long Count, long Errors, long Slow, double MaxMilliseconds, long Queries, long[] Histogram);

    /// <summary>Requests that stay open on purpose (streams, long polls, backup transfers) are not timed.</summary>
    public static bool Measures(HttpRequest request)
    {
        var path = request.Path.Value ?? string.Empty;
        if (!path.StartsWith("/api/v1/", StringComparison.OrdinalIgnoreCase)) return false;
        if (path.StartsWith("/api/v1/streams/", StringComparison.OrdinalIgnoreCase)
            || path.StartsWith("/api/v1/sync/changes", StringComparison.OrdinalIgnoreCase)
            || path.StartsWith("/api/v1/devices/player/commands", StringComparison.OrdinalIgnoreCase)
            || path.StartsWith("/api/v1/server/backups/uploads/", StringComparison.OrdinalIgnoreCase)
            || path.StartsWith("/api/v1/server/backups/transfers/", StringComparison.OrdinalIgnoreCase)
            || path.StartsWith("/api/v1/server/security/alerts", StringComparison.OrdinalIgnoreCase))
            return false;
        foreach (var name in new[] { "waitMs", "waitSeconds" })
            if (request.Query.TryGetValue(name, out var wait) && int.TryParse(wait, out var value) && value > 0) return false;
        return true;
    }

    /// <summary>"GET /api/v1/catalog/items/{mediaId:guid}", or null for a request without a route.</summary>
    public static string? EndpointKey(HttpContext context) =>
        context.GetEndpoint() is RouteEndpoint { RoutePattern.RawText: { } template }
            ? context.Request.Method.ToUpperInvariant() + " " + (template.StartsWith('/') ? template : "/" + template)
            : null;

    public void RecordRequest(string key, double milliseconds, int status, long queries)
    {
        if (string.IsNullOrEmpty(key) || !double.IsFinite(milliseconds) || milliseconds < 0) return;
        var now = clock.GetUtcNow();
        var hour = now.ToUnixTimeSeconds() / 3600;
        lock (gate)
        {
            if (since == DateTimeOffset.MinValue) since = now;
            if (!buckets.TryGetValue((key, hour), out var bucket))
            {
                if (buckets.Keys.Select(value => value.Key).Distinct().Count() >= MaximumEndpoints
                    && !buckets.Keys.Any(value => value.Key == key)) return;
                bucket = new Bucket();
                buckets[(key, hour)] = bucket;
            }
            bucket.Count++;
            if (status >= 500) bucket.Errors++;
            if (milliseconds >= SlowRequestMilliseconds) bucket.Slow++;
            bucket.MaxMilliseconds = Math.Max(bucket.MaxMilliseconds, milliseconds);
            bucket.Queries += Math.Max(0, queries);
            bucket.Histogram[BucketIndex(milliseconds)]++;
            dirty = true;
        }
    }

    public void RecordQuery(double milliseconds, string? commandText, string? endpoint)
    {
        if (milliseconds < SlowQueryMilliseconds || !double.IsFinite(milliseconds)) return;
        var now = clock.GetUtcNow();
        var statement = Sanitize(commandText);
        lock (gate)
        {
            if (since == DateTimeOffset.MinValue) since = now;
            var warm = started != DateTimeOffset.MinValue && now - started < WarmUp;
            slowQueries.AddFirst(new ServerSlowQuery(now, Math.Round(milliseconds, 1), Kind(statement), statement, endpoint, warm));
            while (slowQueries.Count > MaximumSlowQueries) slowQueries.RemoveLast();
            dirty = true;
        }
    }

    public ServerPerformanceResponse Read()
    {
        var oldest = (clock.GetUtcNow() - Retention).ToUnixTimeSeconds() / 3600;
        lock (gate)
        {
            var endpoints = buckets.Where(entry => entry.Key.Hour >= oldest)
                .GroupBy(entry => entry.Key.Key)
                .Select(group =>
                {
                    var histogram = new long[Edges.Length + 1];
                    long count = 0, errors = 0, slow = 0, queries = 0;
                    double max = 0;
                    foreach (var (_, bucket) in group)
                    {
                        count += bucket.Count;
                        errors += bucket.Errors;
                        slow += bucket.Slow;
                        queries += bucket.Queries;
                        max = Math.Max(max, bucket.MaxMilliseconds);
                        for (var index = 0; index < histogram.Length; index++) histogram[index] += bucket.Histogram[index];
                    }
                    var space = group.Key.IndexOf(' ');
                    return new ServerEndpointTiming(group.Key[..space], group.Key[(space + 1)..], count, errors, slow,
                        Percentile(histogram, 0.5, max), Percentile(histogram, 0.95, max), Math.Round(max, 1),
                        count == 0 ? 0 : Math.Round((double)queries / count, 1));
                })
                .OrderByDescending(value => value.P95Milliseconds).ThenByDescending(value => value.Count)
                .ToArray();
            var all = new long[Edges.Length + 1];
            foreach (var (key, bucket) in buckets)
                if (key.Hour >= oldest)
                    for (var index = 0; index < all.Length; index++) all[index] += bucket.Histogram[index];
            var overallMax = endpoints.Length == 0 ? 0 : endpoints.Max(value => value.MaxMilliseconds);
            return new ServerPerformanceResponse(
                since == DateTimeOffset.MinValue ? clock.GetUtcNow() : since,
                SlowRequestMilliseconds, SlowQueryMilliseconds, all.Sum(), Percentile(all, 0.95, overallMax),
                endpoints, slowQueries.ToArray());
        }
    }

    /// <summary>Forgets every measurement (Reset Measurements).</summary>
    public void Reset()
    {
        lock (gate)
        {
            buckets.Clear();
            slowQueries.Clear();
            since = clock.GetUtcNow();
            dirty = true;
        }
    }

    internal static int BucketIndex(double milliseconds)
    {
        for (var index = 0; index < Edges.Length; index++)
            if (milliseconds <= Edges[index]) return index;
        return Edges.Length;
    }

    /// <summary>The value below which <paramref name="quantile"/> of the requests fell, interpolated inside its bucket.</summary>
    internal static double Percentile(long[] histogram, double quantile, double max)
    {
        var total = histogram.Sum();
        if (total == 0) return 0;
        var target = quantile * total;
        double seen = 0;
        for (var index = 0; index < histogram.Length; index++)
        {
            if (histogram[index] == 0) continue;
            if (seen + histogram[index] >= target)
            {
                var lower = index == 0 ? 0 : Edges[index - 1];
                var upper = index < Edges.Length ? Edges[index] : Math.Max(max, lower);
                var share = (target - seen) / histogram[index];
                return Math.Round(Math.Min(max > 0 ? max : upper, lower + (upper - lower) * share), 1);
            }
            seen += histogram[index];
        }
        return Math.Round(max, 1);
    }

    /// <summary>
    /// The statement without anything that could hold a value: quoted text and numbers become ?,
    /// whitespace collapses, and it is cut to <see cref="MaximumStatementLength"/> characters.
    /// EF Core already sends values as parameters (@p0, @__id_0), which are kept as names.
    /// </summary>
    internal static string Sanitize(string? commandText)
    {
        if (string.IsNullOrWhiteSpace(commandText)) return string.Empty;
        var text = QuotedText().Replace(commandText, "?");
        text = BlobLiteral().Replace(text, "?");
        text = NumberLiteral().Replace(text, "?");
        text = Whitespace().Replace(text, " ").Trim();
        if (text.Length > MaximumStatementLength) text = text[..MaximumStatementLength] + "…";
        return text;
    }

    internal static string Kind(string statement)
    {
        var first = statement.TrimStart().Split(' ', 2)[0].ToUpperInvariant();
        return first switch
        {
            "SELECT" or "WITH" => "SELECT",
            "INSERT" => "INSERT",
            "UPDATE" => "UPDATE",
            "DELETE" => "DELETE",
            _ => "OTHER",
        };
    }

    [GeneratedRegex(@"'(?:[^']|'')*'")]
    private static partial Regex QuotedText();
    [GeneratedRegex(@"\b[xX]'[0-9A-Fa-f]*'")]
    private static partial Regex BlobLiteral();
    [GeneratedRegex(@"(?<![\w@$.""\]])-?\d+(?:\.\d+)?\b")]
    private static partial Regex NumberLiteral();
    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        lock (gate) started = clock.GetUtcNow();
        await LoadAsync(stoppingToken);
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromMinutes(2), clock, stoppingToken);
                await FlushAsync(stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        finally { await FlushAsync(CancellationToken.None); }
    }

    internal async Task LoadAsync(CancellationToken token)
    {
        try
        {
            var file = new FileInfo(PathName);
            if (!file.Exists || file.Length > 8 * 1024 * 1024 || file.LinkTarget is not null) return;
            var saved = JsonSerializer.Deserialize<Saved>(await File.ReadAllTextAsync(PathName, token), Json);
            if (saved is null) return;
            lock (gate)
            {
                if (since == DateTimeOffset.MinValue || saved.Since < since) since = saved.Since;
                foreach (var entry in saved.Buckets.Take(MaximumEndpoints * 24 * 7))
                {
                    if (entry.Histogram.Length != Edges.Length + 1 || string.IsNullOrEmpty(entry.Key) || !entry.Key.Contains(' ')) continue;
                    buckets.TryAdd((entry.Key, entry.Hour), new Bucket
                    {
                        Count = entry.Count,
                        Errors = entry.Errors,
                        Slow = entry.Slow,
                        MaxMilliseconds = entry.MaxMilliseconds,
                        Queries = entry.Queries,
                        Histogram = entry.Histogram,
                    });
                }
                foreach (var query in saved.SlowQueries.Take(MaximumSlowQueries))
                    slowQueries.AddLast(query with { Statement = Sanitize(query.Statement) });
                while (slowQueries.Count > MaximumSlowQueries) slowQueries.RemoveLast();
            }
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { }
    }

    internal async Task FlushAsync(CancellationToken token)
    {
        await flushGate.WaitAsync(token);
        try
        {
            Saved snapshot;
            var now = clock.GetUtcNow();
            var oldest = (now - Retention).ToUnixTimeSeconds() / 3600;
            lock (gate)
            {
                var stale = buckets.Keys.Where(key => key.Hour < oldest).ToArray();
                foreach (var key in stale) buckets.Remove(key);
                while (slowQueries.Last is { } last && last.Value.At < now - Retention) slowQueries.RemoveLast();
                if (since != DateTimeOffset.MinValue && since < now - Retention) since = now - Retention;
                dirty |= stale.Length > 0;
                if (!dirty) return;
                snapshot = new Saved(since == DateTimeOffset.MinValue ? now : since,
                    buckets.Select(entry => new SavedBucket(entry.Key.Key, entry.Key.Hour, entry.Value.Count, entry.Value.Errors,
                        entry.Value.Slow, entry.Value.MaxMilliseconds, entry.Value.Queries, entry.Value.Histogram.ToArray())).ToList(),
                    slowQueries.ToList());
                dirty = false;
            }
            var temporary = PathName + "." + Guid.NewGuid().ToString("N") + ".pending";
            try
            {
                await using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporary))
                    await JsonSerializer.SerializeAsync(file, snapshot, Json, token);
                File.Move(temporary, PathName, true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                lock (gate) dirty = true;
            }
            finally
            {
                try { if (File.Exists(temporary)) File.Delete(temporary); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            }
        }
        finally { flushGate.Release(); }
    }
}
