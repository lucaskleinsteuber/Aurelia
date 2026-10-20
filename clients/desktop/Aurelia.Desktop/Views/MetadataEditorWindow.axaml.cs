using System.ComponentModel;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Views;

/// <summary>Edit Details for one title in its own window, as the Mac metadata editor.</summary>
public sealed partial class MetadataEditorWindow : Window
{
    private bool closingConfirmed;

    public MetadataEditorWindow()
    {
        InitializeComponent();
    }

    internal MetadataEditorWindow(MetadataEditorModel model) : this()
    {
        DataContext = model;
        model.PropertyChanged += PreviewChanged;
        model.Saved += () => { closingConfirmed = true; Close(); };
        Opened += async (_, _) =>
        {
            await model.LoadAsync();
            if (!model.IsLoaded && !model.HasError) Close();
            await ShowPreviewAsync(PosterPreview, model.Poster);
            await ShowPreviewAsync(BackdropPreview, model.Backdrop);
        };
        Closing += async (_, e) =>
        {
            if (closingConfirmed) return;
            // Unsaved images are drafts on the server; they go away with the editor.
            e.Cancel = true;
            closingConfirmed = true;
            await model.DiscardAsync();
            Close();
        };
    }

    /// <summary>Picks an image without a dialog, for tests; the app uses the system file picker.</summary>
    internal Func<Task<byte[]?>>? ImageSource { get; set; }

    private MetadataEditorModel? Model => DataContext as MetadataEditorModel;

    private async void PreviewChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (Model is not { } model) return;
        if (e.PropertyName == nameof(MetadataEditorModel.Poster)) await ShowPreviewAsync(PosterPreview, model.Poster);
        if (e.PropertyName == nameof(MetadataEditorModel.Backdrop)) await ShowPreviewAsync(BackdropPreview, model.Backdrop);
    }

    private async Task ShowPreviewAsync(Image target, EditorArtwork? selection)
    {
        if (Model is not { } model) return;
        var bytes = await model.ImageAsync(selection);
        (target.Source as IDisposable)?.Dispose();
        if (bytes is null)
        {
            target.Source = null;
            return;
        }
        try
        {
            using var stream = new MemoryStream(bytes);
            target.Source = Bitmap.DecodeToWidth(stream, 480);
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or NotSupportedException)
        {
            target.Source = null;
        }
    }

    private async void ChoosePoster(object? sender, RoutedEventArgs e) => await ChooseAsync(poster: true);

    private async void ChooseBackdrop(object? sender, RoutedEventArgs e) => await ChooseAsync(poster: false);

    private async Task ChooseAsync(bool poster)
    {
        if (Model is not { } model || await PickImageAsync() is not { } image) return;
        await model.ChooseImageAsync(poster, image);
    }

    private async Task<byte[]?> PickImageAsync()
    {
        if (ImageSource is { } source) return await source();
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Choose an Image",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("JPEG or PNG Images") { Patterns = ["*.jpg", "*.jpeg", "*.png"] }],
        });
        if (files.Count == 0) return null;
        await using var stream = await files[0].OpenReadAsync();
        // Larger files are refused by the server anyway; read at most a little more than its limit.
        using var memory = new MemoryStream();
        var buffer = new byte[81_920];
        int read;
        while ((read = await stream.ReadAsync(buffer)) > 0)
        {
            memory.Write(buffer, 0, read);
            if (memory.Length > 21 * 1024 * 1024) break;
        }
        return memory.ToArray();
    }

    private void UseAutomatic(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model && (sender as Control)?.Tag is string field) model.UseAutomatic(field);
    }

    private async void Save(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.SaveAsync();
    }

    private void Cancel(object? sender, RoutedEventArgs e) => Close();
}
