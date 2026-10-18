using Avalonia.Controls;
using Avalonia.Interactivity;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Views;

/// <summary>The library for the open profile: sidebar sections, shelves, grids, search and detail pages.</summary>
public sealed partial class LibraryView : UserControl
{
    public LibraryView()
    {
        InitializeComponent();
        VersionLabel.Text = AppInfo.VersionLabel;
    }

    /// <summary>Raised when the person chooses Switch Profile in the sidebar.</summary>
    public event Action? SwitchProfileRequested;

    private LibraryModel? Model => DataContext as LibraryModel;

    public void ShowProfile(string name) => ProfileName.Text = name;

    private async void SectionChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (Model is not { } model) return;
        var section = Navigation.SelectedIndex switch
        {
            1 => LibrarySection.Movies,
            2 => LibrarySection.Shows,
            3 => LibrarySection.Search,
            _ => LibrarySection.Home,
        };
        await model.ShowAsync(section);
        if (section == LibrarySection.Search) SearchBox.Focus();
    }

    private async void OpenItem(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model && (sender as Control)?.DataContext is CatalogItemSummary item) await model.OpenAsync(item);
    }

    private async void PlayHero(object? sender, RoutedEventArgs e)
    {
        if (Model is { Hero: { } hero } model) await model.PlayAsync(hero.Id);
    }

    private async void OpenHero(object? sender, RoutedEventArgs e)
    {
        if (Model is not { Hero: { } hero } model) return;
        // An episode's page is its series.
        await model.OpenDetailAsync(hero.Kind == MediaKind.Episode && hero.ParentId is { } series ? series : hero.Id);
    }

    private void CloseDetail(object? sender, RoutedEventArgs e) => Model?.CloseDetail();

    private async void PlayDetail(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.PlayDetailAsync();
    }

    private async void PlayEpisode(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model && (sender as Control)?.DataContext is EpisodePresentation episode) await model.PlayAsync(episode.Item.Id);
    }

    private async void PlaySupplement(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model && (sender as Control)?.DataContext is SupplementPresentation extra) await model.PlayAsync(extra.Item.Id);
    }

    private async void ToggleFavorite(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.ToggleFavoriteAsync();
    }

    private void SwitchProfile(object? sender, RoutedEventArgs e) => SwitchProfileRequested?.Invoke();

    private async void Retry(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.ShowAsync(model.Section);
    }

    /// <summary>Loads more posters when the grid nears its end.</summary>
    private async void GridScrolled(object? sender, ScrollChangedEventArgs e)
    {
        if (Model is not { } model || sender is not ScrollViewer scroll) return;
        if (scroll.Offset.Y + scroll.Viewport.Height < scroll.Extent.Height - 800) return;
        await model.LoadMoreAsync(scroll == MoviesScroll ? MediaKind.Movie : MediaKind.Series);
    }
}
