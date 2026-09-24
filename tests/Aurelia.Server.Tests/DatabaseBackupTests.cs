using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class DatabaseBackupTests
{
    [Fact]
    public async Task RestoreCommandRequiresConfirmationAndAnAvailableServerLock()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var sourcePath = Path.Combine(dataDirectory, "candidate-backup.db");
        var arguments = new[]
        {
            "database",
            "restore",
            "--from",
            sourcePath,
            "--data-dir",
            dataDirectory,
        };

        try
        {
            var runtime = ServerRuntimeOptions.Resolve(
                new ConfigurationBuilder().Build(),
                arguments);
            var unconfirmed = await DatabaseCommandClient.RunAsync(
                ServerCommandLine.Parse(arguments),
                runtime,
                CancellationToken.None);
            Assert.Equal(2, unconfirmed);

            await File.WriteAllTextAsync(sourcePath, "not a valid database");
            using (ServerInstanceLock.Acquire(dataDirectory))
            {
                string[] confirmedArguments = [.. arguments, "--confirm"];
                var serverRunning = await DatabaseCommandClient.RunAsync(
                    ServerCommandLine.Parse(confirmedArguments),
                    runtime,
                    CancellationToken.None);
                Assert.Equal(1, serverRunning);
            }

            Assert.False(File.Exists(Path.Combine(dataDirectory, ".database-restore.pending")));
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task ScheduledBackupsKeepSevenDailyAndFourWeeklySnapshots()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var databasePath = Path.Combine(dataDirectory, "aurelia.db");
        var options = new DbContextOptionsBuilder<AureliaDbContext>()
            .UseSqlite($"Data Source={databasePath}")
            .Options;

        try
        {
            await using (var database = new AureliaDbContext(options))
            {
                await database.Database.MigrateAsync();
                await database.Database.ExecuteSqlRawAsync("PRAGMA journal_mode=WAL;");
            }

            var runtime = ServerRuntimeOptions.Resolve(
                new ConfigurationBuilder().Build(),
                ["--data-dir", dataDirectory]);
            var backups = new DatabaseBackupService(runtime);
            var now = DateTimeOffset.UtcNow;
            Assert.NotNull(await backups.CreateScheduledBackupIfDueAsync(now, CancellationToken.None));
            Assert.Null(await backups.CreateScheduledBackupIfDueAsync(
                now.AddMinutes(10),
                CancellationToken.None));

            for (var index = 0; index < 8; index += 1)
            {
                var path = await backups.CreateBackupAsync(
                    DatabaseBackupKind.Daily,
                    CancellationToken.None);
                File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddDays(-index));
                await Task.Delay(2);
            }

            for (var index = 0; index < 5; index += 1)
            {
                var path = await backups.CreateBackupAsync(
                    DatabaseBackupKind.Weekly,
                    CancellationToken.None);
                File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddDays(-index));
                await Task.Delay(2);
            }

            Assert.Equal(7, Directory.EnumerateFiles(
                backups.BackupDirectory,
                "aurelia-database-daily-*.db").Count());
            Assert.Equal(4, Directory.EnumerateFiles(
                backups.BackupDirectory,
                "aurelia-database-weekly-*.db").Count());

            if (!OperatingSystem.IsWindows())
            {
                Assert.Equal(
                    UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute,
                    File.GetUnixFileMode(backups.BackupDirectory));
                foreach (var path in Directory.EnumerateFiles(backups.BackupDirectory, "*.db"))
                {
                    Assert.Equal(
                        UnixFileMode.UserRead | UnixFileMode.UserWrite,
                        File.GetUnixFileMode(path));
                }
            }
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task BackupIncludesCommittedWalAndInterruptedExplicitRestoreCanResume()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        var databasePath = Path.Combine(dataDirectory, "aurelia.db");
        var runtime = ServerRuntimeOptions.Resolve(
            new ConfigurationBuilder().Build(),
            ["--data-dir", dataDirectory]);
        string backupPath;

        try
        {
            using (var factory = new AureliaServerFactory(dataDirectory))
            using (var client = factory.CreateClient())
            {
                _ = await ApiTestClient.SetupOwnerAsync(client);
                await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
                {
                    DataSource = databasePath,
                    Mode = SqliteOpenMode.ReadWrite,
                    Cache = SqliteCacheMode.Shared,
                    Pooling = false,
                }.ToString()))
                {
                    await connection.OpenAsync();
                    await using var update = connection.CreateCommand();
                    update.CommandText = "PRAGMA wal_autocheckpoint=0; UPDATE Users SET Username='wal-snapshot-marker';";
                    await update.ExecuteNonQueryAsync();
                    Assert.True(File.Exists(databasePath + "-wal"));
                    Assert.True(new FileInfo(databasePath + "-wal").Length > 0);
                }

                var backups = factory.Services.GetRequiredService<DatabaseBackupService>();
                backupPath = await backups.CreateBackupAsync(
                    DatabaseBackupKind.Manual,
                    CancellationToken.None);
                var verification = await backups.VerifyAsync(backupPath, CancellationToken.None);
                Assert.True(verification.IsValid, verification.Message);
                Assert.Equal("wal-snapshot-marker", await ReadUsernameAsync(backupPath));
            }

            var backupService = new DatabaseBackupService(runtime);
            using (ServerInstanceLock.Acquire(dataDirectory))
            {
                await SetUsernameAsync(databasePath, "changed-after-backup");
                await backupService.RestoreAsync(backupPath, CancellationToken.None);
            }

            Assert.Equal("wal-snapshot-marker", await ReadUsernameAsync(databasePath));
            Assert.Single(Directory.EnumerateFiles(
                Path.Combine(dataDirectory, "Backups"),
                "aurelia-database-pre-restore-*.db"));

            var restoreStagePath = Path.Combine(dataDirectory, ".database-restore.pending.db");
            var restoreMarkerPath = Path.Combine(dataDirectory, ".database-restore.pending");
            await SetUsernameAsync(databasePath, "changed-before-interrupted-restore");
            File.Copy(backupPath, restoreStagePath);
            await File.WriteAllTextAsync(restoreMarkerPath, "restore-pending-v1");
            using (ServerInstanceLock.Acquire(dataDirectory))
            {
                await backupService.RecoverPendingRestoreAsync(CancellationToken.None);
            }

            Assert.False(File.Exists(restoreStagePath));
            Assert.False(File.Exists(restoreMarkerPath));
            var restored = await backupService.VerifyAsync(databasePath, CancellationToken.None);
            Assert.True(restored.IsValid, restored.Message);
            Assert.Equal("wal-snapshot-marker", await ReadUsernameAsync(databasePath));

            var invalidBackup = Path.Combine(dataDirectory, "not-a-database.db");
            await File.WriteAllTextAsync(invalidBackup, "not sqlite");
            var invalidResult = await backupService.VerifyAsync(invalidBackup, CancellationToken.None);
            Assert.False(invalidResult.IsValid);
            using (ServerInstanceLock.Acquire(dataDirectory))
            {
                await Assert.ThrowsAsync<InvalidOperationException>(async () =>
                    await backupService.RestoreAsync(invalidBackup, CancellationToken.None));
            }

            Assert.Equal("wal-snapshot-marker", await ReadUsernameAsync(databasePath));
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    private static async Task<string> ReadUsernameAsync(string databasePath)
    {
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        }.ToString());
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT Username FROM Users LIMIT 1;";
        return (string?)await command.ExecuteScalarAsync()
            ?? throw new InvalidOperationException("The synthetic database had no user.");
    }

    private static async Task SetUsernameAsync(string databasePath, string username)
    {
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWrite,
            Pooling = false,
        }.ToString());
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "UPDATE Users SET Username=$username;";
        command.Parameters.AddWithValue("$username", username);
        await command.ExecuteNonQueryAsync();
    }
}
