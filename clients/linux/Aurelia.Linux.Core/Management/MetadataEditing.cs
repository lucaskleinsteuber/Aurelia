using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Management;

/// <summary>The rules of the metadata editor, as the Mac app's MetadataEditorView checks them before saving.</summary>
public static class MetadataEditing
{
    public static readonly int[] FskAges = [0, 6, 12, 16, 18];

    /// <summary>Why the values cannot be saved, or null when they can.</summary>
    public static string? Problem(MediaEditorValues values)
    {
        if (string.IsNullOrWhiteSpace(values.Title)) return "Enter a title.";
        if (values.ReleaseYear is { } year && year is < 1800 or > 3000) return "Enter a year from 1800 to 3000, or leave it empty.";
        if (values.RuntimeMinutes is { } runtime && runtime is < 1 or > 14_400) return "Enter 1–14,400 minutes, or leave it empty.";
        if (values.Credits.Any(credit => string.IsNullOrWhiteSpace(credit.Name))) return "Enter a name for every person, or remove the empty entry.";
        return null;
    }

    /// <summary>A comma separated list as distinct, trimmed entries.</summary>
    public static IReadOnlyList<string> List(string? text) =>
        [.. (text ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct(StringComparer.CurrentCultureIgnoreCase)];

    /// <summary>
    /// The fields whose values differ from the automatic ones, plus those already overridden that
    /// still differ: those are saved as manual changes and survive scans and provider refreshes.
    /// </summary>
    public static IReadOnlyList<string> Overrides(MediaEditorValues values, MediaEditorValues automatic, IEnumerable<string> existing, IReadOnlySet<string> reset)
    {
        var fields = new HashSet<string>(existing.Where(field => !reset.Contains(field)), StringComparer.Ordinal);
        void Check(string field, bool differs)
        {
            if (reset.Contains(field)) fields.Remove(field);
            else if (differs) fields.Add(field);
        }
        Check("title", values.Title != automatic.Title);
        Check("releaseYear", values.ReleaseYear != automatic.ReleaseYear);
        Check("overview", (values.Overview ?? "") != (automatic.Overview ?? ""));
        Check("runtimeMinutes", values.RuntimeMinutes != automatic.RuntimeMinutes);
        Check("fsk", values.FskAge != automatic.FskAge);
        Check("genres", !values.Genres.SequenceEqual(automatic.Genres));
        Check("studios", !values.Studios.SequenceEqual(automatic.Studios));
        Check("country", (values.Country ?? "") != (automatic.Country ?? ""));
        Check("credits", !SameCredits(values.Credits, automatic.Credits));
        Check("poster", values.Poster != automatic.Poster);
        Check("backdrop", values.Backdrop != automatic.Backdrop);
        return [.. fields.Order(StringComparer.Ordinal)];
    }

    private static bool SameCredits(IReadOnlyList<EditorCredit> left, IReadOnlyList<EditorCredit> right) =>
        left.Count == right.Count && left.Zip(right).All(pair => pair.First.Name == pair.Second.Name && pair.First.Department == pair.Second.Department
            && pair.First.Job == pair.Second.Job && pair.First.Character == pair.Second.Character && pair.First.Profile == pair.Second.Profile);

    /// <summary>
    /// A crop of the given aspect ratio (width / height) inside an image rotated by
    /// <paramref name="rotation"/> degrees, as fractions of the rotated image. Zoom 1 is the largest
    /// such crop; <paramref name="x"/> and <paramref name="y"/> from 0 to 1 move it across the image.
    /// </summary>
    public static ArtworkCrop Crop(int width, int height, int rotation, double aspect, double zoom, double x, double y)
    {
        var (w, h) = rotation is 90 or 270 ? ((double)height, (double)width) : (width, height);
        double cropWidth, cropHeight;
        if (w / h > aspect)
        {
            cropHeight = 1;
            cropWidth = h * aspect / w;
        }
        else
        {
            cropWidth = 1;
            cropHeight = w / aspect / h;
        }
        zoom = Math.Clamp(zoom, 1, 8);
        cropWidth /= zoom;
        cropHeight /= zoom;
        return new ArtworkCrop((1 - cropWidth) * Math.Clamp(x, 0, 1), (1 - cropHeight) * Math.Clamp(y, 0, 1), cropWidth, cropHeight, rotation);
    }

    public static string FskLabel(int? age) => age is { } value ? $"FSK {value}" : "Not specified";
}
