using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>
/// "Edit Details" for one title, as the Mac metadata editor: every field the person changes becomes
/// a manual value that later scans and provider updates keep; "Use Automatic" returns a field to
/// what Aurelia found. Images are uploaded as drafts and become the title's poster or backdrop only
/// when saved. Files on disk are never changed.
/// </summary>
public sealed class MetadataEditorModel(ManagementAccess management, Guid mediaId) : INotifyPropertyChanged
{
    /// <summary>"No age rating" followed by the German FSK ratings, as the Mac editor offers them.</summary>
    public static readonly IReadOnlyList<string> AgeRatings = ["No Rating", "FSK 0", "FSK 6", "FSK 12", "FSK 16", "FSK 18"];
    private static readonly int?[] Ages = [null, 0, 6, 12, 16, 18];
    private readonly HashSet<string> overrides = new(StringComparer.Ordinal);
    private readonly List<Guid> uploads = [];
    private MediaEditorDocument? document;
    private bool loading;
    private bool dirty;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>The changes were saved; the library shows them.</summary>
    public event Action? Saved;

    public Guid MediaId => mediaId;
    public bool IsLoaded => document is not null;
    public bool IsBusy { get; private set => Set(ref field, value); }
    public string? Error { get; private set => Set(ref field, value, nameof(Error), nameof(HasError)); }
    public bool HasError => Error is not null;
    public bool IsMovie => document?.Kind == MediaKind.Movie;
    public string KindName => document?.Kind switch
    {
        MediaKind.Movie => "Movie",
        MediaKind.Series => "TV Show",
        MediaKind.Episode => "Episode",
        _ => "Title",
    };
    public string SourcePath => document?.RelativeSourcePath ?? "";
    public string BackdropName => document?.Kind == MediaKind.Episode ? "Still" : "Backdrop";

    public string Title { get; set => Change(ref field, value, "title"); } = "";
    public string Year { get; set => Change(ref field, value, "releaseYear"); } = "";
    public string Overview { get; set => Change(ref field, value, "overview"); } = "";
    public string Runtime { get; set => Change(ref field, value, "runtimeMinutes"); } = "";
    public int AgeIndex { get; set => Change(ref field, Math.Clamp(value, 0, Ages.Length - 1), "fsk"); }
    public string Genres { get; set => Change(ref field, value, "genres"); } = "";
    public string Studios { get; set => Change(ref field, value, "studios"); } = "";
    public string Country { get; set => Change(ref field, value, "country"); } = "";
    public EditorArtwork? Poster { get; private set => Set(ref field, value, nameof(Poster), nameof(PosterText)); }
    public EditorArtwork? Backdrop { get; private set => Set(ref field, value, nameof(Backdrop), nameof(BackdropText)); }
    public string PosterText => Describe(Poster, "poster");
    public string BackdropText => Describe(Backdrop, "backdrop");

    /// <summary>Fields with a manual value, shown with a "Use Automatic" choice.</summary>
    public IReadOnlyCollection<string> Overrides => overrides;
    public bool IsDirty => document is not null && dirty;
    public bool TitleIsManual => overrides.Contains("title");
    public bool YearIsManual => overrides.Contains("releaseYear");
    public bool OverviewIsManual => overrides.Contains("overview");
    public bool RuntimeIsManual => overrides.Contains("runtimeMinutes");
    public bool AgeIsManual => overrides.Contains("fsk");
    public bool GenresAreManual => overrides.Contains("genres");
    public bool StudiosAreManual => overrides.Contains("studios");
    public bool CountryIsManual => overrides.Contains("country");
    public bool PosterIsManual => overrides.Contains("poster");
    public bool BackdropIsManual => overrides.Contains("backdrop");
    private static readonly string[] ManualProperties =
        [nameof(Overrides), nameof(IsDirty), nameof(Problem), nameof(TitleIsManual), nameof(YearIsManual), nameof(OverviewIsManual),
         nameof(RuntimeIsManual), nameof(AgeIsManual), nameof(GenresAreManual), nameof(StudiosAreManual), nameof(CountryIsManual),
         nameof(PosterIsManual), nameof(BackdropIsManual)];

    public string? Problem
    {
        get
        {
            if (Title.Trim().Length == 0) return "Enter a title.";
            if (Year.Trim().Length > 0 && !(int.TryParse(Year.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var year) && year is >= 1800 and <= 3000))
                return "Enter a year between 1800 and 3000, or leave it empty.";
            if (Runtime.Trim().Length > 0 && !(int.TryParse(Runtime.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var minutes) && minutes is >= 1 and <= 14_400))
                return "Enter the runtime in minutes, or leave it empty.";
            return null;
        }
    }

    public bool IsManual(string field) => overrides.Contains(field);

    public Task LoadAsync() => RunAsync(async token =>
    {
        Show(await management.SendAsync<MediaEditorDocument>(HttpMethod.Get, $"/api/v1/media/{mediaId}/editor", null, token));
    });

    /// <summary>Returns a field to the value Aurelia found automatically.</summary>
    public void UseAutomatic(string field)
    {
        if (document?.AutomaticValues is not { } automatic) return;
        loading = true;
        try
        {
            switch (field)
            {
                case "title": Title = automatic.Title; break;
                case "releaseYear": Year = Number(automatic.ReleaseYear); break;
                case "overview": Overview = automatic.Overview ?? ""; break;
                case "runtimeMinutes": Runtime = Number(automatic.RuntimeMinutes); break;
                case "fsk": AgeIndex = Array.IndexOf(Ages, automatic.FskAge) is var index and >= 0 ? index : 0; break;
                case "genres": Genres = string.Join(", ", automatic.Genres); break;
                case "studios": Studios = string.Join(", ", automatic.Studios); break;
                case "country": Country = automatic.Country ?? ""; break;
                case "poster": Poster = automatic.Poster; break;
                case "backdrop": Backdrop = automatic.Backdrop; break;
            }
        }
        finally { loading = false; }
        overrides.Remove(field);
        dirty = true;
        Changed(ManualProperties);
    }

    /// <summary>Uploads a JPEG or PNG the person chose as a draft for the poster or backdrop.</summary>
    public Task ChooseImageAsync(bool poster, byte[] image) => RunAsync(async token =>
    {
        if (image.Length is 0 or > 20 * 1024 * 1024)
        {
            Error = "Choose a JPEG or PNG image of at most 20 MB.";
            return;
        }
        var upload = await management.SendBytesAsync<EditorUploadSummary>(HttpMethod.Post, $"/api/v1/media/{mediaId}/editor/uploads",
            image, "application/octet-stream", token);
        uploads.Add(upload.Id);
        var selection = new EditorArtwork(UploadId: upload.Id);
        if (poster) Poster = selection;
        else Backdrop = selection;
        overrides.Add(poster ? "poster" : "backdrop");
        dirty = true;
        Changed(ManualProperties);
    });

    /// <summary>The picture behind a poster or backdrop choice, for the preview.</summary>
    public async Task<byte[]?> ImageAsync(EditorArtwork? selection)
    {
        var path = selection switch
        {
            { UploadId: { } upload } => $"/api/v1/media/{mediaId}/editor/uploads/{upload}",
            { AssetId: { } asset } => $"/api/v1/media/{mediaId}/editor/artwork/{asset}",
            _ => null,
        };
        if (path is null) return null;
        try { return await management.SendAsync<byte[]>(HttpMethod.Get, path, null, CancellationToken.None); }
        catch (Exception error) when (error is AureliaApiException or OperationCanceledException) { return null; }
    }

    public Task SaveAsync() => RunAsync(async token =>
    {
        if (document is null) return;
        if (Problem is { } problem)
        {
            Error = problem;
            return;
        }
        var saved = await management.SendAsync<MediaEditorDocument>(HttpMethod.Put, $"/api/v1/media/{mediaId}/editor",
            new SaveMediaEditorRequest(document.Revision, Values(), [.. overrides.Order(StringComparer.Ordinal)]), token);
        uploads.Clear();
        Show(saved);
        Saved?.Invoke();
    }, conflict: "This title changed on the server meanwhile. Close the editor and open it again to see the current details.");

    /// <summary>Closing without saving: draft images go away on the server.</summary>
    public async Task DiscardAsync()
    {
        foreach (var upload in uploads.ToArray())
        {
            try { await management.SendAsync<AureliaServerApi.NoContent>(HttpMethod.Delete, $"/api/v1/media/{mediaId}/editor/uploads/{upload}", null, CancellationToken.None); }
            catch (Exception error) when (error is AureliaApiException or OperationCanceledException) { }
        }
        uploads.Clear();
    }

    private MediaEditorValues Values()
    {
        var current = document!.Values;
        return current with
        {
            Title = Title.Trim(),
            ReleaseYear = ParseNumber(Year),
            Overview = Overview.Trim().Length == 0 ? null : Overview.Trim(),
            RuntimeMinutes = ParseNumber(Runtime),
            FskAge = Ages[AgeIndex],
            Genres = List(Genres),
            Studios = List(Studios),
            Country = Country.Trim().Length == 0 ? null : Country.Trim(),
            Poster = Poster,
            Backdrop = Backdrop,
        };
    }

    private void Show(MediaEditorDocument loaded)
    {
        document = loaded;
        overrides.Clear();
        overrides.UnionWith(loaded.OverrideFields);
        var values = loaded.Values;
        loading = true;
        try
        {
            Title = values.Title;
            Year = Number(values.ReleaseYear);
            Overview = values.Overview ?? "";
            Runtime = Number(values.RuntimeMinutes);
            AgeIndex = Array.IndexOf(Ages, values.FskAge) is var index and >= 0 ? index : 0;
            Genres = string.Join(", ", values.Genres);
            Studios = string.Join(", ", values.Studios);
            Country = values.Country ?? "";
            Poster = values.Poster;
            Backdrop = values.Backdrop;
        }
        finally { loading = false; }
        dirty = false;
        Changed(nameof(IsLoaded), nameof(IsMovie), nameof(KindName), nameof(SourcePath), nameof(BackdropName));
        Changed(ManualProperties);
    }

    private async Task RunAsync(Func<CancellationToken, Task> operation, string? conflict = null)
    {
        if (IsBusy) return;
        IsBusy = true;
        Error = null;
        try { await operation(CancellationToken.None); }
        catch (OperationCanceledException) { Error = "Enter the Server Password to edit this title."; }
        catch (AureliaApiException error) { Error = error.Code == "editor_conflict" && conflict is not null ? conflict : error.Message; }
        finally { IsBusy = false; }
    }

    private static string Describe(EditorArtwork? artwork, string name) => artwork switch
    {
        { UploadId: not null } => $"New {name}, saved with the other changes",
        { AssetId: not null } => $"Current {name}",
        _ => $"No {name}",
    };

    private static string Number(int? value) => value?.ToString(CultureInfo.InvariantCulture) ?? "";

    private static int? ParseNumber(string text) =>
        int.TryParse(text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var value) ? value : null;

    private static IReadOnlyList<string> List(string text) =>
        [.. text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct(StringComparer.CurrentCultureIgnoreCase)];

    private void Change<T>(ref T field, T value, string manualField, [CallerMemberName] string name = "")
    {
        if (!Set(ref field, value, name) || loading) return;
        overrides.Add(manualField);
        dirty = true;
        Changed(ManualProperties);
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
