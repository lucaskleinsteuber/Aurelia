using Avalonia.Controls;
using Avalonia.Interactivity;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Views;

/// <summary>Import Preview for one storage location in its own window, as on the Mac.</summary>
public sealed partial class ImportPreviewWindow : Window
{
    public ImportPreviewWindow()
    {
        InitializeComponent();
        TitleBar.Extend(this, Root, top => PreviewContent.Margin = new Avalonia.Thickness(0, top, 0, 0));
    }

    internal ImportPreviewWindow(ImportPreviewModel model) : this()
    {
        DataContext = model;
        model.Confirmed += Close;
        Opened += async (_, _) => await model.AnalyzeAsync();
    }

    private ImportPreviewModel? Model => DataContext as ImportPreviewModel;

    private async void Analyze(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.AnalyzeAsync();
    }

    private async void Assign(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.AssignAsync();
    }

    private async void UseAutomatic(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.UseAutomaticAsync();
    }

    private async void ConfirmImport(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.ConfirmAsync();
    }

    private void CloseWindow(object? sender, RoutedEventArgs e) => Close();
}
