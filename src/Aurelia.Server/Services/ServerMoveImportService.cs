using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using Aurelia.Contracts;
using Microsoft.Data.Sqlite;

namespace Aurelia.Server.Services;

public sealed record SetupMoveNetworkRequest(string? Address, string? Code);
public sealed record SetupMoveOpenRequest(string? Passphrase);
public sealed record SetupMoveUpload(Guid UploadId);
public sealed record SetupMoveProgress(long Received, long? Expected);
public sealed record SetupMoveSource(Guid ServerId, string Name);
public sealed record SetupMoveLocation(Guid Id, string Name, string OldPath, int Sampled, IReadOnlyList<MoveSuggestion> Suggestions);
public sealed record SetupMoveStatus(string State, SetupMoveProgress? Progress, string? Error, SetupMoveSource? Source,
    IReadOnlyList<SetupMoveLocation> Locations);
public sealed record SetupMovePreviewRequest(Guid Id, string? Path);
public sealed record SetupMoveFinishRequest(IReadOnlyList<MovePathMapping>? Mappings);

/// <summary>Where suggestions look and for how long; tests point them at a synthetic folder.</summary>
public class ServerMoveOptions
{
    public virtual IReadOnlyList<string> SearchRoots => ServerMoveLocations.DefaultSearchRoots();
    public virtual TimeSpan SearchBudget => ServerMoveLocations.SearchBudget;
}

/// <summary>
/// Applies a finished move's staged data and restarts the server with it, the way a restore does:
/// the app that hosts the server restores and starts it again, a Linux package server restores at
/// its next start, which systemd begins at once. Tests replace this class.
/// </summary>
public class ServerMoveApplier(ServerRuntimeOptions runtime, NativeHostOperations operations, IServiceProvider services)
{
    public virtual async Task ApplyAsync(Guid restoreId, CancellationToken token)
    {
        if (operations.Available)
        {
            await operations.ApplyRestoreAsync(Guid.Empty, restoreId, token);
            return;
        }
        if (LinuxPackage.IsInstalled)
        {
            await operations.ApplyRestoreAsync(Guid.Empty, restoreId, token, services.GetRequiredService<LinuxServiceRestart>());
            return;
        }
        // Docker and a server started by hand: restore at the next start and end with the restart
        // status, so a supervisor (Docker's restart policy) starts it again.
        await FullServerBackupService.RequestOnStartAsync(runtime, restoreId, token);
        var lifetime = services.GetRequiredService<IHostApplicationLifetime>();
        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(1), CancellationToken.None);
            Environment.ExitCode = LinuxPackage.RestartExitCode;
            lifetime.StopApplication();
        }, CancellationToken.None);
    }
}

/// <summary>
/// The new server's side of a move while it has no owner (docs/SERVER_MOVE.md): fetching the bundle
/// from the old server or opening a moving file, suggesting where each storage location's files are
/// now, rewriting the staged database's paths and applying it. Nothing is applied before Finish, and
/// the staged data lives in the data folder's restore stage, never next to the media.
/// </summary>
public sealed partial class ServerMoveImportService(ServerRuntimeOptions runtime, FullServerBackupService backups,
    ServerMoveTransport transport, ServerMoveOptions options, ServerMoveApplier applier, ILogger<ServerMoveImportService> logger) : IDisposable
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly TimeSpan HelloTimeout = TimeSpan.FromSeconds(15);
    private readonly Lock gate = new();
    private string state = "idle";
    private long received;
    private long? expected;
    private string? error;
    private SetupMoveSource? source;
    private MoveManifest? manifest;
    private Guid? prepared;
    private string[] sourceAddresses = [];
    private IReadOnlyList<SetupMoveLocation> locations = [];
    private Guid? upload;
    private CancellationTokenSource? work;

    public SetupMoveStatus Status()
    {
        lock (gate)
            return new(state, state == "fetching" && (received > 0 || expected is not null) ? new(received, expected) : null,
                state == "failed" ? error : null, source, state is "received" or "applying" or "done" ? locations : []);
    }

    /// <summary>Checks that the old server waits for this code, then fetches its bundle in the background.</summary>
    public async Task<SetupMoveStatus> StartNetworkAsync(SetupMoveNetworkRequest request, CancellationToken token)
    {
        var code = ServerMoveCrypto.Normalize(request.Code)
            ?? throw new AccountException("move_code_invalid", "Enter the move code the old server shows: twelve letters and digits.", 400);
        var address = ServerMoveTransport.ParseAddress(request.Address)
            ?? throw new AccountException("move_address_invalid", "Enter the old server's address, such as 192.168.1.20 or myserver.local.", 400);
        var cancellation = Begin();
        try
        {
            byte[]? observed = null;
            MoveHelloResponse hello;
            using (var client = transport.Create(spki => observed = spki, null))
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token, cancellation.Token))
            {
                client.BaseAddress = address;
                timeout.CancelAfter(HelloTimeout);
                using var response = await SendAsync(client, new HttpRequestMessage(HttpMethod.Get, "/api/v1/move/hello"), timeout.Token);
                if (!response.IsSuccessStatusCode)
                {
                    var problem = await ProblemAsync(response, timeout.Token);
                    throw problem?.Code == "move_not_waiting"
                        ? new AccountException("move_not_waiting", "The old server isn't waiting for a move. On the old server, choose Move to a New Server… and use the code it shows.", 404)
                        : new AccountException("move_source_failed", "The old server refused the move" + (problem is null ? "." : ": " + problem.Message), 502);
                }
                hello = await response.Content.ReadFromJsonAsync<MoveHelloResponse>(Json, timeout.Token)
                    ?? throw new AccountException("move_source_failed", "The old server gave no answer.", 502);
            }
            var nonce = ServerMoveCrypto.DecodeNonce(hello.Nonce);
            if (nonce is null || hello.ServerId == Guid.Empty || string.IsNullOrWhiteSpace(hello.Name) || hello.Name.Length > 128 || observed is not { Length: 32 })
                throw new AccountException("move_source_failed", "The other server's answer is not an Aurelia move.", 502);
            lock (gate) source = new(hello.ServerId, hello.Name.Trim());
            var spki = observed;
            _ = Task.Run(() => ReceiveNetworkAsync(address, code, nonce, spki, cancellation), CancellationToken.None);
            return Status();
        }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException or JsonException or NotSupportedException
            && !token.IsCancellationRequested)
        {
            Reset();
            throw new AccountException("move_source_unreachable", "The old server can't be reached at that address. Check the address and that both servers are on and on the same network.", 502);
        }
        catch
        {
            Reset();
            throw;
        }
    }

    /// <summary>Keeps an uploaded moving file until it is opened with its passphrase.</summary>
    public async Task<SetupMoveUpload> UploadAsync(Stream body, long length, CancellationToken token)
    {
        lock (gate)
        {
            if (state is not ("idle" or "failed")) throw Busy();
            DeleteUpload();
        }
        var id = Guid.NewGuid();
        await backups.UploadAsync(id, body, length, token);
        lock (gate)
        {
            DeleteUpload();
            upload = id;
        }
        return new(id);
    }

    /// <summary>Opens the uploaded moving file; a wrong passphrase leaves it there for another try.</summary>
    public async Task<SetupMoveStatus> OpenFileAsync(Guid uploadId, string? passphrase, CancellationToken token)
    {
        lock (gate)
            if (upload != uploadId) throw new AccountException("move_upload_not_found", "Upload the moving file again.", 404);
        var cancellation = Begin();
        try
        {
            var text = passphrase ?? string.Empty;
            var result = await backups.PrepareMoveAsync(uploadId, (stream, stage, cancel) =>
                EncryptedBackupContainer.DecryptAsync(stream, stage, text, cancel), token);
            lock (gate) upload = null;
            var parsed = ReadManifest(result);
            lock (gate) source = new(parsed.ServerId, parsed.Name);
            _ = Task.Run(() => StageAsync(result, parsed, [], cancellation), CancellationToken.None);
            return Status();
        }
        catch
        {
            Reset();
            throw;
        }
    }

    public MoveLocationMatch Preview(SetupMovePreviewRequest request)
    {
        MoveLocation location;
        lock (gate)
        {
            if (state != "received" || manifest is null) throw NotReceived();
            location = manifest.Locations.FirstOrDefault(candidate => candidate.Id == request.Id)
                ?? throw new AccountException("move_location_not_found", "This storage location is not part of the move.", 404);
        }
        var folder = ServerMoveLocations.ValidFolder(request.Path)
            ?? throw new AccountException("folder_invalid", "Enter the whole path of an existing folder on this computer.", 400);
        return new(location.Samples.Count, ServerMoveLocations.CountMatches(folder, location.Samples));
    }

    /// <summary>
    /// Rewrites the staged database for the chosen folders, leaves where to report the arrival for
    /// the next start and applies the data. A location without a folder keeps its old path and is
    /// offline until Storage Location Moved points it at the new one.
    /// </summary>
    public async Task<SetupMoveStatus> FinishAsync(SetupMoveFinishRequest request, CancellationToken token)
    {
        Guid id;
        MoveManifest moved;
        string[] addresses;
        lock (gate)
        {
            if (state != "received" || manifest is null || prepared is null) throw NotReceived();
            id = prepared.Value;
            moved = manifest;
            addresses = sourceAddresses;
            state = "applying";
        }
        try
        {
            var mappings = new List<MovePathMapping>();
            foreach (var mapping in request.Mappings ?? [])
            {
                if (mapping is null || moved.Locations.All(location => location.Id != mapping.Id))
                    throw new AccountException("move_location_not_found", "A storage location of the mapping is not part of the move.", 400);
                if (mappings.Any(existing => existing.Id == mapping.Id))
                    throw new AccountException("move_mapping_invalid", "Each storage location may appear once.", 400);
                var folder = mapping.Path is null ? null : ServerMoveLocations.ValidFolder(mapping.Path)
                    ?? throw new AccountException("folder_invalid", "Enter the whole path of an existing folder on this computer.", 400);
                mappings.Add(new(mapping.Id, folder));
            }
            await RewriteStageAsync(Path.Combine(backups.RestoreStagePath(id), "aurelia.db"), mappings, token);
            ServerMoveArrival.Write(runtime.DataDirectory, new MoveArrivalRecord(1, moved.ServerId, moved.MoveToken, addresses, false));
            await applier.ApplyAsync(id, token);
            LogFinished(logger, moved.Name);
            lock (gate) state = "done";
            return Status();
        }
        catch
        {
            ServerMoveArrival.Delete(runtime.DataDirectory);
            lock (gate) if (state == "applying") state = "received";
            throw;
        }
    }

    /// <summary>Discards a fetched, staged or uploaded move; nothing was applied.</summary>
    public SetupMoveStatus Discard()
    {
        lock (gate)
        {
            if (state is "applying" or "done") throw new AccountException("move_applying", "The move is being applied and can no longer be discarded.", 409);
            work?.Cancel();
            Clear();
            DeleteUpload();
            state = "idle";
            error = null;
            return Status();
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            work?.Cancel();
            work?.Dispose();
            work = null;
        }
    }

    private async Task ReceiveNetworkAsync(Uri address, string code, byte[] nonce, byte[] spki, CancellationTokenSource cancellation)
    {
        var token = cancellation.Token;
        var uploadId = Guid.NewGuid();
        try
        {
            var clientNonce = RandomNumberGenerator.GetBytes(ServerMoveCrypto.NonceBytes);
            var proof = ServerMoveCrypto.Proof(code, nonce, clientNonce, spki);
            // The claim must reach the same server whose key the proof names.
            using var client = transport.Create(_ => { }, spki);
            client.BaseAddress = address;
            using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/move/claim")
            {
                Content = JsonContent.Create(new MoveClaimRequest(Convert.ToBase64String(nonce), Convert.ToBase64String(clientNonce),
                    Convert.ToBase64String(proof)), options: Json),
            };
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            if (!response.IsSuccessStatusCode)
            {
                var problem = await ProblemAsync(response, token);
                Fail(cancellation, problem?.Code switch
                {
                    "move_proof_invalid" => "The move code is not right. Check the code the old server shows and try again.",
                    "move_ended" => "The move code was entered wrong five times and ended. Start the move again on the old server.",
                    "move_not_waiting" => "The old server is no longer waiting for this move. Start the move again on the old server.",
                    _ => "The old server refused the move" + (problem is null ? "." : ": " + problem.Message),
                });
                return;
            }
            var length = response.Content.Headers.ContentLength
                ?? throw new InvalidDataException("The old server did not say how large the move is.");
            lock (gate) expected = length;
            await using (var body = await response.Content.ReadAsStreamAsync(token))
                await backups.UploadAsync(uploadId, body, length, token, written => { lock (gate) received = written; });
            var key = ServerMoveCrypto.BundleKey(code, nonce, clientNonce, spki);
            PreparedRestore result;
            try
            {
                result = await backups.PrepareMoveAsync(uploadId, (stream, stage, cancel) =>
                    EncryptedBackupContainer.DecryptWithKeyAsync(stream, stage, key, cancel), token);
            }
            finally { CryptographicOperations.ZeroMemory(key); }
            var parsed = ReadManifest(result);
            await StageAsync(result, parsed, [address.GetLeftPart(UriPartial.Authority)], cancellation);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception exception) when (exception is HttpRequestException or IOException or InvalidDataException or JsonException
            or AccountException or CryptographicException or OperationCanceledException)
        {
            Fail(cancellation, exception is AccountException { Code: "backup_invalid" }
                ? "The moved data couldn't be verified. Nothing changed on either server."
                : exception is HttpRequestException or IOException or OperationCanceledException
                    ? "The connection to the old server ended before the move arrived. Start the move again on the old server."
                    : exception is AccountException account ? account.Message : "The move couldn't be received: " + exception.Message);
        }
        finally
        {
            ServerMoveService.TryDelete(backups.TransferPath(uploadId));
        }
    }

    /// <summary>Suggests a folder for every storage location, then shows them.</summary>
    private async Task StageAsync(PreparedRestore result, MoveManifest parsed, IReadOnlyList<string> typedAddresses, CancellationTokenSource cancellation)
    {
        var token = cancellation.Token;
        try
        {
            lock (gate)
            {
                if (work != cancellation) { DeleteStage(result.Id); return; }
                prepared = result.Id;
                manifest = parsed;
            }
            var roots = options.SearchRoots;
            var budget = TimeSpan.FromTicks(Math.Max(TimeSpan.FromSeconds(3).Ticks, options.SearchBudget.Ticks / Math.Max(1, parsed.Locations.Count)));
            var found = await Task.Run(() => parsed.Locations.Select(location => new SetupMoveLocation(location.Id, location.Name, location.Path,
                location.Samples.Count, ServerMoveLocations.Suggest(location.Samples, location.Path, roots, budget, token))).ToArray(), token);
            lock (gate)
            {
                if (work != cancellation) return;
                locations = found;
                sourceAddresses = typedAddresses.Concat(ServerMoveTransport.ValidAddresses(parsed.SourceAddresses))
                    .Distinct(StringComparer.Ordinal).Take(16).ToArray();
                state = "received";
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
        {
            Fail(cancellation, "The storage locations couldn't be compared with this computer's folders: " + exception.Message);
        }
    }

    private MoveManifest ReadManifest(PreparedRestore result)
    {
        try
        {
            var parsed = ServerMoveLocations.Parse(Path.Combine(backups.RestoreStagePath(result.Id), EncryptedBackupContainer.MoveManifestName));
            if (parsed.ServerId != result.ServerId) throw new InvalidDataException("The move description belongs to another server.");
            return parsed;
        }
        catch (Exception exception) when (exception is InvalidDataException or JsonException or IOException)
        {
            DeleteStage(result.Id);
            throw new AccountException("move_file_invalid", "This file is a backup, not a moving file. On the old server, choose Move to a New Server… › Moving File.", 400);
        }
    }

    private static async Task RewriteStageAsync(string databasePath, IReadOnlyCollection<MovePathMapping> mappings, CancellationToken token)
    {
        await using var database = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = databasePath, Pooling = false }.ToString());
        await database.OpenAsync(token);
        await using var transaction = await database.BeginTransactionAsync(token);
        // Every normalized path is made again: a Mac compares paths without case, Linux with it.
        await ServerMoveLocations.RewriteAsync(database, transaction, mappings, renormalizeAll: true, token);
        await transaction.CommitAsync(token);
    }

    private CancellationTokenSource Begin()
    {
        lock (gate)
        {
            if (state is not ("idle" or "failed")) throw Busy();
            Clear();
            work?.Dispose();
            work = new CancellationTokenSource();
            state = "fetching";
            error = null;
            received = 0;
            expected = null;
            return work;
        }
    }

    private void Reset()
    {
        lock (gate)
        {
            work?.Cancel();
            Clear();
            state = "idle";
        }
    }

    private void Fail(CancellationTokenSource cancellation, string message)
    {
        lock (gate)
        {
            if (work != cancellation) return;
            Clear();
            state = "failed";
            error = message;
        }
    }

    /// <summary>Forgets the received data and removes its stage; the caller holds the gate.</summary>
    private void Clear()
    {
        if (prepared is { } id) DeleteStage(id);
        prepared = null;
        manifest = null;
        source = null;
        locations = [];
        sourceAddresses = [];
        received = 0;
        expected = null;
    }

    private void DeleteStage(Guid id)
    {
        try
        {
            var stage = backups.RestoreStagePath(id);
            if (Directory.Exists(stage)) Directory.Delete(stage, true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    private void DeleteUpload()
    {
        if (upload is { } id) ServerMoveService.TryDelete(backups.TransferPath(id));
        upload = null;
    }

    private static async Task<HttpResponseMessage> SendAsync(HttpClient client, HttpRequestMessage request, CancellationToken token)
    {
        using (request)
        {
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            return await client.SendAsync(request, token);
        }
    }

    private static async Task<ApiProblem?> ProblemAsync(HttpResponseMessage response, CancellationToken token)
    {
        try { return response.Content.Headers.ContentLength is > 65_536 ? null : await response.Content.ReadFromJsonAsync<ApiProblem>(Json, token); }
        catch (Exception exception) when (exception is JsonException or NotSupportedException or HttpRequestException or IOException) { return null; }
    }

    private static AccountException Busy() =>
        new("move_in_progress", "A move is already being received. Discard it first to start again.", 409);

    private static AccountException NotReceived() =>
        new("move_not_received", "No moved data is waiting here. Start the move again.", 409);

    [LoggerMessage(Level = LogLevel.Warning, Message = "The data of the server \"{Name}\" was moved here; the server restarts with it.")]
    private static partial void LogFinished(ILogger logger, string name);
}
