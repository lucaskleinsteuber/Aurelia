using Aurelia.Contracts;
using Aurelia.Linux.Core;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Aurelia.Linux.Controls;

/// <summary>
/// A round profile picture: the profile's own photo, a built-in symbol on its palette, or the initial on the
/// gradient its id picks, as on the Mac.
/// </summary>
public sealed class ProfileAvatar : Border
{
    private static readonly Dictionary<(Guid, long), Bitmap> Photos = [];

    /// <summary>Loads a profile's photo from the server; null where no server is connected (tests, previews).</summary>
    public static Func<Guid, long, CancellationToken, Task<byte[]>>? PhotoSource { get; set; }

    /// <summary>
    /// Where photos are kept per revision on this computer, so a known photo is drawn in the first
    /// frame (the profile picker's rise-in no longer shows the initial first); null keeps them in memory only.
    /// </summary>
    public static string? PhotoFolder { get; set; }

    public ProfileAvatar(Guid? id, string name, double size, string? pictureKey = null, long pictureRevision = 0)
    {
        Width = size;
        Height = size;
        CornerRadius = new CornerRadius(size / 2);
        ClipToBounds = true;
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF));
        BorderThickness = new Thickness(1);
        if (ProfileVisuals.Builtin(pictureKey) is { } builtin)
        {
            Background = Gradient(ProfileVisuals.NamedPalette(builtin.Palette));
            Child = Symbol(builtin.Symbol, size);
            return;
        }
        Background = Gradient(ProfileVisuals.Palettes[ProfileVisuals.PaletteIndex(id)]);
        // While a photo loads only the plain gradient shows, never the initial it then replaces.
        if (pictureKey == ProfilePictures.PhotoKey && id is { } profile) ShowPhoto(profile, pictureRevision, name, size);
        else Child = Initial(name, size);
    }

    public ProfileAvatar(UserSummary user, double size)
        : this(user.Id, ProfileVisuals.ShownName(user), size, user.PictureKey, user.PictureRevision)
    {
    }

    public ProfileAvatar(WatchingProfile profile, double size)
        : this(profile.Id, profile.Name, size, profile.PictureKey, profile.PictureRevision)
    {
    }

    internal static LinearGradientBrush Gradient((string Top, string Bottom) colors) => new()
    {
        StartPoint = new RelativePoint(0.5, 0, RelativeUnit.Relative),
        EndPoint = new RelativePoint(0.5, 1, RelativeUnit.Relative),
        GradientStops = { new GradientStop(Color.Parse(colors.Top), 0), new GradientStop(Color.Parse(colors.Bottom), 1) },
    };

    internal static PathIcon Symbol(string symbol, double size) => new()
    {
        Data = Application.Current?.FindResource("ProfileSymbol_" + symbol) as Geometry,
        Width = size * 0.5,
        Height = size * 0.5,
        Foreground = Brushes.White,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static TextBlock Initial(string name, double size) => new()
    {
        Text = ProfileVisuals.Initial(name),
        FontSize = size * 0.42,
        FontWeight = FontWeight.SemiBold,
        Foreground = Brushes.White,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>Shows the photo at once when it is known, else once it arrives; the initial shows if it cannot be loaded.</summary>
    private void ShowPhoto(Guid id, long revision, string name, double size)
    {
        if ((Photos.GetValueOrDefault((id, revision)) ?? FromDisk(id, revision)) is { } cached)
        {
            Photos[(id, revision)] = cached;
            ShowPicture(cached);
            return;
        }
        if (PhotoSource is not { } source)
        {
            Child = Initial(name, size);
            return;
        }
        _ = LoadAsync();

        async Task LoadAsync()
        {
            try
            {
                var bytes = await source(id, revision, CancellationToken.None);
                using var stream = new MemoryStream(bytes);
                var bitmap = new Bitmap(stream);
                ToDisk(id, revision, bytes);
                Dispatcher.UIThread.Post(() =>
                {
                    Photos[(id, revision)] = bitmap;
                    ShowPicture(bitmap);
                });
            }
            catch (Exception failure) when (failure is Core.Api.AureliaApiException or IOException or ArgumentException or InvalidOperationException
                or UnauthorizedAccessException or System.Net.Http.HttpRequestException or OperationCanceledException)
            {
                Dispatcher.UIThread.Post(() => Child ??= Initial(name, size));
            }
        }
    }

    private static string? PhotoPath(Guid id, long revision) =>
        PhotoFolder is { } folder ? Path.Combine(folder, $"{id:N}-{revision.ToString(System.Globalization.CultureInfo.InvariantCulture)}.image") : null;

    private static Bitmap? FromDisk(Guid id, long revision)
    {
        if (PhotoPath(id, revision) is not { } path || !File.Exists(path)) return null;
        try
        {
            return new Bitmap(path);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>Keeps the photo of this revision and drops the profile's earlier ones.</summary>
    private static void ToDisk(Guid id, long revision, byte[] bytes)
    {
        if (PhotoPath(id, revision) is not { } path) return;
        try
        {
            Core.Settings.PrivateFiles.CreateDirectory(Path.GetDirectoryName(path)!);
            foreach (var earlier in Directory.EnumerateFiles(Path.GetDirectoryName(path)!, $"{id:N}-*.image"))
                if (earlier != path) File.Delete(earlier);
            var partial = path + ".tmp";
            File.WriteAllBytes(partial, bytes);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(partial, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            File.Move(partial, path, overwrite: true);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
        {
            // Loaded from the server again next time.
        }
    }

    /// <summary>The photo alone: no gradient beneath it, which showed as a colored rim at its edge.</summary>
    private void ShowPicture(Bitmap bitmap)
    {
        Background = Brushes.Transparent;
        Child = new Image { Source = bitmap, Stretch = Stretch.UniformToFill, Width = Width, Height = Height };
    }
}
