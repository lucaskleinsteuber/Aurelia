using System.Text.Json.Nodes;
using Tarven.Linux.Core.Moving;

namespace Tarven.Linux.Core.Management;

/// <summary>Moving this server to another computer and Storage Location Moved (owner, docs/SERVER_MOVE.md).</summary>
public sealed partial class ManagementClient
{
    public Task<ServerMoveStatus> ServerMoveAsync(CancellationToken cancellation = default) =>
        GetAsync<ServerMoveStatus>("/api/v1/server/move", cancellation);

    /// <summary>A one-use move code for the new server, valid for 15 minutes; starting again replaces an unused one.</summary>
    public Task<ServerMoveStarted> StartNetworkMoveAsync() =>
        SendAsync<ServerMoveStarted>(HttpMethod.Post, "/api/v1/server/move", new { method = "network" });

    /// <summary>
    /// Writes the encrypted moving file with a passphrase and streams it into <paramref name="destination"/>,
    /// downloaded like a backup transfer; the transfer is removed afterwards.
    /// </summary>
    public async Task SaveMovingFileAsync(string passphrase, Stream destination, CancellationToken cancellation = default)
    {
        var started = await SendAsync<ServerMoveStarted>(HttpMethod.Post, "/api/v1/server/move", new { method = "file", passphrase }, cancellation);
        if (started.TransferId is not { } transfer) throw Api.TarvenApiException.InvalidResponse();
        var path = $"/api/v1/server/backups/transfers/{Uri.EscapeDataString(transfer.ToString())}";
        try
        {
            await DownloadToAsync(path, destination, cancellation);
        }
        finally
        {
            try
            {
                await SendAsync<JsonNode>(HttpMethod.Delete, path, null, CancellationToken.None);
            }
            catch (Api.TarvenApiException)
            {
            }
        }
    }

    /// <summary>The new server couldn't report back (a moving file it couldn't reach this server with): this server moved anyway.</summary>
    public Task<ServerMoveStatus> MarkMovedAsync() =>
        SendAsync<ServerMoveStatus>(HttpMethod.Post, "/api/v1/server/move/mark-moved", null);

    /// <summary>Cancels a waiting move, or undoes one that finished.</summary>
    public Task EndMoveAsync() => SendAsync<JsonNode>(HttpMethod.Delete, "/api/v1/server/move", null);

    public Task<RelocateSuggestions> RelocateSuggestionsAsync(Guid libraryId, CancellationToken cancellation = default) =>
        GetAsync<RelocateSuggestions>($"/api/v1/libraries/{libraryId}/relocate/suggestions", cancellation);

    public Task<MoveMatch> PreviewRelocationAsync(Guid libraryId, string path, CancellationToken cancellation = default) =>
        SendAsync<MoveMatch>(HttpMethod.Post, $"/api/v1/libraries/{libraryId}/relocate/preview", new { path }, cancellation);

    /// <summary>Points a storage location at the folder that holds its files now; <paramref name="force"/> only after the second confirmation.</summary>
    public Task RelocateAsync(Guid libraryId, string path, bool force) =>
        SendAsync<JsonNode>(HttpMethod.Post, $"/api/v1/libraries/{libraryId}/relocate", force ? new { path, force = true } : (object)new { path });
}
