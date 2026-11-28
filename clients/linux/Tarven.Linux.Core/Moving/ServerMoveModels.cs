using Tarven.Linux.Core.Api;

namespace Tarven.Linux.Core.Moving;

// Moving a whole server to another computer (docs/SERVER_MOVE.md). The answers are shaped as the
// server sends them; they live here and not in Tarven.Contracts, because only this app reads them.

/// <summary>Where a server that moved went: its id, name and the addresses it answers at now.</summary>
public sealed record MovedServer(Guid ServerId, string? Name, IReadOnlyList<string>? Addresses)
{
    /// <summary>
    /// The addresses worth trying for the saved server <paramref name="serverId"/>: only when the
    /// moved server is the same server, only HTTPS, and none tried before. Each one still has to
    /// present the pinned key before Tarven switches to it.
    /// </summary>
    public IReadOnlyList<Uri> Followable(Guid serverId, IEnumerable<Uri> tried)
    {
        if (ServerId != serverId) return [];
        var seen = new HashSet<string>(tried.Select(Key), StringComparer.OrdinalIgnoreCase);
        List<Uri> result = [];
        foreach (var text in Addresses ?? [])
        {
            if (!Uri.TryCreate(text, UriKind.Absolute, out var parsed) || parsed.Scheme != Uri.UriSchemeHttps) continue;
            if (!ServerAddress.TryNormalize(parsed.GetLeftPart(UriPartial.Authority), out var address)) continue;
            if (seen.Add(Key(address))) result.Add(address);
        }
        return result;
    }

    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? "the new server" : Name.Trim();

    private static string Key(Uri address) => address.GetLeftPart(UriPartial.Authority);
}

/// <summary>GET /api/v1/server/move on the old server.</summary>
public sealed record ServerMoveStatus(string State, string? Method = null, DateTimeOffset? ExpiresAt = null, MovedServer? MovedTo = null,
    DateTimeOffset? MovedAt = null);

/// <summary>POST /api/v1/server/move: a move code for the network, or the moving file's transfer.</summary>
public sealed record ServerMoveStarted(string State, string Method, string? Code = null, DateTimeOffset? ExpiresAt = null, Guid? TransferId = null);

/// <summary>How much of the old server's data arrived; the expected size is unknown at first.</summary>
public sealed record SetupMoveProgress(long Received, long? Expected = null);

public sealed record SetupMoveSource(Guid ServerId, string? Name);

/// <summary>A folder on the new computer that may hold a storage location's files, with how many sample files it has.</summary>
public sealed record MoveSuggestion(string Path, int Matched);

/// <summary>A storage location of the old server, with the folders that may hold its files here.</summary>
public sealed record SetupMoveLocation(Guid Id, string Name, string? OldPath, int Sampled, IReadOnlyList<MoveSuggestion>? Suggestions = null);

/// <summary>GET /api/v1/setup/move on the new server before it has an owner.</summary>
public sealed record SetupMoveStatus(string State, SetupMoveProgress? Progress = null, string? Error = null, SetupMoveSource? Source = null,
    IReadOnlyList<SetupMoveLocation>? Locations = null);

/// <summary>How many of a location's sample files a folder holds (same relative path and size).</summary>
public sealed record MoveMatch(int Sampled, int Matched);

/// <summary>GET /api/v1/libraries/{id}/relocate/suggestions.</summary>
public sealed record RelocateSuggestions(int Sampled, IReadOnlyList<MoveSuggestion>? Suggestions);

/// <summary>One location in POST /api/v1/setup/move/finish; a null path keeps the old one, offline.</summary>
public sealed record MoveMapping(Guid Id, string? Path);

public sealed record FinishMoveRequest(IReadOnlyList<MoveMapping> Mappings);

internal sealed record UploadedMovingFile(string UploadId);

/// <summary>A problem answer that may say where a moved server went (409 server_moved).</summary>
internal sealed record MovedProblem(string? Code, string? Message, MovedServer? MovedTo);

/// <summary>Only the part of the public server info that says the server moved.</summary>
internal sealed record MovedInfo(MovedServer? Moved);
