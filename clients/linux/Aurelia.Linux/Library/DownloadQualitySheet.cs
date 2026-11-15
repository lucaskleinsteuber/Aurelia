using Aurelia.Contracts;
using Aurelia.Linux.Core.Playback;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Library;

/// <summary>Download › the original or a smaller copy the server converts ("converted-downloads-v1").</summary>
public sealed class DownloadQualitySheet : UserControl
{
    private readonly CheckBox remember = new() { Content = "Use This Quality from Now On" };

    public DownloadQualitySheet(string title, DownloadOptionsResponse options, SheetHost sheets)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(sheets);
        var choices = new StackPanel { Spacing = 8 };
        RadioButton Choice(string label, string detail, string? quality, bool selected)
        {
            var button = new RadioButton
            {
                GroupName = "download-quality",
                IsChecked = selected,
                Content = new StackPanel
                {
                    Children =
                    {
                        new TextBlock { Text = label, FontWeight = FontWeight.SemiBold },
                        new TextBlock { Text = detail, FontSize = 12, Classes = { "subdued" } },
                    },
                },
            };
            button.IsCheckedChanged += (_, _) => { if (button.IsChecked == true) Quality = quality; };
            choices.Children.Add(button);
            return button;
        }
        var preferred = options.Qualities.FirstOrDefault(quality => quality.Id == "720p") ?? (options.Qualities.Count > 0 ? options.Qualities[0] : null);
        Quality = preferred?.Id;
        Choice("Original", $"{ConvertedDownloads.Size(options.OriginalBytes)} · the file as it is on the server", null, preferred is null);
        foreach (var quality in options.Qualities) Choice(quality.Id, ConvertedDownloads.Detail(quality), quality.Id, quality == preferred);
        var download = new Button { Content = "Download", Classes = { "primary" }, IsDefault = true };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        download.Click += (_, _) => sheets.Close(true);
        cancel.Click += (_, _) => sheets.Close(false);
        Content = new StackPanel
        {
            Spacing = 14,
            Width = 460,
            Children =
            {
                new TextBlock { Text = $"Download {title}", FontSize = 18, FontWeight = FontWeight.Bold, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = "Choose how large the copy on this computer should be.", Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap },
                choices,
                remember,
                new TextBlock
                {
                    Text = "A smaller copy is converted by the server while it downloads, with stereo sound; subtitles drawn as pictures are left out. Only this computer keeps it.",
                    FontSize = 12, Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap,
                },
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, download } },
            },
        };
    }

    /// <summary>The chosen quality; null keeps the original.</summary>
    public string? Quality { get; private set; }

    public bool Remember => remember.IsChecked == true;
}
