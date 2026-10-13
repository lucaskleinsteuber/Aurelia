namespace Aurelia.Contracts;

public sealed record SceneNoteSummary(
    Guid Id, Guid MediaId, long StartMilliseconds, long? EndMilliseconds,
    string Text, long Revision);

// Revision zero creates a new client-generated ID; positive revisions update it.
public sealed record SaveSceneNoteRequest(
    long StartMilliseconds, long? EndMilliseconds, string Text, long Revision);
