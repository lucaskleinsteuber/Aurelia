namespace Tarven.Linux.Core.Moving;

/// <summary>
/// Storage Location Moved…: points a storage location at the folder that holds its files now (a new
/// disk or computer). A suggested folder comes with its match count; another folder is previewed
/// first. A folder without any matching sample file needs a second, explicit confirmation and is
/// then sent with force. Titles, progress and artwork stay; media files are only read.
/// </summary>
public sealed class RelocateModel
{
    private MoveMatch? preview;
    private string previewed = "";
    private string path = "";

    public int Sampled { get; private set; }

    /// <summary>The suggested folders, the most matching sample files first.</summary>
    public IReadOnlyList<MoveSuggestion> Suggestions { get; private set; } = [];

    /// <summary>The folder chosen or typed.</summary>
    public string Path
    {
        get => path;
        set
        {
            path = value ?? "";
            ConfirmedEmpty = false;
        }
    }

    /// <summary>The person confirmed a folder without any matching sample file.</summary>
    public bool ConfirmedEmpty { get; set; }

    public void Load(RelocateSuggestions suggestions)
    {
        Sampled = suggestions.Sampled;
        Suggestions = ServerMoveText.Ranked(suggestions.Suggestions);
    }

    /// <summary>A suggested folder: its match count is known already, no preview is needed.</summary>
    public void Choose(MoveSuggestion suggestion)
    {
        Path = suggestion.Path;
        Previewed(suggestion.Path, new MoveMatch(Sampled, suggestion.Matched));
    }

    /// <summary>The server compared the folder with the location's sample files.</summary>
    public void Previewed(string folder, MoveMatch match)
    {
        previewed = folder.Trim();
        preview = match;
        ConfirmedEmpty = false;
    }

    /// <summary>What may be confirmed now: only the folder that was previewed, as it was previewed.</summary>
    public RelocateDecision Decision =>
        ServerMoveText.Relocate(previewed.Length > 0 && previewed == Path.Trim() ? preview : null, ConfirmedEmpty);

    /// <summary>The folder and whether to force it, once it may be confirmed; null before.</summary>
    public (string Path, bool Force)? Request => Decision is { CanConfirm: true } decision ? (previewed, decision.Force) : null;
}
