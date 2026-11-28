using System.Globalization;
using Tarven.Linux.Core.Api;

namespace Tarven.Linux.Core.Moving;

/// <summary>Which folder a storage location of a moved server uses on this computer.</summary>
public enum MoveChoiceKind
{
    /// <summary>A folder Tarven suggested.</summary>
    Suggestion,

    /// <summary>A folder the person chose or typed.</summary>
    Folder,

    /// <summary>Later: the location keeps its old path and stays offline until Storage Location Moved…</summary>
    Later,
}

public sealed record MoveChoice(MoveChoiceKind Kind, string? Path)
{
    public static readonly MoveChoice Later = new(MoveChoiceKind.Later, null);
}

/// <summary>What the old server's move offers in Settings › Server, as the browser and the Mac show it.</summary>
public enum ServerMoveAction
{
    Start,
    NewCode,
    Cancel,
    MarkMoved,
    Undo,
}

public sealed record ServerMoveView(string State, string Summary, IReadOnlyList<ServerMoveAction> Actions);

/// <summary>Whether a previewed folder can become a storage location's new folder.</summary>
public sealed record RelocateDecision(bool CanConfirm, bool Force, bool NeedsSecondConfirmation, string Text);

/// <summary>
/// The rules of moving to a new server that need no screen (docs/SERVER_MOVE.md), the same as the
/// browser app's js/server-move.js: move codes, match counts, the mapping sent at the end, the old
/// server's state and Storage Location Moved.
/// </summary>
public static class ServerMoveText
{
    public const int MoveCodeLength = 12;

    /// <summary>"abcd efgh-jkmn" becomes "ABCD-EFGH-JKMN": twelve letters and digits in groups of four.</summary>
    public static string FormatCode(string? text)
    {
        var characters = new string((text ?? "").ToUpperInvariant().Where(char.IsAsciiLetterOrDigit).Take(MoveCodeLength).ToArray());
        return string.Join('-', characters.Chunk(4).Select(group => new string(group)));
    }

    public static bool IsCompleteCode(string? text) => FormatCode(text).Replace("-", "", StringComparison.Ordinal).Length == MoveCodeLength;

    /// <summary>"412 of 415 sample files found".</summary>
    public static string MatchText(int matched, int sampled)
    {
        if (sampled <= 0) return "This location had no files to compare.";
        var files = sampled == 1 ? "sample file" : "sample files";
        if (matched <= 0) return $"None of {sampled.ToString(CultureInfo.InvariantCulture)} {files} found";
        if (matched >= sampled) return $"All {sampled.ToString(CultureInfo.InvariantCulture)} {files} found";
        return $"{matched.ToString(CultureInfo.InvariantCulture)} of {sampled.ToString(CultureInfo.InvariantCulture)} sample files found";
    }

    /// <summary>The fraction for a progress bar (null while the size is unknown) and its text.</summary>
    public static (double? Fraction, string Text) Progress(SetupMoveProgress? progress)
    {
        var received = Math.Max(0, progress?.Received ?? 0);
        var expected = Math.Max(0, progress?.Expected ?? 0L);
        if (expected == 0) return (null, received > 0 ? Bytes(received) + " received" : "Waiting for the old server…");
        return (Math.Min(1, (double)received / expected), $"{Bytes(received)} of {Bytes(expected)}");
    }

    /// <summary>A location's suggestions, the most matches first; ties keep the server's order.</summary>
    public static IReadOnlyList<MoveSuggestion> Ranked(IEnumerable<MoveSuggestion>? suggestions) =>
        [.. (suggestions ?? []).Where(s => !string.IsNullOrWhiteSpace(s.Path)).Select((s, index) => (s, index))
            .OrderByDescending(pair => pair.s.Matched).ThenBy(pair => pair.index).Select(pair => pair.s)];

    /// <summary>A location starts with its best suggestion when that found files, else Later.</summary>
    public static MoveChoice InitialChoice(SetupMoveLocation location)
    {
        var ranked = Ranked(location.Suggestions);
        return ranked.Count > 0 && ranked[0].Matched > 0 ? new MoveChoice(MoveChoiceKind.Suggestion, ranked[0].Path) : MoveChoice.Later;
    }

    /// <summary>
    /// The body of POST /api/v1/setup/move/finish: one mapping per location. Returns a problem to
    /// show instead when a chosen folder is missing or not a whole path.
    /// </summary>
    public static (FinishMoveRequest? Request, string? Problem) Mappings(IReadOnlyList<SetupMoveLocation> locations, IReadOnlyDictionary<Guid, MoveChoice> choices)
    {
        List<MoveMapping> mappings = [];
        foreach (var location in locations)
        {
            var choice = choices.TryGetValue(location.Id, out var chosen) ? chosen : InitialChoice(location);
            if (choice.Kind == MoveChoiceKind.Later)
            {
                mappings.Add(new MoveMapping(location.Id, null));
                continue;
            }
            var path = choice.Path?.Trim() ?? "";
            if (path.Length == 0) return (null, $"Choose a folder for “{location.Name}”, or choose Later.");
            if (!path.StartsWith('/')) return (null, $"Enter the whole path of the folder for “{location.Name}”, starting with /.");
            mappings.Add(new MoveMapping(location.Id, path));
        }
        return (new FinishMoveRequest(mappings), null);
    }

    /// <summary>The old server's move as Settings › Server shows it, with the actions that fit.</summary>
    public static ServerMoveView OwnerView(ServerMoveStatus? status, DateTimeOffset now)
    {
        switch (status?.State)
        {
            case "waiting" when status.Method == "file":
                return new("waiting", "Waiting for the new server to open the moving file.", [ServerMoveAction.MarkMoved, ServerMoveAction.Cancel]);
            case "waiting":
                var left = status.ExpiresAt is { } expires ? expires - now : TimeSpan.Zero;
                return new("waiting", left > TimeSpan.Zero
                    ? $"Waiting for the new server · the code works for {Countdown(left)}"
                    : "The move code has expired. Start again for a new one.", [ServerMoveAction.NewCode, ServerMoveAction.Cancel]);
            case "transferring":
                return new("transferring", "The new server is receiving the data…", [ServerMoveAction.Cancel]);
            case "moved":
                var name = status.MovedTo is { } target ? $"“{target.DisplayName}”" : "a new server";
                var when = status.MovedAt is { } at ? " on " + at.ToLocalTime().ToString("d MMM yyyy, HH:mm", CultureInfo.InvariantCulture) : "";
                return new("moved", $"This server moved to {name}{when}. Devices switch there on their own.", [ServerMoveAction.Undo]);
            default:
                return new("none", "Not moved. Start a move when the new computer is ready.",
                    [ServerMoveAction.Start]);
        }
    }

    /// <summary>"14:30" or "1:02:03" for what is left of a move code.</summary>
    public static string Countdown(TimeSpan left)
    {
        if (left <= TimeSpan.Zero) return "0:00";
        var seconds = (int)Math.Ceiling(left.TotalSeconds);
        var hours = seconds / 3600;
        var minutes = seconds % 3600 / 60;
        var rest = seconds % 60;
        return hours > 0
            ? string.Create(CultureInfo.InvariantCulture, $"{hours}:{minutes:00}:{rest:00}")
            : string.Create(CultureInfo.InvariantCulture, $"{minutes}:{rest:00}");
    }

    /// <summary>
    /// Storage Location Moved: a folder with matching sample files can be confirmed; one without any
    /// needs a second, explicit confirmation and is then sent with force.
    /// </summary>
    public static RelocateDecision Relocate(MoveMatch? preview, bool confirmedEmpty)
    {
        if (preview is null) return new(false, false, false, "Choose a folder and preview it first.");
        if (preview.Matched > 0) return new(true, false, false, MatchText(preview.Matched, preview.Sampled));
        var text = preview.Sampled > 0 ? MatchText(0, preview.Sampled) + ". This may be the wrong folder." : MatchText(0, 0);
        return new(confirmedEmpty, confirmedEmpty, true, text);
    }

    /// <summary>A sentence for the move problems a server reports (docs/SERVER_MOVE.md).</summary>
    public static string Problem(Exception failure) => failure switch
    {
        TarvenApiException { Code: "move_not_waiting" } =>
            "The old server isn't waiting for a move. On the old server, choose Move to a New Server… and use the code it shows.",
        TarvenApiException { Code: "move_code_invalid" or "invalid_move_code" } => "That move code is not right or has expired. Check the code the old server shows.",
        TarvenApiException { Code: "move_address_invalid" } => "Enter the old server's address, such as 192.168.1.20.",
        TarvenApiException { Code: "move_source_unreachable" or "move_source_failed" } =>
            "The old server couldn't be reached at that address. Check that it is on and shows its move code.",
        TarvenApiException { Code: "move_in_progress" } => "A move is already under way on this server.",
        TarvenApiException { Code: "backup_invalid" or "invalid_passphrase" or "backup_passphrase_invalid" } => "The passphrase doesn't open this moving file.",
        TarvenApiException { Code: "move_file_invalid" } => "This file is not a moving file. On the old server, choose Move to a New Server… › With a Moving File.",
        TarvenApiException { Code: "move_not_received" } => "The old server's data hasn't arrived yet. Start the move again.",
        TarvenApiException { Code: "folder_invalid" } => "Choose an existing folder on this computer, with its whole path.",
        TarvenApiException { Code: "locations_overlap" } => "Two storage locations can't use the same folder. Choose another folder, or Later.",
        TarvenApiException { Code: "server_already_setup" or "setup_unavailable" } => "This server already has an owner, so it can't receive a move.",
        TarvenApiException { Code: "passphrase_invalid" } => "Use a passphrase with at least 12 characters.",
        TarvenApiException { Code: "network_access_required" } =>
            "A move over the network needs this server's network access. Turn it on in Network, or use a moving file.",
        TarvenApiException { Code: "relocate_no_matches" } => "None of the sample files are in that folder. Confirm it explicitly to use it anyway.",
        TarvenApiException { Code: "library_scan_active" } => "This storage location is being scanned. Try again when the scan finished.",
        TarvenApiException { Code: "identity_mismatch" } => "The old server's identity changed during the move. Start again.",
        TarvenApiException { Status: 404, Code: null or "http_404" } => "This server's version can't move yet. Update Tarven first.",
        _ => failure.Message,
    };

    /// <summary>The message shown when a saved server moved and could not be followed.</summary>
    public static string NotFollowed(MovedServer? moved, bool differentKey, string serverName)
    {
        var target = moved is null ? "another computer" : $"“{moved.DisplayName}”";
        return differentKey
            ? $"{serverName} moved to {target}, but the server there presents a different key than the one this computer trusts. Connect to it again to check its identity."
            : $"{serverName} moved to {target}, which doesn't answer yet. Check that the new server is on.";
    }

    internal static string Bytes(long bytes)
    {
        if (bytes < 1024) return bytes.ToString(CultureInfo.InvariantCulture) + " B";
        string[] units = ["KB", "MB", "GB", "TB"];
        var size = bytes / 1024.0;
        var unit = 0;
        while (size >= 1024 && unit < units.Length - 1)
        {
            size /= 1024;
            unit++;
        }
        return size.ToString(size < 10 ? "0.0" : "0", CultureInfo.InvariantCulture) + " " + units[unit];
    }
}
