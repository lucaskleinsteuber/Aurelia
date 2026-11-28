using Tarven.Contracts;
using Tarven.Linux.Core.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using static Tarven.Linux.Management.AdminScope;
using static Tarven.Linux.Settings.SettingsRows;

namespace Tarven.Linux.Management;

/// <summary>Server settings › File Watch for the owner, refreshed every five seconds while shown.</summary>
public static class ServerFileWatchSection
{
    private const string Description =
        "The server reads every file in the background, only while nobody watches, and tells you in Library Health when one is damaged, can't be read or changed by itself. Files are only read, never changed.";

    public static async Task<Control> BuildAsync(AdminScope scope)
    {
        var problem = Message();
        FileCheckSettingsResponse? settings = null;
        await scope.RunAsync(async () => settings = await scope.Client.FileChecksAsync(), problem);
        if (settings is null) return Section("File Watch", Block(problem));
        var panel = Block();
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Height = 6, MinWidth = 260 };
        var status = Note("");
        var current = Note("");
        var depthDetail = Note("");
        // A switch like every other setting that turns something on (audit Linux D2).
        var enabled = new ToggleSwitch { OnContent = "", OffContent = "" };
        ToolTip.SetTip(enabled, "Off until you turn it on. The first round reads the whole library once.");
        var updating = false;
        void Render(FileCheckSettingsResponse value)
        {
            settings = value;
            updating = true;
            enabled.IsChecked = value.Enabled;
            updating = false;
            bar.Value = FileWatchText.Progress(value);
            bar.IsVisible = value.Enabled && value.TotalCount > 0;
            status.Text = FileWatchText.Status(value);
            // While it is off the switch says so; a lone "Off" below would only repeat it.
            status.IsVisible = value.Enabled;
            current.Text = FileWatchText.Current(value);
            current.IsVisible = current.Text.Length > 0;
            depthDetail.Text = FileWatchText.DepthDetail(value.Depth)
                + (value.CanInspect ? "" : " This server has no FFmpeg, so it can only read every byte.");
        }
        async Task Change(UpdateFileCheckSettingsRequest request)
        {
            FileCheckSettingsResponse? saved = null;
            if (await scope.RunAsync(async () => saved = await scope.Client.SaveFileChecksAsync(request), problem) && saved is not null) Render(saved);
        }
        enabled.IsCheckedChanged += (_, _) => { if (!updating) _ = Change(new UpdateFileCheckSettingsRequest(enabled.IsChecked == true)); };
        var depths = settings.CanInspect ? FileWatchText.Depths : [.. FileWatchText.Depths.Where(depth => depth.Value == FileCheckDepth.Read)];
        var depth = Choice("How Thoroughly", null, depths, settings.Depth,
            value => _ = Change(new UpdateFileCheckSettingsRequest(settings?.Enabled ?? false, Depth: value)));
        var rhythm = Choice("Read Again", "Reads every file again in this rhythm and compares it with the first time, to find bit rot.",
            FileWatchText.Rhythms, settings.RecheckDays,
            value => _ = Change(new UpdateFileCheckSettingsRequest(settings?.Enabled ?? false, RecheckDays: value)));
        panel.Children.Add(Note(Description));
        panel.Children.Add(Row("Watch Files", "Off until you turn it on. The first round reads the whole library once.", enabled));
        panel.Children.Add(depth);
        panel.Children.Add(depthDetail);
        panel.Children.Add(rhythm);
        panel.Children.Add(bar);
        panel.Children.Add(status);
        panel.Children.Add(current);
        panel.Children.Add(problem);
        Render(settings);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        timer.Tick += async (_, _) =>
        {
            try { Render(await Core.Api.TarvenApi.InBackgroundAsync(() => scope.Client.FileChecksAsync())); }
            catch (Core.Api.TarvenApiException) { }
        };
        var section = Section("File Watch", panel);
        section.AttachedToVisualTree += (_, _) => timer.Start();
        section.DetachedFromVisualTree += (_, _) => timer.Stop();
        return section;
    }
}

/// <summary>Library Health's File Problems and Drives, drawn into the sheet's content.</summary>
internal static class FileWatchHealth
{
    public static Control ProblemRow(AdminScope scope, FileProblemSummary problem, bool setAside, TextBlock message, Func<Task> reload)
    {
        var again = Button("Examine Again", async () =>
        {
            if (await scope.RunAsync(() => scope.Client.RecheckFileAsync(problem.MediaId), message))
            {
                message.Text = "The file is examined again in the background.";
                await reload();
            }
        });
        ToolTip.SetTip(again, "Reads the file again from the start and keeps it as the new reference.");
        AutomationProperties.SetName(again, "Examine " + problem.Title + " again");
        var aside = Button(setAside ? "Bring Back" : "Set Aside", async () =>
        {
            if (await scope.RunAsync(() => scope.Client.SetFileProblemIgnoredAsync(problem.MediaId, !setAside), message)) await reload();
        });
        ToolTip.SetTip(aside, setAside ? "Shows the problem with the open ones again." : "Keeps the problem out of the count, for a file you know about.");
        var details = new StackPanel
        {
            Spacing = 2,
            Children =
            {
                new TextBlock { Text = $"{problem.Title} · {FileWatchText.ProblemTitle(problem.State)}", FontWeight = FontWeight.SemiBold },
                Note(problem.FileName),
            },
        };
        if (problem.Detail is { } detail) details.Children.Add(new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap, FontSize = 12 });
        if (FileWatchText.Facts(problem) is { Length: > 0 } facts) details.Children.Add(Note(facts));
        return new Border
        {
            Classes = { "card" },
            Padding = new Thickness(12),
            Child = new DockPanel
            {
                Children =
                {
                    new StackPanel { Spacing = 6, Children = { again, aside } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                    details,
                },
            },
        };
    }

    public static Control DriveRow(DriveHealthSummary drive)
    {
        var details = new StackPanel
        {
            Spacing = 2,
            Children =
            {
                new TextBlock { Text = $"{drive.Name} · {FileWatchText.DriveTitle(drive.State)}", FontWeight = FontWeight.SemiBold },
                Note(string.Join(", ", drive.Libraries)),
            },
        };
        if (drive.Detail is { } detail)
        {
            var text = new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap, FontSize = 12 };
            if (drive.State == DriveHealthState.Failing) text.Classes.Add("error");
            details.Children.Add(text);
        }
        if (FileWatchText.DriveFacts(drive) is { Length: > 0 } facts) details.Children.Add(Note(facts));
        return new Border { Classes = { "card" }, Padding = new Thickness(12), Child = details };
    }

    public static Control ShowChoice(bool setAside, Func<bool, Task> changed)
    {
        var open = new Avalonia.Controls.Primitives.ToggleButton { Content = "Open Problems", Classes = { "chip" }, IsChecked = !setAside };
        var aside = new Avalonia.Controls.Primitives.ToggleButton { Content = "Set Aside", Classes = { "chip" }, IsChecked = setAside };
        open.Click += async (_, _) => await changed(false);
        aside.Click += async (_, _) => await changed(true);
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { open, aside } };
    }
}
