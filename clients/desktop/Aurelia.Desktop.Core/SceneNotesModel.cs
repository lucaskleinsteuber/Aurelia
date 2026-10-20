using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>A note as the list shows it: its time and text; choosing it jumps there.</summary>
public sealed record SceneNoteRow(SceneNoteSummary Note)
{
    public string TimeLabel => PlayerPolicy.TimeLabel(Note.StartMilliseconds)
        + (Note.EndMilliseconds is { } end ? " – " + PlayerPolicy.TimeLabel(end) : "");
    public string Text => Note.Text.Length == 0 ? "Marked scene" : Note.Text;
}

/// <summary>
/// Scene Notes in the player, as on the Mac: moments or time ranges with a short note, private to the
/// profile. Playback keeps running while a note is written.
/// </summary>
public sealed class SceneNotesModel(ILibraryApi api, Func<Guid> media, Func<long> position, Action<long> seek) : INotifyPropertyChanged
{
    private Guid draftId;
    private long draftRevision;

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<SceneNoteRow> Notes { get; } = [];
    public bool HasNotes => Notes.Count > 0;
    public bool IsBusy { get; private set => Set(ref field, value); }
    public string? Error { get; private set => Set(ref field, value, nameof(Error), nameof(HasError)); }
    public bool HasError => Error is not null;
    public bool IsEditing { get; private set => Set(ref field, value, nameof(IsEditing), nameof(ShowsCreate)); }
    public bool ShowsCreate => !IsEditing;
    public bool IsRange { get; set => Set(ref field, value); }
    public string Start { get; set => Set(ref field, value); } = "";
    public string End { get; set => Set(ref field, value); } = "";
    public string Text { get; set => Set(ref field, value); } = "";

    public Task LoadAsync() => RunAsync(async token => Show(await api.SceneNotesAsync(media(), token)));

    /// <summary>A new note at the current position.</summary>
    public void Create()
    {
        draftId = Guid.NewGuid();
        draftRevision = 0;
        var now = position();
        Start = PlayerPolicy.TimeLabel(now);
        End = PlayerPolicy.TimeLabel(now + 30_000);
        IsRange = false;
        Text = "";
        Error = null;
        IsEditing = true;
    }

    public void Edit(SceneNoteRow row)
    {
        draftId = row.Note.Id;
        draftRevision = row.Note.Revision;
        Start = PlayerPolicy.TimeLabel(row.Note.StartMilliseconds);
        IsRange = row.Note.EndMilliseconds is not null;
        End = PlayerPolicy.TimeLabel(row.Note.EndMilliseconds ?? row.Note.StartMilliseconds + 30_000);
        Text = row.Note.Text;
        Error = null;
        IsEditing = true;
    }

    public void Cancel()
    {
        IsEditing = false;
        Error = null;
    }

    public Task SaveAsync()
    {
        if (ParseTime(Start) is not { } start) return Fail("Enter the start as minutes and seconds, such as 12:30 or 1:02:45.");
        long? end = null;
        if (IsRange)
        {
            if (ParseTime(End) is not { } until || until <= start) return Fail("The end must come after the start.");
            end = until;
        }
        if (Text.Length > 2000) return Fail("Keep the note to 2,000 characters.");
        return RunAsync(async token =>
        {
            await api.SaveSceneNoteAsync(media(), draftId, new SaveSceneNoteRequest(start, end, Text.Trim(), draftRevision), token);
            IsEditing = false;
            Show(await api.SceneNotesAsync(media(), token));
        });
    }

    public Task RemoveAsync(SceneNoteRow row) => RunAsync(async token =>
    {
        await api.RemoveSceneNoteAsync(media(), row.Note.Id, row.Note.Revision, token);
        Show(await api.SceneNotesAsync(media(), token));
    });

    public void Jump(SceneNoteRow row) => seek(row.Note.StartMilliseconds);

    /// <summary>"12:30" or "1:02:45" in milliseconds.</summary>
    public static long? ParseTime(string text)
    {
        var parts = text.Trim().Split(':');
        if (parts.Length is < 2 or > 3) return null;
        var numbers = new long[parts.Length];
        for (var index = 0; index < parts.Length; index++)
        {
            if (!long.TryParse(parts[index], NumberStyles.None, CultureInfo.InvariantCulture, out numbers[index])) return null;
            if (index > 0 && numbers[index] > 59) return null;
        }
        var seconds = parts.Length == 3 ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2] : numbers[0] * 60 + numbers[1];
        return seconds * 1000;
    }

    private void Show(IReadOnlyList<SceneNoteSummary> notes)
    {
        Notes.Clear();
        foreach (var note in notes.OrderBy(note => note.StartMilliseconds)) Notes.Add(new SceneNoteRow(note));
        Changed(nameof(HasNotes));
    }

    private Task Fail(string message)
    {
        Error = message;
        return Task.CompletedTask;
    }

    private async Task RunAsync(Func<CancellationToken, Task> operation)
    {
        if (IsBusy) return;
        IsBusy = true;
        Error = null;
        try { await operation(CancellationToken.None); }
        catch (AureliaApiException error) { Error = error.Message; }
        finally { IsBusy = false; }
    }

    private void Changed(params string[] names)
    {
        foreach (var name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string name = "", params string[] also)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Changed(name);
        Changed(also);
        return true;
    }
}
