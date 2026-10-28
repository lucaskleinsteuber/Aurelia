using Aurelia.Server.Data;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public enum DatabaseBackupKind
{
    Manual,
    Daily,
    Weekly,
    PreMigration,
    PreRestore,
}

public sealed record DatabaseVerificationResult(
    bool IsValid,
    string Message,
    int AppliedMigrationCount);

public sealed record DatabaseBackupRuntimeStatus(bool LastAttemptFailed, DateTimeOffset? LastSucceededAt);

public sealed class DatabaseBackupService(
    ServerRuntimeOptions runtime,
    ServerConfigurationStore? configuration = null,
    ActiveStreamRegistry? activeStreams = null,
    LiveConversionService? liveConversions = null,
    Func<bool>? isBusy = null)
{
    private const string BackupPrefix = "aurelia-database-";
    private const string RestoreStageName = ".database-restore.pending.db";
    private const string RestoreMarkerName = ".database-restore.pending";
    private const string OperationLockName = ".database-backup-operation.lock";
    private static readonly TimeSpan WeeklyInterval = TimeSpan.FromDays(7);

    public string BackupDirectory => Path.Combine(runtime.DataDirectory, "Backups");
    private DatabaseBackupRuntimeStatus health = new(false, null);
    public DatabaseBackupRuntimeStatus Health => Volatile.Read(ref health);

    /// <summary>
    /// Scheduled backups run only when the server is idle. Active playback streams
    /// or active live conversions defer scheduled runs to the next maintenance interval.
    /// </summary>
    public bool IsServerBusy => isBusy?.Invoke() ?? ((activeStreams?.PlaybackCount > 0) || (liveConversions?.Running > 0));

    public async Task<string> CreateBackupAsync(
        DatabaseBackupKind kind,
        CancellationToken cancellationToken)
    {
        try
        {
            using var operationLock = AcquireOperationLock();
            var path = await CreateBackupLockedAsync(kind, cancellationToken);
            Volatile.Write(ref health, new(false, DateTimeOffset.UtcNow));
            return path;
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            Volatile.Write(ref health, new(true, Health.LastSucceededAt));
            throw;
        }
    }

    public async Task<string?> CreateScheduledBackupIfDueAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        try
        {
            var path = await CreateScheduledBackupCoreAsync(now, cancellationToken);
            if (path is not null) Volatile.Write(ref health, new(false, DateTimeOffset.UtcNow));
            return path;
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            Volatile.Write(ref health, new(true, Health.LastSucceededAt));
            throw;
        }
    }

    private async Task<string?> CreateScheduledBackupCoreAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        using var operationLock = AcquireOperationLock();
        if (configuration?.Current.AutomaticBackupsEnabled == false) return null;
        if (IsServerBusy)
        {
            return null;
        }

        if (!File.Exists(runtime.DatabasePath) || new FileInfo(runtime.DatabasePath).Length == 0)
        {
            return null;
        }

        var backups = ListBackups();
        var daily = backups
            .Where(backup => backup.Kind == DatabaseBackupKind.Daily)
            .OrderByDescending(backup => backup.CreatedAt)
            .FirstOrDefault();
        var weekly = backups
            .Where(backup => backup.Kind == DatabaseBackupKind.Weekly)
            .OrderByDescending(backup => backup.CreatedAt)
            .FirstOrDefault();
        string? latestPath = null;
        string? createdDailyPath = null;
        if (daily is null || now - daily.CreatedAt >= TimeSpan.FromHours(configuration?.Current.BackupIntervalHours ?? 24))
        {
            latestPath = await CreateBackupLockedAsync(DatabaseBackupKind.Daily, cancellationToken);
            createdDailyPath = latestPath;
        }

        if (weekly is null || now - weekly.CreatedAt >= WeeklyInterval)
        {
            if (createdDailyPath is not null && File.Exists(createdDailyPath))
            {
                // When daily was just created and verified, duplicate it as weekly to avoid a second expensive SQLite backup and verification cycle on slow hardware.
                latestPath = DuplicateVerifiedBackupLocked(createdDailyPath, DatabaseBackupKind.Weekly);
            }
            else
            {
                latestPath = await CreateBackupLockedAsync(DatabaseBackupKind.Weekly, cancellationToken);
            }
        }

        return latestPath;
    }

    private string DuplicateVerifiedBackupLocked(string sourcePath, DatabaseBackupKind targetKind)
    {
        EnsurePrivateBackupDirectory();
        var stamp = DateTimeOffset.UtcNow.ToString("yyyyMMdd'T'HHmmssfff'Z'", System.Globalization.CultureInfo.InvariantCulture);
        var finalPath = Path.Combine(BackupDirectory, $"{BackupPrefix}{KindName(targetKind)}-{stamp}.db");
        File.Copy(sourcePath, finalPath, overwrite: true);
        PrivateFilePermissions.ProtectFile(finalPath);
        ApplyRetention(targetKind);
        return finalPath;
    }

    public async Task<DatabaseVerificationResult> VerifyAsync(
        string databasePath,
        CancellationToken cancellationToken)
    {
        var fullPath = Path.GetFullPath(databasePath);
        var file = new FileInfo(fullPath);
        if (!file.Exists || file.Length == 0)
        {
            return new DatabaseVerificationResult(false, "Database file is missing or empty.", 0);
        }

        if (file.LinkTarget is not null)
        {
            return new DatabaseVerificationResult(false, "Symbolic-link database files are not accepted.", 0);
        }

        try
        {
            await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = fullPath,
                Mode = SqliteOpenMode.ReadOnly,
                ForeignKeys = true,
                Pooling = false,
            }.ToString());
            await connection.OpenAsync(cancellationToken);

            await using (var quickCheck = connection.CreateCommand())
            {
                quickCheck.CommandText = "PRAGMA quick_check;";
                await using var reader = await quickCheck.ExecuteReaderAsync(cancellationToken);
                while (await reader.ReadAsync(cancellationToken))
                {
                    if (!string.Equals(reader.GetString(0), "ok", StringComparison.OrdinalIgnoreCase))
                    {
                        return new DatabaseVerificationResult(false, "SQLite quick_check reported corruption.", 0);
                    }
                }
            }

            await using (var foreignKeyCheck = connection.CreateCommand())
            {
                foreignKeyCheck.CommandText = "PRAGMA foreign_key_check;";
                await using var reader = await foreignKeyCheck.ExecuteReaderAsync(cancellationToken);
                if (await reader.ReadAsync(cancellationToken))
                {
                    return new DatabaseVerificationResult(false, "SQLite foreign_key_check found violations.", 0);
                }
            }

            var knownMigrations = GetKnownMigrations();
            var appliedMigrations = await ReadAppliedMigrationsAsync(connection, cancellationToken);
            if (appliedMigrations.Count == 0)
            {
                await using var userTables = connection.CreateCommand();
                userTables.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';";
                if (Convert.ToInt32(
                        await userTables.ExecuteScalarAsync(cancellationToken),
                        System.Globalization.CultureInfo.InvariantCulture) > 0)
                {
                    return new DatabaseVerificationResult(
                        false,
                        "Database contains application tables without a valid Aurelia migration history.",
                        0);
                }
            }

            if (appliedMigrations.Count > knownMigrations.Length
                || !appliedMigrations.SequenceEqual(
                    knownMigrations.Take(appliedMigrations.Count),
                    StringComparer.Ordinal))
            {
                return new DatabaseVerificationResult(
                    false,
                    "Database migration history is newer, incomplete, or incompatible with this Aurelia version.",
                    appliedMigrations.Count);
            }

            return new DatabaseVerificationResult(true, "Database is valid.", appliedMigrations.Count);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (SqliteException)
        {
            return new DatabaseVerificationResult(false, "SQLite could not verify this database.", 0);
        }
    }

    public async Task RestoreAsync(
        string sourcePath,
        CancellationToken cancellationToken)
    {
        using var operationLock = AcquireOperationLock();
        var fullSourcePath = Path.GetFullPath(sourcePath);
        if (string.Equals(fullSourcePath, Path.GetFullPath(runtime.DatabasePath), PathComparison))
        {
            throw new InvalidOperationException("The active database cannot be used as its own restore source.");
        }

        var sourceInfo = new FileInfo(fullSourcePath);
        if (!sourceInfo.Exists || sourceInfo.LinkTarget is not null)
        {
            throw new InvalidOperationException("Restore source is missing or is a symbolic link.");
        }

        var sourceVerification = await VerifyAsync(fullSourcePath, cancellationToken);
        if (!sourceVerification.IsValid)
        {
            throw new InvalidOperationException($"Restore source failed verification: {sourceVerification.Message}");
        }

        EnsurePrivateBackupDirectory();
        var stagePath = Path.Combine(runtime.DataDirectory, RestoreStageName);
        if (File.Exists(stagePath))
        {
            File.Delete(stagePath);
        }

        try
        {
            await CopyDatabaseWithSqliteBackupAsync(fullSourcePath, stagePath, cancellationToken);
            var stagedVerification = await VerifyAsync(stagePath, cancellationToken);
            if (!stagedVerification.IsValid)
            {
                throw new InvalidOperationException(
                    $"Staged restore failed verification: {stagedVerification.Message}");
            }

            await PreserveCurrentDatabaseAsync(cancellationToken);
            await File.WriteAllTextAsync(
                Path.Combine(runtime.DataDirectory, RestoreMarkerName),
                "restore-pending-v1",
                cancellationToken);
            PrivateFilePermissions.ProtectFile(Path.Combine(runtime.DataDirectory, RestoreMarkerName));
            await ActivateStagedRestoreAsync(cancellationToken);
        }
        catch
        {
            if (File.Exists(stagePath)
                && !File.Exists(Path.Combine(runtime.DataDirectory, RestoreMarkerName)))
            {
                File.Delete(stagePath);
            }

            throw;
        }
    }

    public async Task RecoverPendingRestoreAsync(CancellationToken cancellationToken)
    {
        var markerPath = Path.Combine(runtime.DataDirectory, RestoreMarkerName);
        if (!File.Exists(markerPath))
        {
            return;
        }

        using var operationLock = AcquireOperationLock();
        await ActivateStagedRestoreAsync(cancellationToken);
    }

    private async Task<string> CreateBackupLockedAsync(
        DatabaseBackupKind kind,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(runtime.DatabasePath) || new FileInfo(runtime.DatabasePath).Length == 0)
        {
            throw new InvalidOperationException("Aurelia database does not exist yet.");
        }

        var sourceVerification = await VerifyAsync(runtime.DatabasePath, cancellationToken);
        if (!sourceVerification.IsValid)
        {
            throw new InvalidOperationException($"Source database failed verification: {sourceVerification.Message}");
        }

        EnsurePrivateBackupDirectory();
        var stamp = DateTimeOffset.UtcNow.ToString("yyyyMMdd'T'HHmmssfff'Z'", System.Globalization.CultureInfo.InvariantCulture);
        var finalPath = Path.Combine(BackupDirectory, $"{BackupPrefix}{KindName(kind)}-{stamp}.db");
        var temporaryPath = finalPath + $".{Guid.NewGuid():N}.tmp";
        try
        {
            await CopyDatabaseWithSqliteBackupAsync(runtime.DatabasePath, temporaryPath, cancellationToken);
            var result = await VerifyAsync(temporaryPath, cancellationToken);
            if (!result.IsValid)
            {
                throw new InvalidOperationException($"Created backup failed verification: {result.Message}");
            }

            PrivateFilePermissions.ProtectFile(temporaryPath);
            File.Move(temporaryPath, finalPath);
            PrivateFilePermissions.ProtectFile(finalPath);
            ApplyRetention(kind);
            return finalPath;
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private async Task PreserveCurrentDatabaseAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(runtime.DatabasePath) || new FileInfo(runtime.DatabasePath).Length == 0)
        {
            return;
        }

        try
        {
            await CreateBackupLockedAsync(DatabaseBackupKind.PreRestore, cancellationToken);
        }
        catch (SqliteException)
        {
            await PreserveRawDatabaseFilesAsync(cancellationToken);
        }
        catch (InvalidOperationException)
        {
            await PreserveRawDatabaseFilesAsync(cancellationToken);
        }
    }

    private async Task PreserveRawDatabaseFilesAsync(CancellationToken cancellationToken)
    {
        var recoveryDirectory = Path.Combine(
            BackupDirectory,
            $"aurelia-database-recovery-{DateTimeOffset.UtcNow:yyyyMMdd'T'HHmmssfff'Z'}");
        PrivateFilePermissions.CreatePrivateDirectory(recoveryDirectory);
        foreach (var source in new[]
                 {
                     runtime.DatabasePath,
                     runtime.DatabasePath + "-wal",
                     runtime.DatabasePath + "-shm",
                 })
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!File.Exists(source))
            {
                continue;
            }

            var destination = Path.Combine(recoveryDirectory, Path.GetFileName(source));
            await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read);
            await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            await input.CopyToAsync(output, cancellationToken);
            PrivateFilePermissions.ProtectFile(destination);
        }
    }

    private async Task ActivateStagedRestoreAsync(CancellationToken cancellationToken)
    {
        var stagePath = Path.Combine(runtime.DataDirectory, RestoreStageName);
        var markerPath = Path.Combine(runtime.DataDirectory, RestoreMarkerName);
        if (File.Exists(stagePath))
        {
            var stageVerification = await VerifyAsync(stagePath, cancellationToken);
            if (!stageVerification.IsValid)
            {
                throw new InvalidOperationException($"Pending restore failed verification: {stageVerification.Message}");
            }

            // Restores must never revive a device token that was revoked after the backup.
            await using (var staged = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = stagePath, Pooling = false }.ToString()))
            {
                await staged.OpenAsync(cancellationToken);
                await using var command = staged.CreateCommand();
                command.CommandText = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='DeviceSessions';";
                if (Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken), System.Globalization.CultureInfo.InvariantCulture) > 0)
                {
                    command.CommandText = "UPDATE DeviceSessions SET RevokedAt=$now WHERE RevokedAt IS NULL; UPDATE PairingCodes SET ConsumedAt=$now WHERE ConsumedAt IS NULL; DELETE FROM PlaybackTickets;";
                    command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                    await command.ExecuteNonQueryAsync(cancellationToken);
                }
                command.CommandText = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='DeviceAuthorizationRequests';";
                if (Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken), System.Globalization.CultureInfo.InvariantCulture) > 0)
                {
                    command.CommandText = "UPDATE DeviceAuthorizationRequests SET State='Expired', ProtectedAuthentication=NULL WHERE AcknowledgedAt IS NULL AND State IN ('Pending','Approved');";
                    await command.ExecuteNonQueryAsync(cancellationToken);
                }
                command.CommandText = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='SyncHistoryState';";
                if (Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken), System.Globalization.CultureInfo.InvariantCulture) > 0)
                {
                    command.CommandText = SyncChangeService.RotateGenerationSql;
                    await command.ExecuteNonQueryAsync(cancellationToken);
                }
            }

            SqliteConnections.ClearPool(runtime.DatabasePath);
            DeleteDatabaseSidecar(runtime.DatabasePath + "-wal");
            DeleteDatabaseSidecar(runtime.DatabasePath + "-shm");
            File.Move(stagePath, runtime.DatabasePath, overwrite: true);
            PrivateFilePermissions.ProtectFile(runtime.DatabasePath);
        }

        var restoredVerification = await VerifyAsync(runtime.DatabasePath, cancellationToken);
        if (!restoredVerification.IsValid)
        {
            throw new InvalidOperationException($"Restored database failed verification: {restoredVerification.Message}");
        }

        DeleteDatabaseSidecar(runtime.DatabasePath + "-wal");
        DeleteDatabaseSidecar(runtime.DatabasePath + "-shm");
        if (File.Exists(markerPath))
        {
            File.Delete(markerPath);
        }
    }

    private static async Task CopyDatabaseWithSqliteBackupAsync(
        string sourcePath,
        string destinationPath,
        CancellationToken cancellationToken)
    {
        var source = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = sourcePath,
            Mode = SqliteOpenMode.ReadOnly,
            ForeignKeys = true,
            Pooling = false,
        }.ToString());
        await using (source)
        {
            await source.OpenAsync(cancellationToken);
            await using var destination = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = destinationPath,
                Mode = SqliteOpenMode.ReadWriteCreate,
                ForeignKeys = true,
                Pooling = false,
            }.ToString());
            await destination.OpenAsync(cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            source.BackupDatabase(destination);
        }
    }

    private static async Task<IReadOnlyList<string>> ReadAppliedMigrationsAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        await using var exists = connection.CreateCommand();
        exists.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='__EFMigrationsHistory';";
        if (Convert.ToInt32(await exists.ExecuteScalarAsync(cancellationToken), System.Globalization.CultureInfo.InvariantCulture) == 0)
        {
            return [];
        }

        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT MigrationId FROM __EFMigrationsHistory ORDER BY MigrationId;";
        var migrations = new List<string>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            migrations.Add(reader.GetString(0));
        }

        return migrations;
    }

    private static string[] GetKnownMigrations()
    {
        var options = new DbContextOptionsBuilder<AureliaDbContext>()
            .UseSqlite("Data Source=:memory:")
            .Options;
        using var database = new AureliaDbContext(options);
        return database.Database.GetMigrations().ToArray();
    }

    private void ApplyRetention(DatabaseBackupKind kind)
    {
        var retention = kind switch
        {
            DatabaseBackupKind.Daily => configuration?.Current.DailyBackupsRetained ?? 7,
            DatabaseBackupKind.Weekly => configuration?.Current.WeeklyBackupsRetained ?? 4,
            DatabaseBackupKind.PreMigration => 8,
            DatabaseBackupKind.PreRestore => 4,
            DatabaseBackupKind.Manual => 10,
            _ => 4,
        };
        var oldBackups = ListBackups()
            .Where(backup => backup.Kind == kind)
            .OrderByDescending(backup => backup.CreatedAt)
            .Skip(retention);
        foreach (var backup in oldBackups)
        {
            File.Delete(backup.Path);
        }
    }

    public List<DatabaseBackupFile> ListBackups()
    {
        if (!Directory.Exists(BackupDirectory))
        {
            return [];
        }

        var backups = new List<DatabaseBackupFile>();
        foreach (var path in Directory.EnumerateFiles(BackupDirectory, $"{BackupPrefix}*.db"))
        {
            var info = new FileInfo(path);
            if (info.LinkTarget is not null || !TryParseKind(info.Name, out var kind))
            {
                continue;
            }

            backups.Add(new DatabaseBackupFile(path, kind, info.LastWriteTimeUtc));
        }

        return backups;
    }

    private FileStream AcquireOperationLock()
    {
        EnsurePrivateBackupDirectory();
        var lockPath = Path.Combine(BackupDirectory, OperationLockName);
        try
        {
            var stream = new FileStream(
                lockPath,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None);
            PrivateFilePermissions.ProtectFile(lockPath);
            return stream;
        }
        catch (IOException exception)
        {
            throw new InvalidOperationException("Another database backup or restore operation is already running.", exception);
        }
    }

    private void EnsurePrivateBackupDirectory()
    {
        PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
        if (Directory.Exists(BackupDirectory)
            && new DirectoryInfo(BackupDirectory).LinkTarget is not null)
        {
            throw new InvalidOperationException("The database backup directory cannot be a symbolic link.");
        }

        PrivateFilePermissions.CreatePrivateDirectory(BackupDirectory);
    }

    private static bool TryParseKind(string filename, out DatabaseBackupKind kind)
    {
        foreach (var candidate in Enum.GetValues<DatabaseBackupKind>())
        {
            var prefix = $"{BackupPrefix}{KindName(candidate)}-";
            if (filename.StartsWith(prefix, StringComparison.Ordinal)
                && filename.EndsWith(".db", StringComparison.Ordinal))
            {
                kind = candidate;
                return true;
            }
        }

        kind = default;
        return false;
    }

    private static string KindName(DatabaseBackupKind kind) => kind switch
    {
        DatabaseBackupKind.PreMigration => "pre-migration",
        DatabaseBackupKind.PreRestore => "pre-restore",
        _ => kind.ToString().ToLowerInvariant(),
    };

    private static void DeleteDatabaseSidecar(string path)
    {
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }

    private static StringComparison PathComparison => OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;

    public sealed record DatabaseBackupFile(
        string Path,
        DatabaseBackupKind Kind,
        DateTime CreatedAt);
}
