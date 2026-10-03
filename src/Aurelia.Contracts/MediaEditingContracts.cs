namespace Aurelia.Contracts;

public sealed record ArtworkCrop(double X, double Y, double Width, double Height, int Rotation = 0);
public sealed record EditorArtwork(Guid? AssetId = null, Guid? UploadId = null, ArtworkCrop? Crop = null);
public sealed record EditorCredit(Guid Id, string Name, string Department, string? Job, string? Character,
    EditorArtwork? Profile, string? PersonKey = null);
public sealed record MediaEditorValues(string Title, int? ReleaseYear, string? Overview, int? RuntimeMinutes,
    int? FskAge, IReadOnlyList<string> Genres, IReadOnlyList<string> Studios, string? Country,
    IReadOnlyList<EditorCredit> Credits, EditorArtwork? Poster, EditorArtwork? Backdrop);
public sealed record MediaEditorDocument(Guid MediaId, Guid LibraryId, MediaKind Kind, long Revision,
    MediaEditorValues Values, IReadOnlyList<string> OverrideFields, string SourcePath, string RelativeSourcePath,
    MediaEditorValues AutomaticValues);
public sealed record SaveMediaEditorRequest(long Revision, MediaEditorValues Values,
    IReadOnlyList<string> OverrideFields, string? RelativeSourcePath = null);
public sealed record EditorUploadSummary(Guid Id, string Path, int Width, int Height);
public sealed record ServerFileEntry(string Name, string RelativePath, bool IsDirectory, long? Bytes);
public sealed record ServerFileListing(Guid LibraryId, string RelativePath, IReadOnlyList<ServerFileEntry> Entries);
public sealed record ExcludedMediaSummary(Guid Id, Guid LibraryId, string RelativePath, bool IsDirectory);
public sealed record ResetLibraryRequest(IReadOnlyList<Guid> LibraryIds, string Revision);
public sealed record ResetLibraryPreview(IReadOnlyList<Guid> LibraryIds, string Revision, int Titles, int Files,
    int Artwork, int StorageLocations);
public sealed record LibraryMutationResult(Guid Id, string State, int RemovedItems, string? Error);
