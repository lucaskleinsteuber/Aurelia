using System.Collections;
using System.Data;
using System.Data.Common;
using System.Diagnostics;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Xunit;
using Xunit.Abstractions;

namespace Aurelia.Server.Tests;

public sealed class CatalogBenchmarkTests(ITestOutputHelper output)
{
    [BenchmarkTheory]
    [Trait("Category", "Benchmark")]
    [InlineData(1_000)]
    [InlineData(10_000)]
    [InlineData(50_000)]
    public async Task BoundedCatalogQueriesWithLargeSyntheticSeries(int mediaCount)
    {
        var root = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(root);
        try
        {
            await using var connection = new SqliteConnection($"Data Source={Path.Combine(root, "benchmark.db")}");
            await connection.OpenAsync();
            connection.CreateFunction("seed_id", (int value) => Id(value).ToString().ToUpperInvariant());
            var counter = new QueryCounter();
            var options = new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite(connection).AddInterceptors(counter).Options;
            await using var database = new AureliaDbContext(options);
            await database.Database.MigrateAsync();
            var owner = new ServerUser { Id = Id(-1), Username = "Synthetic", NormalizedUsername = "SYNTHETIC", PasswordHash = "synthetic-only", Role = UserRole.Owner, AccessMode = ProfileAccessMode.EntireLibrary };
            var library = new LibraryRoot { Id = Id(-2), Name = "Synthetic", Path = root, NormalizedPath = root, MonitoringEnabled = false, Availability = LibraryAvailability.Available };
            database.Users.Add(owner);
            database.LibraryRoots.Add(library);
            for (var index = 1; index <= 50; index++)
                database.MediaItems.Add(new MediaItem
                {
                    Id = Id(index),
                    LibraryRoot = library,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Series,
                    DetectedTitle = $"Benchmark series {index:D3}",
                    SourcePath = Path.Combine(root, $"Series{index}"),
                    NormalizedSourcePath = $"SERIES{index}",
                    Availability = MediaAvailability.Available
                });
            await database.SaveChangesAsync();
            // Measure reads rather than bulk-seed/index construction time.
            foreach (var trigger in IncrementalSearchIndex.Triggers())
            {
                var drop = "DROP TRIGGER IF EXISTS " + trigger.Name + ";";
                await database.Database.ExecuteSqlRawAsync(drop);
            }
            await database.Database.ExecuteSqlInterpolatedAsync($"""
                WITH RECURSIVE source(n) AS (SELECT 51 UNION ALL SELECT n+1 FROM source WHERE n < {mediaCount})
                INSERT INTO MediaItems(Id,LibraryRootId,ParentId,Kind,SourcePath,NormalizedSourcePath,DetectedTitle,Category,Availability,CreatedAt,UpdatedAt,ManualSourceBinding,SeasonNumber,EpisodeNumber)
                SELECT seed_id(n),{library.Id},seed_id(1+((n-51)%50)),'Episode','synthetic/'||n,'SYNTHETIC/'||n,'Episode '||n,'','Available',0,0,0,1,1+((n-51)/50) FROM source;
                """);
            await new MediaSearchIndexService(database).RebuildAsync(default);
            foreach (var trigger in IncrementalSearchIndex.Triggers())
                await database.Database.ExecuteSqlRawAsync(trigger.Sql);
            for (var index = 51; index <= 100; index++)
                database.PlaybackProgress.Add(new PlaybackProgress { Id = Id(-100 - index), UserId = owner.Id, User = owner, MediaItemId = Id(index), MediaItem = null!, PositionMilliseconds = 45_000, DurationMilliseconds = 120_000, LastPlayedAt = DateTimeOffset.UtcNow, Revision = 1 });
            await database.SaveChangesAsync();
            database.ChangeTracker.Clear();
            var presentation = new PresentationService(database, TimeProvider.System, new MediaSearchIndexService(database));
            _ = await presentation.CatalogAsync(owner.Id, new CatalogQuery(Kind: MediaKind.Series, Limit: 20), default);
            await Measure("catalog", async () =>
            {
                var page = await presentation.CatalogAsync(owner.Id, new CatalogQuery(Kind: MediaKind.Series, Limit: 20), default);
                Assert.Equal(50, page.Total);
                Assert.Equal(20, page.Items.Count);
                return page;
            });
            await Measure("search", async () =>
            {
                var page = await presentation.SearchAsync(owner.Id, "Episode", new CatalogQuery(Limit: 20), default);
                Assert.Equal(mediaCount - 50, page.Total);
                Assert.Equal(20, page.Items.Count);
                return page;
            });
            await Measure("home", async () =>
            {
                var home = await presentation.HomeAsync(owner.Id, default);
                Assert.Equal(20, home.ContinueWatching.Count);
                return home;
            });

            async Task Measure(string operation, Func<Task<object>> read)
            {
                counter.Reset();
                var allocated = GC.GetTotalAllocatedBytes(true);
                var watch = Stopwatch.StartNew();
                var result = await read();
                watch.Stop();
                var bytes = GC.GetTotalAllocatedBytes(true) - allocated;
                Assert.True(counter.Rows < 500, $"{operation} materialized {counter.Rows} rows for a bounded response.");
                output.WriteLine("CATALOG_BENCHMARK " + JsonSerializer.Serialize(new { mediaCount, operation, counter.Commands, counter.Rows, milliseconds = watch.Elapsed.TotalMilliseconds, allocatedBytes = bytes, responseBytes = JsonSerializer.SerializeToUtf8Bytes(result).Length }));
                if (mediaCount == 1000)
                    foreach (var captured in counter.Queries)
                    {
                        await using var explain = connection.CreateCommand();
                        explain.CommandText = "EXPLAIN QUERY PLAN " + captured.Sql;
                        foreach (var parameter in captured.Parameters) explain.Parameters.AddWithValue(parameter.Name, parameter.Value);
                        await using var reader = await explain.ExecuteReaderAsync();
                        var plan = new List<string>();
                        while (await reader.ReadAsync()) plan.Add(reader.GetString(3));
                        output.WriteLine("CATALOG_QUERY_PLAN " + JsonSerializer.Serialize(new { operation, plan }));
                    }
            }
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static Guid Id(int value) => new(value, 0, 0, new byte[8]);

    private sealed class QueryCounter : DbCommandInterceptor
    {
        public int Commands { get; private set; }
        public int Rows { get; private set; }
        public List<(string Sql, List<(string Name, object Value)> Parameters)> Queries { get; } = [];
        public void Reset() { Commands = 0; Rows = 0; Queries.Clear(); }
        private void Capture(DbCommand command)
        {
            Commands++;
            Queries.Add((command.CommandText, command.Parameters.Cast<DbParameter>().Select(value => (value.ParameterName, value.Value ?? DBNull.Value)).ToList()));
        }
        public override DbDataReader ReaderExecuted(DbCommand command, CommandExecutedEventData eventData, DbDataReader result)
        { Capture(command); return new CountingReader(result, () => Rows++); }
        public override ValueTask<DbDataReader> ReaderExecutedAsync(DbCommand command, CommandExecutedEventData eventData, DbDataReader result, CancellationToken cancellationToken = default)
        { Capture(command); return ValueTask.FromResult<DbDataReader>(new CountingReader(result, () => Rows++)); }
    }

    private sealed class CountingReader(DbDataReader inner, Action read) : DbDataReader
    {
        public override bool Read() { var found = inner.Read(); if (found) read(); return found; }
        public override async Task<bool> ReadAsync(CancellationToken cancellationToken) { var found = await inner.ReadAsync(cancellationToken); if (found) read(); return found; }
        public override int Depth => inner.Depth;
        public override int FieldCount => inner.FieldCount;
        public override bool HasRows => inner.HasRows;
        public override bool IsClosed => inner.IsClosed;
        public override int RecordsAffected => inner.RecordsAffected;
        public override object this[int ordinal] => inner[ordinal];
        public override object this[string name] => inner[name];
        public override bool NextResult() => inner.NextResult();
        public override Task<bool> NextResultAsync(CancellationToken cancellationToken) => inner.NextResultAsync(cancellationToken);
        public override string GetName(int ordinal) => inner.GetName(ordinal);
        public override string GetDataTypeName(int ordinal) => inner.GetDataTypeName(ordinal);
        public override Type GetFieldType(int ordinal) => inner.GetFieldType(ordinal);
        public override object GetValue(int ordinal) => inner.GetValue(ordinal);
        public override int GetValues(object[] values) => inner.GetValues(values);
        public override int GetOrdinal(string name) => inner.GetOrdinal(name);
        public override bool GetBoolean(int ordinal) => inner.GetBoolean(ordinal);
        public override byte GetByte(int ordinal) => inner.GetByte(ordinal);
        public override long GetBytes(int ordinal, long dataOffset, byte[]? buffer, int bufferOffset, int length) => inner.GetBytes(ordinal, dataOffset, buffer, bufferOffset, length);
        public override char GetChar(int ordinal) => inner.GetChar(ordinal);
        public override long GetChars(int ordinal, long dataOffset, char[]? buffer, int bufferOffset, int length) => inner.GetChars(ordinal, dataOffset, buffer, bufferOffset, length);
        public override Guid GetGuid(int ordinal) => inner.GetGuid(ordinal);
        public override short GetInt16(int ordinal) => inner.GetInt16(ordinal);
        public override int GetInt32(int ordinal) => inner.GetInt32(ordinal);
        public override long GetInt64(int ordinal) => inner.GetInt64(ordinal);
        public override float GetFloat(int ordinal) => inner.GetFloat(ordinal);
        public override double GetDouble(int ordinal) => inner.GetDouble(ordinal);
        public override string GetString(int ordinal) => inner.GetString(ordinal);
        public override decimal GetDecimal(int ordinal) => inner.GetDecimal(ordinal);
        public override DateTime GetDateTime(int ordinal) => inner.GetDateTime(ordinal);
        public override bool IsDBNull(int ordinal) => inner.IsDBNull(ordinal);
        public override IEnumerator GetEnumerator() => ((IEnumerable)inner).GetEnumerator();
        public override DataTable? GetSchemaTable() => inner.GetSchemaTable();
        public override void Close() => inner.Close();
        protected override void Dispose(bool disposing) { if (disposing) inner.Dispose(); base.Dispose(disposing); }
        public override async ValueTask DisposeAsync() { await inner.DisposeAsync(); await base.DisposeAsync(); }
    }
}
