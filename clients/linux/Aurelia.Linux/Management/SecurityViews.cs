using Aurelia.Contracts;
using Aurelia.Linux.Core.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>
/// Settings › Profiles and Devices › Security for the owner, as on the Mac: signed-in devices with
/// "New", Block and the block list, how long the log is kept, and the security log. Face ID and
/// Touch ID are set up in the iPhone, iPad and Mac apps, where the keys are.
/// </summary>
public sealed class SecuritySection : StackPanel
{
    private readonly AdminScope scope;
    private readonly TextBlock message = Message();
    private readonly StackPanel settings = new() { Spacing = 0 };
    private readonly StackPanel devices = new() { Spacing = 8 };
    private readonly StackPanel blocked = new() { Spacing = 8 };

    public SecuritySection(AdminScope scope)
    {
        this.scope = scope;
        Spacing = 0;
        Children.Add(Section("Security",
            Block(Note("Who signed in when and from which device, failed attempts and changes. Face ID and Touch ID are set up in the iPhone, iPad and Mac apps."),
                message),
            settings,
            Block(new TextBlock { Text = "Signed-In Devices", FontWeight = FontWeight.SemiBold }, devices, blocked,
                Button("Show Security Log…", ShowLogAsync))));
        Loading = ReloadAsync();
    }

    internal Task Loading { get; private set; }

    private ManagementClient Client => scope.Client;

    public async Task ReloadAsync()
    {
        SecuritySettingsResponse? current = null;
        IReadOnlyList<SecurityDeviceSummary> deviceList = [];
        IReadOnlyList<BlockedDeviceSummary> blockedList = [];
        await scope.RunAsync(async () =>
        {
            current = await Client.SecuritySettingsAsync();
            deviceList = await Client.SecurityDevicesAsync();
            blockedList = await Client.BlockedDevicesAsync();
        }, message);
        FillSettings(current);
        FillDevices(deviceList);
        FillBlocked(blockedList);
    }

    private void FillSettings(SecuritySettingsResponse? current)
    {
        settings.Children.Clear();
        if (current is null) return;
        settings.Children.Add(Value("Face ID or Touch ID for Administrators", current.RequirePasskeysForAdministrators ? "Required" : "Optional"));
        settings.Children.Add(Padded(Note("Changed in the iPhone, iPad or Mac app, where the keys are. When required, this computer asks one of them to confirm. On the server computer itself the Server Password always works.")));
        IReadOnlyList<(int Value, string Label)> days = [(30, "30 days"), (60, "60 days"), (90, "90 days"), (180, "180 days"), (365, "365 days")];
        settings.Children.Add(Choice("Keep the Log", null, days, current.SecurityLogDays, value =>
            _ = scope.RunAsync(async () =>
            {
                await Client.SaveSecuritySettingsAsync(new UpdateSecuritySettingsRequest(value, current.RequirePasskeysForAdministrators));
                await ReloadAsync();
            }, message)));
    }

    private void FillDevices(IReadOnlyList<SecurityDeviceSummary> list)
    {
        devices.Children.Clear();
        foreach (var device in list)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            if (device.IsNew)
                actions.Children.Add(Button("That Was Me", () => RunAndReloadAsync(() => Client.AcknowledgeDeviceAsync(device.Id))).Also(b =>
                    AutomationProperties.SetName(b, "That Was Me " + device.DeviceName)));
            if (device.CanBlock)
                actions.Children.Add(Button("Block…", () => BlockAsync(device.Id, device.DeviceName), "destructive").Also(b =>
                    AutomationProperties.SetName(b, "Block " + device.DeviceName)));
            var title = device.DeviceName + (device.IsCurrent ? " (This Computer)" : "") + (device.IsNew ? " · New" : "");
            var detail = string.Join(" · ", new[] { device.UserName, SecurityText.DeviceLine(device.Platform, device.IpAddress), "last used " + Date(device.LastSeenAt) }
                .Where(part => part.Length > 0));
            devices.Children.Add(Card(title, detail, actions, device.IsNew));
        }
        if (devices.Children.Count == 0) devices.Children.Add(Note("No devices are signed in."));
    }

    private void FillBlocked(IReadOnlyList<BlockedDeviceSummary> list)
    {
        blocked.Children.Clear();
        if (list.Count == 0) return;
        blocked.Children.Add(new TextBlock { Text = "Blocked Devices", FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 8, 0, 0) });
        foreach (var device in list)
        {
            var detail = string.Join(" · ", new[] { SecurityText.DeviceLine(device.Platform, device.IpAddress), "blocked " + Date(device.BlockedAt) }
                .Where(part => part.Length > 0));
            blocked.Children.Add(Card(device.DeviceName, detail,
                Button("Unblock", () => RunAndReloadAsync(() => Client.UnblockDeviceAsync(device.Id))).Also(b =>
                    AutomationProperties.SetName(b, "Unblock " + device.DeviceName)), highlighted: false));
        }
    }

    private async Task BlockAsync(Guid id, string name)
    {
        if (!await scope.Sheets.ConfirmAsync($"Block “{name}”?",
            "It is signed out at once and can’t sign in or pair again until you unblock it.", "Block", destructive: true)) return;
        await RunAndReloadAsync(() => Client.BlockDeviceAsync(id));
    }

    private async Task RunAndReloadAsync(Func<Task> action)
    {
        if (await scope.RunAsync(action, message)) await ReloadAsync();
    }

    private async Task ShowLogAsync()
    {
        var list = new StackPanel { Spacing = 6 };
        var problem = Message();
        DateTimeOffset? before = null;
        var filter = "all";
        var more = new Button { Content = "Load More", Classes = { "chip" }, IsVisible = false };
        async Task LoadAsync(bool append)
        {
            SecurityEventPage? page = null;
            if (!await scope.RunAsync(async () => page = await Client.SecurityEventsAsync(filter, append ? before : null), problem) || page is null) return;
            if (!append) list.Children.Clear();
            foreach (var entry in page.Events)
            {
                var title = SecurityText.Kind(entry.Kind) + (string.IsNullOrEmpty(entry.Detail) ? "" : " · " + entry.Detail);
                var detail = string.Join(" · ", new[] { entry.UserName, entry.DeviceName, SecurityText.DeviceLine(entry.Platform, entry.IpAddress), Date(entry.At) }
                    .Where(part => !string.IsNullOrEmpty(part)));
                list.Children.Add(new StackPanel
                {
                    Spacing = 2,
                    Margin = new Thickness(0, 4),
                    Children =
                    {
                        new TextBlock
                        {
                            Text = title,
                            FontWeight = FontWeight.SemiBold,
                            TextWrapping = TextWrapping.Wrap,
                            Foreground = entry.Outcome == "failed" ? new SolidColorBrush(Color.Parse("#FFB36B")) : null,
                        },
                        Note(detail),
                    },
                });
            }
            if (list.Children.Count == 0) list.Children.Add(Note("Nothing recorded yet."));
            before = page.Before;
            more.IsVisible = before is not null;
        }
        more.Click += async (_, _) => await LoadAsync(append: true);
        var filters = new ComboBox { ItemsSource = SecurityText.Filters.Select(f => f.Label).ToList(), SelectedIndex = 0, MinWidth = 160 };
        AutomationProperties.SetName(filters, "Show");
        filters.SelectionChanged += async (_, _) =>
        {
            filter = SecurityText.Filters[Math.Max(0, filters.SelectedIndex)].Value;
            await LoadAsync(append: false);
        };
        var done = new Button { Content = "Done", Classes = { "primary" }, IsDefault = true, IsCancel = true };
        done.Click += (_, _) => scope.Sheets.Close(true);
        var shown = scope.Sheets.ShowAsync(new StackPanel
        {
            Spacing = 12,
            Width = 640,
            Children =
            {
                new DockPanel
                {
                    Children =
                    {
                        filters.Also(f => DockPanel.SetDock(f, Dock.Right)),
                        new TextBlock { Text = "Security Log", FontSize = 18, FontWeight = FontWeight.Bold, VerticalAlignment = VerticalAlignment.Center },
                    },
                },
                problem,
                new ScrollViewer { MaxHeight = 460, Content = list },
                more,
                new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { done } },
            },
        });
        await LoadAsync(append: false);
        await shown;
    }

    private static Border Card(string title, string detail, Control actions, bool highlighted) => new()
    {
        Classes = { "card" },
        Padding = new Thickness(12),
        BorderThickness = new Thickness(highlighted ? 1 : 0),
        BorderBrush = highlighted ? new SolidColorBrush(Color.Parse("#FFB547")) : null,
        Child = new DockPanel
        {
            Children =
            {
                actions.Also(a => DockPanel.SetDock(a, Dock.Right)),
                new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap },
                        Note(detail),
                    },
                },
            },
        },
    };
}

/// <summary>
/// The owner's notes at the top of the window while a profile is open: a device signed in for the
/// first time, with "That Was Me" and "Block…". Long-polls the server, so a sign-in shows within
/// seconds. Runs on the UI thread; stops when disposed or when the server refuses the read.
/// </summary>
public sealed class SecurityAlertWatcher : IDisposable
{
    private readonly AdminScope scope;
    private readonly Panel host;
    private readonly CancellationTokenSource stop = new();
    private readonly HashSet<Guid> answered = [];
    private IReadOnlyList<SecurityDeviceSummary> shown = [];

    public SecurityAlertWatcher(AdminScope scope, Panel host)
    {
        this.scope = scope;
        this.host = host;
        Running = RunAsync(stop.Token);
    }

    internal Task Running { get; }

    private async Task RunAsync(CancellationToken cancellation)
    {
        long version = 0;
        var failures = 0;
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                var alerts = await scope.Client.SecurityAlertsAsync(version, version == 0 ? 0 : 25, cancellation);
                version = alerts.Version;
                shown = alerts.NewDevices;
                Render();
                failures = 0;
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Aurelia.Linux.Core.Api.AureliaApiException error) when (error.Status is 401 or 403 or 404)
            {
                return;
            }
            catch (Exception failure) when (failure is Aurelia.Linux.Core.Api.AureliaApiException or HttpRequestException)
            {
                failures++;
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(Math.Min(60, 5 * failures)), cancellation);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }

    private void Render()
    {
        host.Children.Clear();
        foreach (var device in shown.Where(device => !answered.Contains(device.Id)).Take(3))
        {
            var block = new Button { Content = "Block…", Classes = { "destructive" } };
            var mine = new Button { Content = "That Was Me", Classes = { "primary" } };
            AutomationProperties.SetName(mine, "That Was Me " + device.DeviceName);
            AutomationProperties.SetName(block, "Block " + device.DeviceName);
            mine.Click += async (_, _) => await AnswerAsync(device, () => scope.Client.AcknowledgeDeviceAsync(device.Id));
            block.Click += async (_, _) =>
            {
                if (await scope.Sheets.ConfirmAsync($"Block “{device.DeviceName}”?",
                    "It is signed out at once and can’t sign in or pair again until you unblock it.", "Block", destructive: true))
                    await AnswerAsync(device, () => scope.Client.BlockDeviceAsync(device.Id));
            };
            host.Children.Add(new Border
            {
                Classes = { "banner" },
                Child = new StackPanel
                {
                    Spacing = 10,
                    Children =
                    {
                        new TextBlock { Text = SecurityText.NewDevice(device.DeviceName, device.Platform, device.IpAddress), FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap },
                        Note($"{device.UserName} · {Date(device.CreatedAt)}"),
                        new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { block, mine } },
                    },
                },
            });
        }
    }

    private async Task AnswerAsync(SecurityDeviceSummary device, Func<Task> action)
    {
        answered.Add(device.Id);
        Render();
        await scope.RunAsync(action);
    }

    public void Dispose()
    {
        stop.Cancel();
        stop.Dispose();
        host.Children.Clear();
    }
}
