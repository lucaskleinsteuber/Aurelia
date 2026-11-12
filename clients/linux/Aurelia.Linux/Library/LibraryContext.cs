using Aurelia.Contracts;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Playback;

namespace Aurelia.Linux.Library;

/// <summary>
/// What every library page needs from the shell: the profile's library and the ways to move
/// around (open a title, a collection or a person), to play, to ask before a change and to edit
/// collections. The shell implements it; tests can record the calls.
/// </summary>
public interface ILibraryNavigator
{
    void OpenDetail(CatalogItemSummary item);

    void OpenCollection(CollectionSummary collection);

    void OpenPerson(string name, string? personKey);

    void Back();

    void Play(CatalogItemSummary item, bool fromLastPosition);

    void PlayCollection(IReadOnlyList<CatalogItemSummary> playlist, CatalogItemSummary target, bool fromLastPosition) =>
        Play(target, fromLastPosition);

    void EditCollection(CollectionSummary? collection, CatalogItemSummary? preselected);

    void EditCollection(CollectionSummary? collection, CatalogItemSummary? preselected, int? seasonNumber) =>
        EditCollection(collection, preselected);

    /// <summary>Play On: other players in the household, or null before a profile is open.</summary>
    RemotePlayback? Remote { get; }

    /// <summary>Asks the person to confirm a change; true when they chose <paramref name="confirmLabel"/>.</summary>
    Task<bool> ConfirmAsync(string title, string message, string confirmLabel, bool destructive);

    /// <summary>An administrator's change to a title: edit its metadata, match it or remove it from the library.</summary>
    Task ManageTitleAsync(CatalogItemSummary item, TitleAction action) => Task.CompletedTask;

    /// <summary>Watch Together parties on the server, to join from a title's page.</summary>
    Task<IReadOnlyList<WatchPartySummary>> WatchPartiesAsync() => Task.FromResult<IReadOnlyList<WatchPartySummary>>([]);

    Task JoinWatchTogetherAsync(WatchPartySummary party) => Task.CompletedTask;

    /// <summary>Opens Movie Night: a new night, or <paramref name="joining"/>.</summary>
    Task ShowMovieNightAsync(MovieNightSummary? joining) => Task.CompletedTask;

    /// <summary>Plays the profile's year as Wrapped slides.</summary>
    Task ShowWrappedAsync(int year, int? month = null) => Task.CompletedTask;

    /// <summary>Downloads on this computer, or null where downloads are not offered.</summary>
    Aurelia.Linux.Core.Playback.OfflineDownloads? Downloads => null;

    void Download(CatalogItemSummary item) { }

    void PlayOffline(Aurelia.Linux.Core.Playback.OfflineTitle title) { }
}

public enum TitleAction
{
    EditMetadata,
    FindMatch,
    Remove,
}

public sealed class LibraryContext(LibraryStore store, ILibraryNavigator navigator)
{
    public LibraryStore Store { get; } = store;

    public ILibraryNavigator Navigator { get; } = navigator;

    public void OpenDetail(CatalogItemSummary item) => Navigator.OpenDetail(item);

    public void OpenCollection(CollectionSummary collection) => Navigator.OpenCollection(collection);

    public void OpenPerson(string name, string? personKey) => Navigator.OpenPerson(name, personKey);

    public void Play(CatalogItemSummary item, bool resume) => Navigator.Play(item, fromLastPosition: resume);

    public void PlayCollection(IReadOnlyList<CatalogItemSummary> playlist, CatalogItemSummary target, bool resume) =>
        Navigator.PlayCollection(playlist, target, resume);
}
