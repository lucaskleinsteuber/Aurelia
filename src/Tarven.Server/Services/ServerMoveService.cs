using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Tarven.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Tarven.Server.Services;

public sealed record StartServerMoveRequest(string? Method, string? Passphrase = null);
public sealed record ServerMoveTarget(Guid ServerId, string Name, IReadOnlyList<string> Addresses);
public sealed record ServerMoveStatus(string State, string? Method = null, DateTimeOffset? ExpiresAt = null,
    ServerMoveTarget? MovedTo = null, DateTimeOffset? MovedAt = null);
public sealed record ServerMoveStarted(string State, string Method, string? Code = null, DateTimeOffset? ExpiresAt = null, Guid? TransferId = null);
public sealed record MoveHelloResponse(Guid ServerId, string Name, string Nonce);
public sealed record MoveClaimRequest(string? Nonce, string? ClientNonce, string? Proof);
public sealed record MoveArrivedRequest(string? MoveToken, Guid ServerId, string? Name, string[]? Addresses);
internal sealed record MovePending(int Version, string Method, string TokenHash, Guid? TransferId, DateTimeOffset StartedAt);
internal sealed record MovedRecord(int Version, ServerMoveTarget MovedTo, DateTimeOffset MovedAt, string? Method, string? TokenHash);

/// <summary>
/// The old server's side of a move (docs/SERVER_MOVE.md). A network move's code, nonce and tries
/// live only in memory; what must survive a restart is a hash of the bundle's move token
/// (<see cref="PendingFile"/>) and, once moved, where the server went (<see cref="MovedFile"/>).
/// </summary>
public sealed class ServerMoveService(ServerRuntimeOptions runtime, ServerTlsIdentity tls, TimeProvider clock,
    IServiceScopeFactory scopes, FullServerBackupService backups, ServerConfigurationStore configuration)
{
    public const string PendingFile = "move-pending.json";
    public const string MovedFile = "server-moved.json";
    public const int MaximumProofAttempts = 5;
    public static readonly TimeSpan CodeLifetime = TimeSpan.FromMinutes(15);
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private sealed class Waiting
    {
        public required string Method { get; init; }
        public string? Code { get; init; }
        public byte[]? Nonce { get; init; }
        public DateTimeOffset? ExpiresAt { get; init; }
        public int Attempts { get; set; }
        public Guid? TransferId { get; init; }
        public required string MoveToken { get; init; }
        public bool Claimed { get; set; }
    }

    private readonly Lock gate = new();
    private Waiting? waiting;
    private MovePending? pending;
    private MovedRecord? moved;
    private bool loaded;

    /// <summary>Raised when the server moves or comes back, so Bonjour stops or starts.</summary>
    public event Action? Changed;

    private string PendingPath => Path.Combine(runtime.DataDirectory, PendingFile);
    private string MovedPath => Path.Combine(runtime.DataDirectory, MovedFile);

    public bool IsMoved { get { lock (gate) { Load(); return moved is not null; } } }

    public ServerMoveTarget? MovedTo { get { lock (gate) { Load(); return moved?.MovedTo; } } }

    public ServerMoveStatus Status()
    {
        lock (gate)
        {
            Load();
            Expire();
            if (moved is not null) return new("moved", moved.Method, MovedTo: moved.MovedTo, MovedAt: moved.MovedAt);
            if (waiting is not null) return new(waiting.Claimed ? "transferring" : "waiting", waiting.Method, waiting.ExpiresAt);
            if (pending is not null) return new(pending.Method == "network" ? "transferring" : "waiting", pending.Method);
            return new("none");
        }
    }

    public async Task<ServerMoveStarted> StartAsync(StartServerMoveRequest request, CancellationToken token)
    {
        var method = request.Method?.Trim().ToLowerInvariant();
        if (method is not ("network" or "file"))
            throw new AccountException("move_method_invalid", "Choose a move over the network or with a moving file.", 400);
        if (IsMoved) throw new AccountException("server_moved", "This server has already moved. Undo the move first.", 409);
        var moveToken = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        if (method == "network")
        {
            if (!runtime.LanAccessEnabled || tls.PublicKeyFingerprint is null)
                throw new AccountException("network_access_required", "Moving over the network needs this server's network access. Turn it on, or use a moving file.", 409);
            var code = ServerMoveCrypto.NewCode();
            var expiresAt = clock.GetUtcNow().Add(CodeLifetime);
            Replace(new Waiting
            {
                Method = method,
                Code = code,
                Nonce = RandomNumberGenerator.GetBytes(ServerMoveCrypto.NonceBytes),
                ExpiresAt = expiresAt,
                MoveToken = moveToken,
            }, null);
            return new("waiting", method, ServerMoveCrypto.Display(code), expiresAt);
        }
        var passphrase = request.Passphrase ?? string.Empty;
        if (passphrase.Length is < 12 or > 1024)
            throw new AccountException("passphrase_invalid", "Use a passphrase with 12 to 1024 characters for the moving file.", 400);
        var export = await ExportBundleAsync(moveToken, (stage, names, serverId, stream, cancellation) =>
            EncryptedBackupContainer.EncryptAsync(stage, names, serverId, stream, passphrase, cancellation), token);
        Replace(new Waiting { Method = method, TransferId = export.Id, MoveToken = moveToken },
            new MovePending(1, method, Hash(moveToken), export.Id, clock.GetUtcNow()));
        return new("waiting", method, TransferId: export.Id);
    }

    public async Task<MoveHelloResponse> HelloAsync(CancellationToken token)
    {
        byte[] nonce;
        lock (gate)
        {
            Load();
            Expire();
            if (moved is not null || waiting is not { Method: "network", Claimed: false, Nonce: not null }) throw NotWaiting();
            nonce = waiting.Nonce;
        }
        return new(await ServerIdAsync(token), configuration.Current.ServerName, Convert.ToBase64String(nonce));
    }

    /// <summary>
    /// Checks the new server's proof and, when it is right, writes the move bundle under the derived
    /// key into a transfer file that deletes itself once the response stream closes.
    /// </summary>
    public async Task<(FileStream Bundle, long Length)> ClaimAsync(MoveClaimRequest request, CancellationToken token)
    {
        var spki = OwnSpki() ?? throw NotWaiting();
        byte[] key;
        string moveToken;
        lock (gate)
        {
            Load();
            Expire();
            if (moved is not null || waiting is not { Method: "network", Claimed: false, Code: not null, Nonce: not null }) throw NotWaiting();
            var nonce = ServerMoveCrypto.DecodeNonce(request.Nonce);
            var clientNonce = ServerMoveCrypto.DecodeNonce(request.ClientNonce);
            var proof = ServerMoveCrypto.DecodeNonce(request.Proof);
            if (nonce is null || clientNonce is null || proof is null || !CryptographicOperations.FixedTimeEquals(nonce, waiting.Nonce)
                || !CryptographicOperations.FixedTimeEquals(proof, ServerMoveCrypto.Proof(waiting.Code, nonce, clientNonce, spki)))
            {
                if (++waiting.Attempts >= MaximumProofAttempts)
                {
                    waiting = null;
                    throw new AccountException("move_ended", "The move code was entered wrong five times and ended. Start the move again on the old server.", 403);
                }
                throw new AccountException("move_proof_invalid", "The move code is not right.", 403);
            }
            waiting.Claimed = true;
            moveToken = waiting.MoveToken;
            key = ServerMoveCrypto.BundleKey(waiting.Code, nonce, clientNonce, spki);
            pending = new MovePending(1, "network", Hash(moveToken), null, clock.GetUtcNow());
            WritePrivate(PendingPath, pending);
        }
        try
        {
            var export = await ExportBundleAsync(moveToken, (stage, names, serverId, stream, cancellation) =>
                EncryptedBackupContainer.EncryptWithKeyAsync(stage, names, serverId, stream, key, cancellation), token);
            var path = backups.TransferPath(export.Id);
            var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete, 1024 * 1024,
                FileOptions.Asynchronous | FileOptions.DeleteOnClose);
            return (stream, stream.Length);
        }
        catch
        {
            lock (gate) { waiting = null; pending = null; TryDelete(PendingPath); }
            throw;
        }
        finally { CryptographicOperations.ZeroMemory(key); }
    }

    public async Task ArrivedAsync(MoveArrivedRequest request, CancellationToken token)
    {
        var serverId = await ServerIdAsync(token);
        var name = request.Name?.Trim();
        if (request.ServerId != serverId || string.IsNullOrEmpty(name) || name.Length > 128 || request.MoveToken is not { Length: > 0 and <= 256 })
            throw new AccountException("move_token_invalid", "This report does not belong to this server's move.", 403);
        var hash = Encoding.ASCII.GetBytes(Hash(request.MoveToken));
        lock (gate)
        {
            Load();
            var expected = moved?.TokenHash ?? pending?.TokenHash ?? (waiting is null ? null : Hash(waiting.MoveToken));
            if (expected is null || !CryptographicOperations.FixedTimeEquals(hash, Encoding.ASCII.GetBytes(expected)))
                throw new AccountException("move_token_invalid", "This report does not belong to this server's move.", 403);
            // A report after Mark as Moved (or a repeated one) only adds where the server went.
            SetMoved(new MovedRecord(1, new ServerMoveTarget(serverId, name, ServerMoveTransport.ValidAddresses(request.Addresses)),
                moved?.MovedAt ?? clock.GetUtcNow(), moved?.Method ?? pending?.Method ?? waiting?.Method, expected));
        }
        Changed?.Invoke();
    }

    public async Task<ServerMoveStatus> MarkMovedAsync(CancellationToken token)
    {
        var serverId = await ServerIdAsync(token);
        lock (gate)
        {
            Load();
            if (moved is null)
                SetMoved(new MovedRecord(1, new ServerMoveTarget(serverId, configuration.Current.ServerName, []), clock.GetUtcNow(),
                    pending?.Method ?? waiting?.Method, pending?.TokenHash ?? (waiting is null ? null : Hash(waiting.MoveToken))));
        }
        Changed?.Invoke();
        return Status();
    }

    /// <summary>Cancels a waiting move, or undoes a finished one: the server answers and advertises itself again.</summary>
    public ServerMoveStatus Cancel()
    {
        bool undone;
        lock (gate)
        {
            Load();
            undone = moved is not null;
            if (undone)
            {
                TryDelete(MovedPath);
                moved = null;
            }
            else Replace(null, null);
        }
        if (undone) Changed?.Invoke();
        return Status();
    }

    private Task<BackupExportResult> ExportBundleAsync(string moveToken, BackupContainerWriter writer, CancellationToken token) =>
        backups.ExportMoveAsync(writer, async (stageDatabase, cancellation) =>
        {
            var serverId = await ServerIdAsync(cancellation);
            var locations = await ServerMoveLocations.ReadLocationsAsync(stageDatabase, cancellation);
            return ServerMoveLocations.Serialize(new MoveManifest(1, serverId, configuration.Current.ServerName, moveToken,
                ServerMoveTransport.LocalAddresses(runtime.LanHttpsPort), locations));
        }, token);

    private byte[]? OwnSpki() => tls.PublicKeyFingerprint is { } hex ? Convert.FromHexString(hex) : null;

    private async Task<Guid> ServerIdAsync(CancellationToken token)
    {
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
        return (await database.ServerIdentities.AsNoTracking().SingleAsync(identity => identity.Id == 1, token)).ServerId;
    }

    private static AccountException NotWaiting() =>
        new("move_not_waiting", "This server is not waiting for a move. Start the move on the old server first.", 404);

    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    /// <summary>Replaces the waiting move; a replaced moving file's transfer is removed.</summary>
    private void Replace(Waiting? next, MovePending? nextPending)
    {
        lock (gate)
        {
            Load();
            foreach (var transfer in new[] { waiting?.TransferId, pending?.TransferId }.OfType<Guid>().Distinct())
                if (transfer != next?.TransferId) TryDelete(backups.TransferPath(transfer));
            waiting = next;
            pending = nextPending;
            if (nextPending is null) TryDelete(PendingPath);
            else WritePrivate(PendingPath, nextPending);
        }
    }

    private void SetMoved(MovedRecord record)
    {
        WritePrivate(MovedPath, record);
        moved = record;
        waiting = null;
        pending = null;
        TryDelete(PendingPath);
    }

    private void Expire()
    {
        if (waiting is { Method: "network", Claimed: false } && waiting.ExpiresAt <= clock.GetUtcNow()) waiting = null;
    }

    private void Load()
    {
        if (loaded) return;
        loaded = true;
        moved = Read<MovedRecord>(MovedPath);
        if (moved is not null && (moved.Version != 1 || moved.MovedTo is null)) moved = null;
        pending = Read<MovePending>(PendingPath);
        if (pending is not null && (pending.Version != 1 || pending.Method is not ("network" or "file") || string.IsNullOrEmpty(pending.TokenHash))) pending = null;
    }

    private static T? Read<T>(string path) where T : class
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null || info.Length > 64 * 1024) return null;
            return JsonSerializer.Deserialize<T>(File.ReadAllBytes(path), Json);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    internal static void WritePrivate<T>(string path, T value)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporary))
            {
                JsonSerializer.Serialize(file, value, Json);
                file.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally { TryDelete(temporary); }
    }

    internal static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
