using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Playback;

/// <summary>
/// Which scene notes show while playing, as on the Mac: a note appears when playback passes its
/// start and stays six seconds; at most three show at once. A jump of more than five seconds, or
/// backwards, does not replay the notes it skipped.
/// </summary>
public sealed class SceneNoteCues
{
    public static readonly TimeSpan ShowFor = TimeSpan.FromSeconds(6);
    public const int MaximumShown = 3;
    private readonly List<(SceneNoteSummary Note, DateTimeOffset Until)> shown = [];
    private long last = -1;

    public IReadOnlyList<SceneNoteSummary> Notes { get; private set; } = [];

    public void Replace(IReadOnlyList<SceneNoteSummary> notes)
    {
        Notes = [.. notes.OrderBy(n => n.StartMilliseconds)];
        shown.RemoveAll(cue => !Notes.Any(n => n.Id == cue.Note.Id));
    }

    /// <summary>Moves to a new position and returns the notes to show now.</summary>
    public IReadOnlyList<SceneNoteSummary> Advance(long position, DateTimeOffset now)
    {
        shown.RemoveAll(cue => cue.Until <= now);
        var jumped = last < 0 || position < last || position - last > 5000;
        if (!jumped)
        {
            foreach (var note in Notes.Where(n => n.StartMilliseconds > last && n.StartMilliseconds <= position))
            {
                shown.RemoveAll(cue => cue.Note.Id == note.Id);
                shown.Add((note, now + ShowFor));
            }
        }
        last = position;
        while (shown.Count > MaximumShown) shown.RemoveAt(0);
        return [.. shown.Select(cue => cue.Note)];
    }
}
