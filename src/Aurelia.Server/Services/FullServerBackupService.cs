using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Xml;
using Aurelia.Server.Data;
using Microsoft.Data.Sqlite;

namespace Aurelia.Server.Services;

public sealed record BackupExportRequest(string Passphrase);
public sealed record BackupExportResult(Guid Id, long Bytes, bool IncludesMedia = false, bool IncludesArtwork = false);
public sealed record BackupRestoreRequest(Guid UploadId, string Passphrase, bool RevokeAllSessions, bool AcceptDifferentServerIdentity = false);
/// <param name="KeepsSessions">A server move keeps every device's sign-in (docs/SERVER_MOVE.md); a restore revokes them.</param>
public sealed record PreparedRestore(Guid Id, Guid ServerId, bool RevokesAllSessions, bool KeepsSessions = false);
/// <summary>Writes a staged backup into a transfer stream: a passphrase container or a move's key container.</summary>
internal delegate Task BackupContainerWriter(string stage, IReadOnlyList<string> names, Guid serverId, Stream destination, CancellationToken token);
internal delegate Task<BackupManifest> BackupContainerReader(Stream source, string stage, CancellationToken token);
internal sealed record RestoreActivationJournal(int Version, Guid Id, string[] Originals, string[] Replacements);
internal enum RestoreActivationStep { JournalWritten, OriginalMoved, ReplacementMoved, Verified }

public sealed class FullServerBackupService(ServerRuntimeOptions runtime, DatabaseBackupService databaseBackups,
    ServerConfigurationStore configuration, MetadataProviderSettingsStore? metadataSettings = null,
    CatalogMutationGate? mutations = null) : IDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly string[] DatabaseSidecars = ["aurelia.db-wal", "aurelia.db-shm"];
    public void Dispose() => gate.Dispose();
    private string DirectoryPath => Path.Combine(databaseBackups.BackupDirectory, "Transfers");
    public string TransferPath(Guid id) => Path.Combine(DirectoryPath, id.ToString("N") + ".aureliabackup");

    public Task<BackupExportResult> ExportAsync(string passphrase, CancellationToken token) =>
        ExportCoreAsync((stage, names, serverId, stream, cancellation) =>
            EncryptedBackupContainer.EncryptAsync(stage, names, serverId, stream, passphrase, cancellation), null, token);

    /// <summary>
    /// A move bundle: the full backup plus <c>move.json</c>, written into a transfer file. The move
    /// manifest is made inside the catalog lease, so its samples describe the exported database.
    /// </summary>
    internal Task<BackupExportResult> ExportMoveAsync(BackupContainerWriter writer, Func<string, CancellationToken, Task<byte[]>> moveManifest,
        CancellationToken token) => ExportCoreAsync(writer, moveManifest, token);

    private async Task<BackupExportResult> ExportCoreAsync(BackupContainerWriter writer, Func<string, CancellationToken, Task<byte[]>>? moveManifest,
        CancellationToken token)
    {
        await gate.WaitAsync(token);
        string? stage = null;
        string? output = null;
        try
        {
            using var catalogLease = mutations is null ? null : await mutations.EnterAsync(token);
            PrepareTransferDirectory();
            var id = Guid.NewGuid();
            stage = Path.Combine(DirectoryPath, ".export-" + id.ToString("N"));
            PrivateFilePermissions.CreatePrivateDirectory(stage);
            var backup = await databaseBackups.CreateBackupAsync(DatabaseBackupKind.Manual, token);
            await CopyPrivateAsync(backup, Path.Combine(stage, "aurelia.db"), token);
            foreach (var name in StateFiles(runtime.DataDirectory).Where(name => name != "aurelia.db" && name != ServerHostSettings.FileName
                && name is not "metadata-settings.json" and not "Secrets/tmdb-token" && !name.StartsWith("Artwork/", StringComparison.Ordinal)))
                await CopyPrivateAsync(Path.Combine(runtime.DataDirectory, name), Path.Combine(stage, name), token);
            foreach (var name in await ManualArtworkFilesAsync(Path.Combine(stage, "aurelia.db"), token))
                await CopyPrivateAsync(Path.Combine(runtime.DataDirectory, name), Path.Combine(stage, name), token);
            // Settings and their credential must describe the same provider revision.
            foreach (var entry in (metadataSettings ?? new MetadataProviderSettingsStore(runtime)).BackupSnapshot())
            {
                var destination = Path.Combine(stage, entry.Key);
                PrivateFilePermissions.CreatePrivateDirectory(Path.GetDirectoryName(destination)!);
                await using var file = PrivateFilePermissions.OpenNewPrivateFile(destination);
                await using var text = new StreamWriter(file);
                await text.WriteAsync(entry.Value.AsMemory(), token);
            }
            // Always include the authoritative configuration, including a first-run default.
            var settingsPath = Path.Combine(stage, ServerHostSettings.FileName);
            await using (var settings = PrivateFilePermissions.OpenNewPrivateFile(settingsPath))
                await JsonSerializer.SerializeAsync(settings, configuration.Current, Json, token);
            var names = StateFiles(stage);
            if (moveManifest is not null)
            {
                var bytes = await moveManifest(Path.Combine(stage, "aurelia.db"), token);
                await using (var file = PrivateFilePermissions.OpenNewPrivateFile(Path.Combine(stage, EncryptedBackupContainer.MoveManifestName)))
                    await file.WriteAsync(bytes, token);
                names.Add(EncryptedBackupContainer.MoveManifestName);
            }
            output = TransferPath(id);
            await using (var stream = PrivateFilePermissions.OpenNewPrivateFile(output))
            {
                await writer(stage, names, await ServerIdAsync(Path.Combine(stage, "aurelia.db"), token), stream, token);
                await stream.FlushAsync(token);
                stream.Flush(flushToDisk: true);
            }
            return new(id, new FileInfo(output).Length, IncludesArtwork: StateFiles(stage).Any(name => name.StartsWith("Artwork/", StringComparison.Ordinal)));
        }
        catch { if (output is not null && File.Exists(output)) File.Delete(output); throw; }
        finally { if (stage is not null && Directory.Exists(stage)) Directory.Delete(stage, true); gate.Release(); }
    }
    public async Task UploadAsync(Guid id, Stream source, long length, CancellationToken token, Action<long>? progress = null)
    {
        if (length is < 1 or > EncryptedBackupContainer.MaximumBytes)
            throw new AccountException("backup_too_large", "The encrypted backup exceeds the transfer limit.", 413);
        await gate.WaitAsync(token);
        try
        {
            PrepareTransferDirectory();
            var path = TransferPath(id);
            if (File.Exists(path))
                throw new AccountException("backup_upload_exists", "This backup upload identifier has already been used. Start a new upload.", StatusCodes.Status409Conflict);
            var created = false;
            try
            {
                FileStream output;
                try
                {
                    output = PrivateFilePermissions.OpenNewPrivateFile(path);
                }
                catch (IOException) when (File.Exists(path))
                {
                    throw new AccountException("backup_upload_exists", "This backup upload identifier has already been used. Start a new upload.", StatusCodes.Status409Conflict);
                }
                await using (output)
                {
                    created = true;
                    var buffer = new byte[1024 * 1024];
                    long written = 0;
                    while (true)
                    {
                        var count = await source.ReadAsync(buffer, token);
                        if (count == 0) break;
                        written += count;
                        if (written > length) throw new InvalidDataException("Backup transfer length changed.");
                        await output.WriteAsync(buffer.AsMemory(0, count), token);
                        progress?.Invoke(written);
                    }
                    if (written != length) throw new InvalidDataException("The encrypted backup transfer was truncated.");
                    await output.FlushAsync(token);
                }
            }
            catch { if (created && File.Exists(path)) File.Delete(path); throw; }
        }
        finally { gate.Release(); }
    }
    public Task<PreparedRestore> PrepareRestoreAsync(BackupRestoreRequest request, CancellationToken token)
    {
        if (!request.RevokeAllSessions) throw new AccountException("session_revocation_confirmation_required", "Restoring a backup signs out every device. Confirm this before continuing.", 400);
        return PrepareCoreAsync(request.UploadId, (source, stage, cancellation) =>
            EncryptedBackupContainer.DecryptAsync(source, stage, request.Passphrase, cancellation), request.AcceptDifferentServerIdentity, false, token);
    }

    /// <summary>
    /// Verifies a received move bundle like a restore, with the moved server's identity accepted and
    /// every device's sign-in kept. The staged files, <c>move.json</c> among them, stay in
    /// <see cref="RestoreStagePath"/> until the move is finished or discarded.
    /// </summary>
    internal Task<PreparedRestore> PrepareMoveAsync(Guid uploadId, BackupContainerReader reader, CancellationToken token) =>
        PrepareCoreAsync(uploadId, reader, true, true, token);

    public string RestoreStagePath(Guid id) => RestoreStage(runtime, id);

    private async Task<PreparedRestore> PrepareCoreAsync(Guid uploadId, BackupContainerReader reader, bool acceptDifferentIdentity,
        bool keepSessions, CancellationToken token)
    {
        await gate.WaitAsync(token);
        var id = Guid.NewGuid();
        var stage = RestoreStage(runtime, id);
        try
        {
            var path = TransferPath(uploadId);
            if (!File.Exists(path) || new FileInfo(path).LinkTarget is not null) throw new InvalidDataException("The backup upload was not found.");
            BackupManifest manifest;
            await using (var source = File.OpenRead(path))
                manifest = await reader(source, stage, token);
            await ValidateStageAsync(stage, databaseBackups, token);
            if (manifest.ServerId != await ServerIdAsync(Path.Combine(stage, "aurelia.db"), token))
                throw new InvalidDataException("The manifest and database identities differ.");
            var currentId = await ServerIdAsync(runtime.DatabasePath, token);
            if (manifest.ServerId != currentId && !acceptDifferentIdentity)
                throw new InvalidDataException("This backup belongs to another server. Its identity requires an explicit trust change.");
            var stageDatabase = Path.Combine(stage, "aurelia.db");
            await using (var database = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = stageDatabase, Pooling = false }.ToString()))
            {
                await database.OpenAsync(token);
                await using var command = database.CreateCommand();
                // A move keeps every device signed in; playback tickets are for one stream only either way.
                command.CommandText = keepSessions ? "DELETE FROM PlaybackTickets;"
                    : "UPDATE DeviceSessions SET RevokedAt=$now WHERE RevokedAt IS NULL; UPDATE PairingCodes SET ConsumedAt=$now WHERE ConsumedAt IS NULL; DELETE FROM PlaybackTickets;";
                command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                await command.ExecuteNonQueryAsync(token);
                command.CommandText = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='DeviceAuthorizationRequests';";
                if (Convert.ToInt64(await command.ExecuteScalarAsync(token), System.Globalization.CultureInfo.InvariantCulture) > 0)
                {
                    command.CommandText = "UPDATE DeviceAuthorizationRequests SET State='Expired', ProtectedAuthentication=NULL WHERE AcknowledgedAt IS NULL AND State IN ('Pending','Approved');";
                    await command.ExecuteNonQueryAsync(token);
                }
                command.CommandText = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='SyncHistoryState';";
                if (Convert.ToInt64(await command.ExecuteScalarAsync(token), System.Globalization.CultureInfo.InvariantCulture) > 0)
                {
                    command.CommandText = SyncChangeService.RotateGenerationSql;
                    await command.ExecuteNonQueryAsync(token);
                }
            }
            await using (var receipt = PrivateFilePermissions.OpenNewPrivateFile(Path.Combine(stage, "restore-receipt.json")))
                await JsonSerializer.SerializeAsync(receipt, new PreparedRestore(id, manifest.ServerId, !keepSessions, keepSessions), Json, token);
            File.Delete(path);
            return new(id, manifest.ServerId, !keepSessions, keepSessions);
        }
        catch (Exception exception) when (exception is CryptographicException or InvalidDataException or JsonException or FormatException or EndOfStreamException
            or XmlException or KeyNotFoundException or InvalidOperationException || exception is AccountException { StatusCode: 400 })
        {
            if (Directory.Exists(stage)) Directory.Delete(stage, true);
            throw new AccountException("backup_invalid", "The backup could not be verified. Check the passphrase, integrity, and server compatibility. Active data was not changed.", 400);
        }
        catch { if (Directory.Exists(stage)) Directory.Delete(stage, true); throw; }
        finally { gate.Release(); }
    }

    public static Task ApplyPreparedAsync(ServerRuntimeOptions runtime, Guid id, CancellationToken token) =>
        ApplyPreparedCoreAsync(runtime, id, token);

    /// <summary>
    /// On a Linux package server the browser's restore names the prepared backup in this file and
    /// restarts the service; the next start applies it before the database opens.
    /// </summary>
    public const string RestoreOnStartFile = "restore-on-start";

    public static async Task RequestOnStartAsync(ServerRuntimeOptions runtime, Guid id, CancellationToken token)
    {
        var path = Path.Combine(runtime.DataDirectory, RestoreOnStartFile);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporary))
            {
                await file.WriteAsync(System.Text.Encoding.ASCII.GetBytes(id.ToString("D")), token);
                file.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    /// <summary>
    /// Applies a restore requested for this start, once: the request is removed first, so a restore
    /// that fails (and rolls itself back) never stops the server from starting. Returns the outcome
    /// for the host operation journal, or null when nothing was requested.
    /// </summary>
    public static async Task<string?> ApplyRequestedOnStartAsync(ServerRuntimeOptions runtime, CancellationToken token)
    {
        var request = new FileInfo(Path.Combine(runtime.DataDirectory, RestoreOnStartFile));
        if (!request.Exists && request.LinkTarget is null) return null;
        var text = request.LinkTarget is null && request.Length <= 64 ? await File.ReadAllTextAsync(request.FullName, token) : "";
        File.Delete(request.FullName);
        if (!Guid.TryParse(text.Trim(), out var id)) return "failed";
        // Only a restore this server prepared and verified itself.
        if (!File.Exists(Path.Combine(RestoreStage(runtime, id), "restore-receipt.json"))) return "failed";
        string outcome;
        try
        {
            await ApplyPreparedAsync(runtime, id, token);
            outcome = "completed";
        }
        // Keys, settings and XML files of a damaged backup fail too, without stopping the server's start (audit S-X11).
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException
            or JsonException or Microsoft.Data.Sqlite.SqliteException or System.Security.Cryptography.CryptographicException
            or System.Xml.XmlException or FormatException or EndOfStreamException)
        {
            outcome = "failed";
        }
        var journal = Path.Combine(runtime.DataDirectory, NativeHostOperations.JournalFileName);
        if (File.Exists(journal) && new FileInfo(journal).LinkTarget is null)
        {
            HostOperationJournal? current;
            try { current = JsonSerializer.Deserialize<HostOperationJournal>(await File.ReadAllTextAsync(journal, token), Json); }
            catch (JsonException) { current = null; }
            if (current?.Id == id)
            {
                var temporary = journal + "." + Guid.NewGuid().ToString("N");
                await using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporary))
                    await JsonSerializer.SerializeAsync(file, current with { State = outcome }, Json, token);
                File.Move(temporary, journal, true);
            }
        }
        return outcome;
    }

    internal static async Task ApplyPreparedCoreAsync(ServerRuntimeOptions runtime, Guid id, CancellationToken token,
        Action<RestoreActivationStep, int>? afterStep = null)
    {
        var backups = new DatabaseBackupService(runtime);
        var stage = RestoreStage(runtime, id);
        PrivateFilePermissions.CreatePrivateDirectory(stage);
        var receiptPath = Path.Combine(stage, "restore-receipt.json");
        if (!File.Exists(receiptPath) || new FileInfo(receiptPath).LinkTarget is not null) throw new InvalidDataException("A verified restore receipt is required.");
        var receipt = JsonSerializer.Deserialize<PreparedRestore>(await File.ReadAllTextAsync(receiptPath, token), Json);
        if (receipt?.Id != id || receipt.RevokesAllSessions == receipt.KeepsSessions) throw new InvalidDataException("Invalid restore receipt.");
        await ValidateStageAsync(stage, backups, token);
        if (receipt.ServerId != await ServerIdAsync(Path.Combine(stage, "aurelia.db"), token)) throw new InvalidDataException("The prepared restore identity changed.");
        // Bound both the incoming state and the existing rollback state before
        // creating the activation marker or moving any active file.
        var originals = StateFiles(runtime.DataDirectory).Concat(DatabaseSidecars
            .Where(name => File.Exists(Path.Combine(runtime.DataDirectory, name)))).ToArray();
        var replacementNames = StateFiles(stage).ToArray();
        var journal = new RestoreActivationJournal(1, id, originals, replacementNames);
        ValidateJournal(journal);
        // Mandatory rollback copy includes database, configuration, keys and managed
        // PNG artwork so failed activation cannot lose a user's imported images.
        // Original video files are never included.
        // An unsuccessful pre-activation attempt must not prevent retrying the
        // same prepared restore after freeing disk space.
        var rollback = Path.Combine(backups.BackupDirectory, "pre-full-restore-" + Guid.NewGuid().ToString("N"));
        PrivateFilePermissions.CreatePrivateDirectory(rollback);
        try
        {
            var preDatabase = await backups.CreateBackupAsync(DatabaseBackupKind.PreRestore, token);
            await CopyPrivateAsync(preDatabase, Path.Combine(rollback, "aurelia.db"), token);
            foreach (var name in StateFiles(runtime.DataDirectory).Where(name => name != "aurelia.db"))
                await CopyPrivateAsync(Path.Combine(runtime.DataDirectory, name), Path.Combine(rollback, name), token);
        }
        catch
        {
            Directory.Delete(rollback, true);
            throw;
        }
        SqliteConnections.ClearPool(runtime.DatabasePath);
        // Backup connections can create or retire SQLite sidecars. Capture the
        // actual closed-connection state, and validate it again before activation.
        originals = StateFiles(runtime.DataDirectory).Concat(DatabaseSidecars
            .Where(name => File.Exists(Path.Combine(runtime.DataDirectory, name)))).ToArray();
        journal = new RestoreActivationJournal(1, id, originals, replacementNames);
        ValidateJournal(journal);
        var undo = UndoDirectory(runtime, id);
        PrivateFilePermissions.CreatePrivateDirectory(undo);
        // Prepare directory entries before activation. Activation and rollback use same-volume
        // renames, not copies that could fail because the remaining disk space was consumed.
        foreach (var name in originals)
            PrivateFilePermissions.CreatePrivateDirectory(Path.GetDirectoryName(Path.Combine(undo, name))!);
        foreach (var name in replacementNames)
            PrivateFilePermissions.CreatePrivateDirectory(Path.GetDirectoryName(Path.Combine(runtime.DataDirectory, name))!);
        var marker = Path.Combine(runtime.DataDirectory, ".full-restore.pending");
        var temporaryMarker = marker + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporaryMarker))
            {
                await JsonSerializer.SerializeAsync(file, journal, Json, token);
                await file.FlushAsync(token);
                file.Flush(flushToDisk: true);
            }
            File.Move(temporaryMarker, marker);
        }
        finally { if (File.Exists(temporaryMarker)) File.Delete(temporaryMarker); }
        try
        {
            token.ThrowIfCancellationRequested();
            afterStep?.Invoke(RestoreActivationStep.JournalWritten, 0);
            var moved = 0;
            foreach (var name in originals)
            {
                File.Move(Path.Combine(runtime.DataDirectory, name), Path.Combine(undo, name));
                afterStep?.Invoke(RestoreActivationStep.OriginalMoved, ++moved);
            }
            moved = 0;
            foreach (var name in replacementNames)
            {
                File.Move(Path.Combine(stage, name), Path.Combine(runtime.DataDirectory, name));
                afterStep?.Invoke(RestoreActivationStep.ReplacementMoved, ++moved);
            }
            await ValidateStageAsync(runtime.DataDirectory, backups, CancellationToken.None);
            afterStep?.Invoke(RestoreActivationStep.Verified, 0);
            File.Delete(marker);
        }
        catch
        {
            await RecoverInterruptedRestoreAsync(runtime, CancellationToken.None);
            throw;
        }
        // Cleanup happens only after the committed state no longer needs the undo journal.
        if (Directory.Exists(undo)) Directory.Delete(undo, true);
        if (Directory.Exists(stage)) Directory.Delete(stage, true);
        foreach (var old in Directory.EnumerateDirectories(backups.BackupDirectory, "pre-full-restore-*")
            .OrderByDescending(Directory.GetCreationTimeUtc).Skip(4)) Directory.Delete(old, true);
    }
    public static async Task RecoverInterruptedRestoreAsync(ServerRuntimeOptions runtime, CancellationToken token)
    {
        var marker = Path.Combine(runtime.DataDirectory, ".full-restore.pending");
        if (!File.Exists(marker)) return;
        if (new FileInfo(marker).LinkTarget is not null || new FileInfo(marker).Length > 16 * 1024 * 1024)
            throw new InvalidDataException("Unsafe or oversized restore journal.");
        var journal = JsonSerializer.Deserialize<RestoreActivationJournal>(await File.ReadAllTextAsync(marker, token), Json);
        ValidateJournal(journal);
        var undo = UndoDirectory(runtime, journal!.Id);
        if (!Directory.Exists(undo) || new DirectoryInfo(undo).LinkTarget is not null)
            throw new InvalidDataException("The interrupted restore undo state is missing.");
        SqliteConnections.ClearPool(runtime.DatabasePath);
        foreach (var name in journal.Replacements.Except(journal.Originals, StringComparer.Ordinal))
            if (File.Exists(Path.Combine(runtime.DataDirectory, name))) File.Delete(Path.Combine(runtime.DataDirectory, name));
        foreach (var name in journal.Originals)
        {
            var saved = Path.Combine(undo, name);
            var target = Path.Combine(runtime.DataDirectory, name);
            if (File.Exists(saved))
            {
                PrivateFilePermissions.CreatePrivateDirectory(Path.GetDirectoryName(target)!);
                File.Move(saved, target, true);
            }
            // If it was never moved, the original is still in its active location.
            else if (!File.Exists(target))
                throw new InvalidDataException("An original restore entry is missing.");
        }
        File.Delete(marker);
    }

    private static void ValidateJournal(RestoreActivationJournal? journal)
    {
        if (journal is null || journal.Version != 1 || journal.Id == Guid.Empty
            || journal.Originals is null || journal.Replacements is null
            || journal.Originals.Length > EncryptedBackupContainer.MaximumEntries + DatabaseSidecars.Length
            || journal.Replacements.Length > EncryptedBackupContainer.MaximumEntries
            || journal.Originals.Distinct(StringComparer.Ordinal).Count() != journal.Originals.Length
            || journal.Replacements.Distinct(StringComparer.Ordinal).Count() != journal.Replacements.Length
            || journal.Originals.Any(name => !EncryptedBackupContainer.AllowedName(name) && name is not "aurelia.db-wal" and not "aurelia.db-shm")
            || journal.Replacements.Any(name => !EncryptedBackupContainer.AllowedName(name)))
            throw new InvalidDataException("Invalid restore journal.");
    }
    private static string UndoDirectory(ServerRuntimeOptions runtime, Guid id) => Path.Combine(runtime.DataDirectory, "Backups", ".restore-undo-" + id.ToString("N"));
    private static async Task ValidateStageAsync(string stage, DatabaseBackupService backups, CancellationToken token)
    {
        foreach (var name in StateFiles(stage))
        {
            var file = new FileInfo(Path.Combine(stage, name));
            if (file.LinkTarget is not null || file.Length > EncryptedBackupContainer.MaximumEntryBytes(name))
                throw new InvalidDataException("Unsafe or oversized backup state.");
        }
        var verification = await backups.VerifyAsync(Path.Combine(stage, "aurelia.db"), token);
        if (!verification.IsValid) throw new InvalidDataException("The restored database is incompatible or corrupt.");
        var settings = ServerHostSettings.Load(stage) ?? throw new InvalidDataException("Backup configuration is missing.");
        ServerConfigurationStore.Validate(settings);
        if (settings.LanAccessEnabled && !File.Exists(Path.Combine(stage, "server-certificate.pem")))
            throw new InvalidDataException("A network-enabled backup must contain its TLS identity.");
        if (File.Exists(Path.Combine(stage, "server-certificate.pem")) != File.Exists(Path.Combine(stage, "server-private-key.pem")))
            throw new InvalidDataException("The TLS identity is incomplete.");
        if (File.Exists(Path.Combine(stage, "server-certificate.pem")))
        {
            using var certificate = X509Certificate2.CreateFromPemFile(Path.Combine(stage, "server-certificate.pem"), Path.Combine(stage, "server-private-key.pem"));
            if (!certificate.HasPrivateKey) throw new InvalidDataException("The TLS identity has no private key.");
        }
        await using var database = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(stage, "aurelia.db"), Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        await database.OpenAsync(token);
        var requiredArtwork = await ManualArtworkFilesAsync(Path.Combine(stage, "aurelia.db"), token);
        foreach (var name in requiredArtwork)
        {
            if (!EncryptedBackupContainer.AllowedName(name) || !File.Exists(Path.Combine(stage, name)))
                throw new InvalidDataException("The backup is missing referenced manual artwork.");
            EditorArtworkStore.ValidateStoredImage(Path.Combine(stage, name), allowProviderWebP: name.EndsWith(".webp", StringComparison.OrdinalIgnoreCase));
        }
        await using var command = database.CreateCommand();
        command.CommandText = "SELECT count(*) FROM pragma_table_info('Users') WHERE name='IsEnabled';";
        var hasEnabled = Convert.ToInt64(await command.ExecuteScalarAsync(token), System.Globalization.CultureInfo.InvariantCulture) > 0;
        command.CommandText = "SELECT count(*) FROM Users WHERE Role='Owner'" + (hasEnabled ? " AND IsEnabled=1;" : ";");
        if (Convert.ToInt64(await command.ExecuteScalarAsync(token), System.Globalization.CultureInfo.InvariantCulture) == 0)
            throw new InvalidDataException("The backup has no owner account.");
        foreach (var file in StateFiles(stage).Where(name => name.EndsWith(".xml", StringComparison.Ordinal)))
        {
            using var reader = XmlReader.Create(Path.Combine(stage, file), new XmlReaderSettings
            { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 1_048_576 });
            while (reader.Read()) { }
        }
        var metadata = Path.Combine(stage, "metadata-settings.json");
        if (File.Exists(metadata))
        {
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(metadata, token));
            if (document.RootElement.GetProperty("version").GetInt32() != 1)
                throw new InvalidDataException("The metadata configuration is incompatible.");
        }
        foreach (var jsonFile in StateFiles(stage).Where(name => name.EndsWith(".json", StringComparison.Ordinal)
            && name is not ServerHostSettings.FileName and not "metadata-settings.json"))
        {
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(stage, jsonFile), token));
        }
    }
    private static async Task<Guid> ServerIdAsync(string databasePath, CancellationToken token)
    {
        await using var database = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = databasePath, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        await database.OpenAsync(token);
        await using var command = database.CreateCommand();
        command.CommandText = "SELECT ServerId FROM ServerIdentities WHERE Id=1;";
        return Guid.Parse((string)(await command.ExecuteScalarAsync(token) ?? throw new InvalidDataException("Server identity is missing.")));
    }
    private void PrepareTransferDirectory()
    {
        PrivateFilePermissions.CreatePrivateDirectory(DirectoryPath);
        foreach (var file in Directory.EnumerateFiles(DirectoryPath, "*.aureliabackup").Where(file => File.GetLastWriteTimeUtc(file) < DateTime.UtcNow.AddHours(-24))) File.Delete(file);
        if (Directory.EnumerateFiles(DirectoryPath, "*.aureliabackup").Count() >= 4)
            throw new AccountException("backup_transfer_limit", "Download or remove pending backup transfers before starting another one.", 409);
    }
    private static List<string> StateFiles(string directory)
    {
        var names = new List<string>();
        foreach (var name in new[]
        {
            "aurelia.db",
            ServerHostSettings.FileName,
            "server-certificate.pem",
            "server-private-key.pem",
            "metadata-settings.json",
            "security-settings.json",
            "subtitle-settings.json",
            "Secrets/tmdb-token",
            "Secrets/opensubtitles-key",
            "Secrets/opensubtitles-account",
        })
            if (File.Exists(Path.Combine(directory, name))) names.Add(name);
        var keys = Path.Combine(directory, "DataProtectionKeys");
        if (Directory.Exists(keys))
        {
            if (new DirectoryInfo(keys).LinkTarget is not null) throw new InvalidDataException("Unsafe key directory.");
            names.AddRange(Directory.EnumerateFiles(keys, "key-*.xml").Select(path => "DataProtectionKeys/" + Path.GetFileName(path)));
        }
        var artwork = Path.Combine(directory, "Artwork");
        if (Directory.Exists(artwork))
        {
            if (new DirectoryInfo(artwork).LinkTarget is not null) throw new InvalidDataException("Unsafe artwork directory.");
            names.AddRange(Directory.EnumerateFiles(artwork).Select(path => "Artwork/" + Path.GetFileName(path)).Where(EncryptedBackupContainer.AllowedName));
            var collections = Path.Combine(artwork, "Collections");
            if (Directory.Exists(collections))
            {
                if (new DirectoryInfo(collections).LinkTarget is not null) throw new InvalidDataException("Unsafe collection artwork directory.");
                names.AddRange(Directory.EnumerateFiles(collections).Select(path => "Artwork/Collections/" + Path.GetFileName(path)).Where(EncryptedBackupContainer.AllowedName));
            }
        }
        var watchlist = Path.Combine(directory, "Watchlist");
        if (Directory.Exists(watchlist))
        {
            if (new DirectoryInfo(watchlist).LinkTarget is not null) throw new InvalidDataException("Unsafe watchlist directory.");
            names.AddRange(Directory.EnumerateFiles(watchlist).Select(path => "Watchlist/" + Path.GetFileName(path)).Where(EncryptedBackupContainer.AllowedName));
        }
        var subtitles = Path.Combine(directory, "Subtitles");
        if (Directory.Exists(subtitles))
        {
            if (new DirectoryInfo(subtitles).LinkTarget is not null) throw new InvalidDataException("Unsafe subtitles directory.");
            var automatic = Path.Combine(subtitles, "automatic.json");
            if (File.Exists(automatic)) names.Add("Subtitles/automatic.json");
            foreach (var folder in Directory.EnumerateDirectories(subtitles))
            {
                var info = new DirectoryInfo(folder);
                if (info.LinkTarget is not null) throw new InvalidDataException("Unsafe subtitle folder.");
                var folderName = info.Name;
                if (!Guid.TryParseExact(folderName, "N", out _)) continue;
                names.AddRange(Directory.EnumerateFiles(folder)
                    .Select(path => $"Subtitles/{folderName}/{Path.GetFileName(path)}")
                    .Where(EncryptedBackupContainer.AllowedName));
            }
        }
        return names;
    }
    private static async Task<IReadOnlyList<string>> ManualArtworkFilesAsync(string path, CancellationToken token)
    {
        await using var database = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        await database.OpenAsync(token);
        var names = new HashSet<string>(StringComparer.Ordinal);
        await CollectManualArtworkAsync(database, "ArtworkAssets", "Artwork/", names, token);
        await CollectManualArtworkAsync(database, "CollectionArtworkAssets", "Artwork/Collections/", names, token);
        return names.ToArray();
    }
    private static async Task CollectManualArtworkAsync(SqliteConnection database, string table, string prefix, HashSet<string> names, CancellationToken token)
    {
        await using var command = database.CreateCommand();
        command.CommandText = $"SELECT count(*) FROM pragma_table_info('{table}') WHERE name='IsManual';";
        if (Convert.ToInt64(await command.ExecuteScalarAsync(token), System.Globalization.CultureInfo.InvariantCulture) == 0) return;
        command.CommandText = $"SELECT RelativeFilePath, OriginalFilePath FROM {table} WHERE IsManual=1;";
        await using var reader = await command.ExecuteReaderAsync(token);
        while (await reader.ReadAsync(token))
        {
            for (var index = 0; index < 2; index++)
            {
                if (reader.IsDBNull(index)) continue;
                var name = prefix + reader.GetString(index);
                if (!EncryptedBackupContainer.AllowedName(name)) throw new InvalidDataException("Invalid manual artwork reference.");
                names.Add(name);
            }
        }
    }
    private static string RestoreStage(ServerRuntimeOptions runtime, Guid id) => Path.Combine(runtime.DataDirectory, "Backups", ".restore-" + id.ToString("N"));
    private static async Task CopyPrivateAsync(string source, string destination, CancellationToken token)
    {
        if (new FileInfo(source).LinkTarget is not null) throw new InvalidDataException("Symbolic links are not backup state.");
        PrivateFilePermissions.CreatePrivateDirectory(Path.GetDirectoryName(destination)!);
        await using var input = File.OpenRead(source);
        await using var output = PrivateFilePermissions.OpenNewPrivateFile(destination);
        await input.CopyToAsync(output, 1024 * 1024, token);
        await output.FlushAsync(token);
        output.Flush(flushToDisk: true);
    }
}
