using Aurelia.Contracts;
using Aurelia.Linux.Core;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.VisualTree;

namespace Aurelia.Linux.Controls;

/// <summary>
/// Chooses a profile picture: a symbol and a color, an own photo from this computer, or the initial.
/// The choice is applied by whoever shows the picker (<see cref="Choice"/>), so nothing is sent while choosing.
/// </summary>
public sealed class ProfilePicturePicker : StackPanel
{
    private readonly Guid? id;
    private readonly Func<string> name;
    private readonly Border preview = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private readonly WrapPanel symbols = new() { Orientation = Orientation.Horizontal };
    private readonly WrapPanel palettes = new() { Orientation = Orientation.Horizontal };
    private readonly TextBlock problem = new() { Foreground = new SolidColorBrush(Color.Parse("#FF8A8A")), FontSize = 12, IsVisible = false, TextWrapping = TextWrapping.Wrap };
    private readonly string? original;
    private readonly long revision;
    private string symbol = "star";
    private string palette = "blue";
    private Image? photoPreview;
    // A cropped photo is sent at most this large; the server shrinks it further for avatars.
    private const int CroppedPhotoSide = 1024;
    private readonly Button adjust = new() { Content = "Adjust Photo…", Classes = { "chip" } };
    // The photo chosen in this picker before cropping, and its last crop, for Adjust Photo.
    private byte[]? chosenOriginal;
    private ArtworkCrop? chosenCrop;

    public ProfilePicturePicker(Guid? id, Func<string> name, string? pictureKey, long pictureRevision)
    {
        this.id = id;
        this.name = name;
        original = pictureKey;
        revision = pictureRevision;
        Spacing = 10;
        if (ProfileVisuals.Builtin(pictureKey) is { } builtin)
        {
            symbol = builtin.Symbol;
            palette = builtin.Palette;
            Key = pictureKey;
        }
        else
        {
            Key = pictureKey == ProfilePictures.PhotoKey ? ProfilePictures.PhotoKey : null;
            if (id is { } known) palette = ProfilePictures.Palettes[ProfileVisuals.PaletteIndex(known)];
        }
        var photo = new Button { Content = "Choose Photo…", Classes = { "chip" } };
        photo.Click += async (_, _) => await ChoosePhotoAsync();
        adjust.Click += async (_, _) => await AdjustPhotoAsync();
        var initial = new Button { Content = "Use Initial", Classes = { "chip" } };
        initial.Click += (_, _) =>
        {
            Key = null;
            Photo = null;
            Refresh();
        };
        Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 14,
            Children = { preview, new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center, Children = { photo, adjust, initial } } },
        });
        Children.Add(symbols);
        Children.Add(palettes);
        Children.Add(problem);
        Refresh();
    }

    /// <summary>The chosen picture: a built-in key, "photo" with <see cref="Photo"/> (new) or the stored photo, or null.</summary>
    public string? Key { get; private set; }

    /// <summary>A newly chosen photo: the square chosen in the crop sheet, or the file's bytes where no sheet can open.</summary>
    public byte[]? Photo { get; private set; }

    public bool Changed => Photo is not null || Key != original;

    /// <summary>Repaints the preview, for example after the name changed.</summary>
    public void Refresh()
    {
        adjust.IsVisible = Key == ProfilePictures.PhotoKey && (chosenOriginal is not null || (Photo is null && id is not null && ProfileAvatar.PhotoSource is not null));
        if (photoPreview?.Parent is Border shown) shown.Child = null;
        preview.Child = photoPreview is not null && Key == ProfilePictures.PhotoKey && Photo is not null
            ? new Border { Width = 72, Height = 72, CornerRadius = new CornerRadius(36), ClipToBounds = true, Child = photoPreview }
            : new ProfileAvatar(id, name(), 72, Key, revision);
        symbols.Children.Clear();
        foreach (var candidate in ProfilePictures.Symbols)
        {
            var button = new Button
            {
                Classes = { "plain" },
                Padding = new Thickness(2),
                Margin = new Thickness(0, 0, 4, 4),
                Content = new Border
                {
                    Width = 34,
                    Height = 34,
                    CornerRadius = new CornerRadius(17),
                    Background = ProfileAvatar.Gradient(ProfileVisuals.NamedPalette(palette)),
                    BorderBrush = Key == ProfilePictures.Builtin(candidate, palette) ? Brushes.White : Brushes.Transparent,
                    BorderThickness = new Thickness(2),
                    Child = ProfileAvatar.Symbol(candidate, 34),
                },
            };
            AutomationProperties.SetName(button, "Picture " + candidate);
            var chosen = candidate;
            button.Click += (_, _) =>
            {
                symbol = chosen;
                Key = ProfilePictures.Builtin(symbol, palette);
                Photo = null;
                Refresh();
            };
            symbols.Children.Add(button);
        }
        palettes.Children.Clear();
        foreach (var candidate in ProfilePictures.Palettes)
        {
            var swatch = new Button
            {
                Classes = { "plain" },
                Padding = new Thickness(2),
                Margin = new Thickness(0, 0, 6, 0),
                Content = new Border
                {
                    Width = 24,
                    Height = 24,
                    CornerRadius = new CornerRadius(12),
                    Background = ProfileAvatar.Gradient(ProfileVisuals.NamedPalette(candidate)),
                    BorderBrush = candidate == palette ? Brushes.White : Brushes.Transparent,
                    BorderThickness = new Thickness(2),
                },
            };
            AutomationProperties.SetName(swatch, "Color " + candidate);
            var chosen = candidate;
            swatch.Click += (_, _) =>
            {
                palette = chosen;
                Key = ProfilePictures.Builtin(symbol, palette);
                Photo = null;
                Refresh();
            };
            palettes.Children.Add(swatch);
        }
    }

    /// <summary>Uses a photo already read from a file (also for tests, which have no file picker).</summary>
    public void UsePhoto(byte[] bytes) => UsePhoto(bytes, apply: true);

    /// <summary>Checks the photo; with <paramref name="apply"/> it also becomes the chosen picture.</summary>
    private void UsePhoto(byte[] bytes, bool apply)
    {
        problem.IsVisible = false;
        if (bytes.Length > ProfilePictures.MaximumUploadBytes)
        {
            problem.Text = "Choose a photo no larger than 8 MB.";
            problem.IsVisible = true;
            return;
        }
        try
        {
            using var stream = new MemoryStream(bytes);
            var shown = new Image { Source = new Bitmap(stream), Stretch = Stretch.UniformToFill };
            if (apply) photoPreview = shown;
        }
        catch (Exception failure) when (failure is ArgumentException or InvalidOperationException or IOException or NotSupportedException)
        {
            problem.Text = "This file is not a picture Aurelia can read. Choose a JPEG or PNG photo.";
            problem.IsVisible = true;
            return;
        }
        if (!apply) return;
        Photo = bytes;
        Key = ProfilePictures.PhotoKey;
        Refresh();
    }

    private async Task ChoosePhotoAsync()
    {
        if (TopLevel.GetTopLevel(this)?.StorageProvider is not { } storage) return;
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Choose a Photo",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("Photos") { Patterns = ["*.jpg", "*.jpeg", "*.png", "*.webp"], MimeTypes = ["image/jpeg", "image/png", "image/webp"] }],
        });
        if (files.Count == 0) return;
        byte[] bytes;
        await using (var stream = await files[0].OpenReadAsync())
        {
            using var copy = new MemoryStream();
            var buffer = new byte[65_536];
            int read;
            while ((read = await stream.ReadAsync(buffer)) > 0)
            {
                if (copy.Length + read > ProfilePictures.MaximumUploadBytes + 1) break;
                copy.Write(buffer, 0, read);
            }
            bytes = copy.ToArray();
        }
        await CropAsync(bytes, null);
    }

    /// <summary>
    /// As on the Mac: the photo opens in the crop sheet as a square with a round preview, and only
    /// the chosen square is sent. Cancel keeps the picture the profile had.
    /// </summary>
    private async Task CropAsync(byte[] source, ArtworkCrop? existing)
    {
        UsePhoto(source, apply: false);
        if (problem.IsVisible) return;
        if (Sheets() is not { } sheets)
        {
            UsePhoto(source);
            return;
        }
        var sheet = new Management.CropSheet(sheets, source, 1, existing, "Crop Photo", "Use Photo");
        if (!await sheets.ShowAsync(sheet) || sheet.Result is not { } crop) return;
        if (Management.CropSheet.Render(source, crop, CroppedPhotoSide) is not { } square) return;
        chosenOriginal = source;
        chosenCrop = crop;
        UsePhoto(square);
    }

    /// <summary>Reopens the crop sheet with the photo chosen here, or with the saved photo, which can only be framed tighter.</summary>
    private async Task AdjustPhotoAsync()
    {
        if (chosenOriginal is { } chosen)
        {
            await CropAsync(chosen, chosenCrop);
            return;
        }
        if (id is not { } profile || ProfileAvatar.PhotoSource is not { } source) return;
        try
        {
            await CropAsync(await source(profile, revision, CancellationToken.None), null);
        }
        catch (Exception failure) when (failure is Core.Api.AureliaApiException or InvalidOperationException or IOException or System.Net.Http.HttpRequestException)
        {
            problem.Text = "The saved photo could not be loaded. Choose the photo again.";
            problem.IsVisible = true;
        }
    }

    /// <summary>The sheet layer this picker is shown in, or the one beside the page that holds it.</summary>
    private Library.SheetHost? Sheets() =>
        this.GetVisualAncestors().OfType<Library.SheetHost>().FirstOrDefault()
        ?? this.GetVisualAncestors().OfType<Panel>().SelectMany(panel => panel.Children.OfType<Library.SheetHost>()).FirstOrDefault();
}
