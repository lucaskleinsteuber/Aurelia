using System.Globalization;
using Avalonia.Data.Converters;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Design;

/// <summary>How far a title has been watched, 0 to 1; 0 when it was not started or is finished.</summary>
public sealed class ProgressFractionConverter : IValueConverter
{
    public static readonly ProgressFractionConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is PlaybackProgressResponse { IsCompleted: false, DurationMilliseconds: > 0 } progress
            ? Math.Clamp((double)progress.PositionMilliseconds / progress.DurationMilliseconds, 0, 1)
            : 0d;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>True when a title is partly watched, to show its progress bar.</summary>
public sealed class InProgressConverter : IValueConverter
{
    public static readonly InProgressConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is PlaybackProgressResponse { IsCompleted: false, PositionMilliseconds: > 0, DurationMilliseconds: > 0 };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>The small line under a card: the year, or "Show · S2 E4" for an episode.</summary>
public sealed class CardCaptionConverter : IValueConverter
{
    public static readonly CardCaptionConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        CatalogItemSummary { Kind: MediaKind.Episode } episode =>
            string.Join(" · ", new[] { episode.ParentTitle, LibraryModel.EpisodeLabel(episode) }.Where(part => !string.IsNullOrEmpty(part))),
        CatalogItemSummary { Kind: MediaKind.Series } => "TV Show",
        CatalogItemSummary item => item.Year?.ToString(CultureInfo.InvariantCulture) ?? "",
        _ => "",
    };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>"Episode 4" style label from an episode presentation.</summary>
public sealed class EpisodeNumberConverter : IValueConverter
{
    public static readonly EpisodeNumberConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is EpisodePresentation episode ? $"Episode {episode.EpisodeNumber}" : "";

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>"Season 2", or "Specials" for season 0.</summary>
public sealed class SeasonNameConverter : IValueConverter
{
    public static readonly SeasonNameConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is SeasonPresentation season ? (season.Number == 0 ? "Specials" : $"Season {season.Number}") : "";

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Picks the backdrop of a detail page: its own, else the poster.</summary>
public sealed class HeroArtworkConverter : IValueConverter
{
    public static readonly HeroArtworkConverter Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        CatalogDetailPresentation detail => detail.Metadata.Backdrop ?? detail.Item.Backdrop ?? detail.Metadata.Still ?? detail.Metadata.Poster,
        CatalogItemSummary item => item.Backdrop ?? item.Poster,
        _ => null,
    };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Home shelves use poster cards, except Continue Watching with its landscape cards.</summary>
public sealed class CardTemplateConverter : IValueConverter
{
    public Avalonia.Controls.Templates.IDataTemplate? Poster { get; set; }
    public Avalonia.Controls.Templates.IDataTemplate? Landscape { get; set; }

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is true ? Landscape : Poster;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}
