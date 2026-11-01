using Aurelia.Contracts;
using Aurelia.Linux.Core.Library;

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

    void EditCollection(CollectionSummary? collection, CatalogItemSummary? preselected);

    /// <summary>Asks the person to confirm a change; true when they chose <paramref name="confirmLabel"/>.</summary>
    Task<bool> ConfirmAsync(string title, string message, string confirmLabel, bool destructive);
}

public sealed class LibraryContext(LibraryStore store, ILibraryNavigator navigator)
{
    public LibraryStore Store { get; } = store;

    public ILibraryNavigator Navigator { get; } = navigator;

    public void OpenDetail(CatalogItemSummary item) => Navigator.OpenDetail(item);

    public void OpenCollection(CollectionSummary collection) => Navigator.OpenCollection(collection);

    public void OpenPerson(string name, string? personKey) => Navigator.OpenPerson(name, personKey);

    public void Play(CatalogItemSummary item, bool resume) => Navigator.Play(item, fromLastPosition: resume);
}
