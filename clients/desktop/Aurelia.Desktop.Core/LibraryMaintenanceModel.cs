using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>A storage location in the reset list.</summary>
public sealed class ResetChoice(LibrarySummary library) : INotifyPropertyChanged
{
    public LibrarySummary Library => library;
    public string Name => library.Name;
    public bool IsSelected { get; set { if (field == value) return; field = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected))); } }
    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>
/// Library maintenance in Server Settings › Storage, as on the Mac: sources removed from Aurelia stay
/// excluded until reimported, and a reset removes chosen storage locations with their catalog after
/// reviewing what goes. Video files are never changed.
/// </summary>
public sealed class LibraryMaintenanceModel(Func<IAdministrationClient> client) : INotifyPropertyChanged
{
    private ResetLibraryPreview? preview;
    private int exclusionLoads;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>A reimport or a reset changed the library; Storage reloads.</summary>
    public event Action? LibraryChanged;

    public bool IsBusy { get; private set => Set(ref field, value); }
    public string? Error { get; private set => Set(ref field, value, nameof(Error), nameof(HasError)); }
    public bool HasError => Error is not null;
    public string? Notice { get; private set => Set(ref field, value, nameof(Notice), nameof(HasNotice)); }
    public bool HasNotice => Notice is not null;

    public ObservableCollection<LibrarySummary> Libraries { get; } = [];
    public LibrarySummary? ExclusionLibrary { get; set { if (Set(ref field, value)) _ = LoadExclusionsAsync(); } }
    public ObservableCollection<ExcludedMediaSummary> Exclusions { get; } = [];
    public bool HasExclusions => Exclusions.Count > 0;

    public bool ShowsReset { get; private set => Set(ref field, value); }
    public ObservableCollection<ResetChoice> ResetChoices { get; } = [];
    public string? ResetSummary { get; private set => Set(ref field, value, nameof(ResetSummary), nameof(IsResetReviewed)); }
    public bool IsResetReviewed => ResetSummary is not null;

    public const string ResetExplanation =
        "This deletes catalog entries, metadata, images, favorites and playback history for all users. Storage locations must be added again " +
        "afterward. Videos, accounts, devices, server settings and the server's identity are never deleted; existing backups are kept.";

    /// <summary>The storage locations as Server Settings last loaded them.</summary>
    public void Show(IEnumerable<LibrarySummary> libraries)
    {
        var current = ExclusionLibrary?.Id;
        Libraries.Clear();
        foreach (var library in libraries) Libraries.Add(library);
        ExclusionLibrary = Libraries.FirstOrDefault(library => library.Id == current) ?? Libraries.FirstOrDefault();
    }

    /// <summary>The chosen location's excluded sources; loads independently of other work so a choice always shows its list.</summary>
    public async Task LoadExclusionsAsync()
    {
        if (ExclusionLibrary is not { } library) return;
        var load = ++exclusionLoads;
        try
        {
            var excluded = await client().SendAsync<IReadOnlyList<ExcludedMediaSummary>>(HttpMethod.Get, $"/api/v1/libraries/{library.Id}/exclusions",
                null, CancellationToken.None);
            // Only the latest load shows its list.
            if (load != exclusionLoads || ExclusionLibrary?.Id != library.Id) return;
            Exclusions.Clear();
            foreach (var item in excluded.OrderBy(item => item.RelativePath, StringComparer.CurrentCultureIgnoreCase)) Exclusions.Add(item);
            Changed(nameof(HasExclusions));
        }
        catch (AureliaApiException error) { Error = error.Message; }
    }

    /// <summary>Lets a removed source back into scans and scans its location.</summary>
    public Task ReimportAsync(ExcludedMediaSummary item) => RunAsync(async token =>
    {
        await client().SendAsync<AureliaServerApi.NoContent>(HttpMethod.Delete, $"/api/v1/libraries/{item.LibraryId}/exclusions/{item.Id}", null, token);
        try { await client().SendAsync<LibraryScanSummary>(HttpMethod.Post, $"/api/v1/libraries/{item.LibraryId}/scans", null, token); }
        catch (AureliaApiException error) when (error.Code == "library_scan_active") { }
        Notice = $"{item.RelativePath} is scanned again and returns to the library.";
        Exclusions.Remove(item);
        Changed(nameof(HasExclusions));
        LibraryChanged?.Invoke();
    });

    public void BeginReset()
    {
        ResetChoices.Clear();
        foreach (var library in Libraries)
        {
            var choice = new ResetChoice(library);
            choice.PropertyChanged += (_, _) => { preview = null; ResetSummary = null; };
            ResetChoices.Add(choice);
        }
        preview = null;
        ResetSummary = null;
        Error = null;
        ShowsReset = true;
    }

    public void CancelReset() => ShowsReset = false;

    /// <summary>Counts what a reset of the chosen locations would remove, before anything happens.</summary>
    public Task ReviewResetAsync()
    {
        var chosen = ResetChoices.Where(choice => choice.IsSelected).Select(choice => choice.Library.Id).ToList();
        if (chosen.Count == 0) return Fail("Choose at least one storage location.");
        return RunAsync(async token =>
        {
            preview = await client().SendAsync<ResetLibraryPreview>(HttpMethod.Post, "/api/v1/libraries/reset/preview", chosen, token);
            ResetSummary = $"{preview.Titles} catalog entries · {preview.Artwork} images · {preview.StorageLocations} storage locations";
        });
    }

    public Task ResetAsync() => preview is not { } reviewed ? Task.CompletedTask : RunAsync(async token =>
    {
        var result = await client().SendAsync<LibraryMutationResult>(HttpMethod.Post, "/api/v1/libraries/reset",
            new ResetLibraryRequest(reviewed.LibraryIds, reviewed.Revision), token);
        Notice = result.State == "completed"
            ? "Reset complete. Your video files were not changed."
            : "The catalog was removed; images are cleaned up in the background. Your video files were not changed.";
        ShowsReset = false;
        preview = null;
        ResetSummary = null;
        LibraryChanged?.Invoke();
    });

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
        catch (AureliaApiException error) when (error.Code == "reset_conflict")
        {
            preview = null;
            ResetSummary = null;
            Error = "The library changed since the review. Review the reset again.";
        }
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
