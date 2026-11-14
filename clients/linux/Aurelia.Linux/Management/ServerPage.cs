using System.Globalization;
using System.Text.Json.Nodes;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>
/// The owner's Server settings, as the Mac app's ServerManagementView: a summary and health,
/// updates and power saving for a Linux package server, devices and backups, scrub previews, and
/// the advanced settings (details, network, limits, library maintenance, backups, diagnostics).
/// </summary>
public sealed class ServerPage : StackPanel
{
    private static readonly int[] IdleChoices = [10, 15, 20, 30, 45, 60, 90, 120, 180];
    private static readonly int[] IntervalChoices = [10, 15, 20, 30, 60];
    private static readonly int[] CapChoices = [100, 250, 500, 1_000, 2_000, 5_000];

    private readonly AdminScope scope;
    private readonly TextBlock message = Message();
    private ServerStatusResponse? status;
    private ServerHealthResponse? health;
    private ServerManagementCapabilities? capabilities;
    private JsonObject? configuration;
    private bool showsAdvanced;

    private readonly Control? localHosting;

    private readonly bool powerOnly;

    /// <param name="localHosting">When this computer hosts the server: when it runs, set here.</param>
    /// <param name="powerOnly">Settings › Power: only when the server runs and what it does when unused.</param>
    public ServerPage(AdminScope scope, Control? localHosting = null, bool powerOnly = false)
    {
        this.scope = scope;
        this.localHosting = localHosting;
        this.powerOnly = powerOnly;
        Spacing = 22;
        Children.Add(new TextBlock { Text = "Loading server settings…", Classes = { "subdued" } });
        _ = ReloadAsync();
    }

    internal Task Loading { get; private set; } = Task.CompletedTask;

    private ManagementClient Client => scope.Client;

    private JsonObject Stored => (JsonObject)configuration!["stored"]!;

    private JsonObject Active => (JsonObject)configuration!["active"]!;

    private ServerHosting Hosting => ServerHostingKind.From(capabilities);

    public Task ReloadAsync() => Loading = LoadAsync();

    private async Task LoadAsync()
    {
        var loaded = await scope.RunAsync(async () =>
        {
            var statusTask = Client.StatusAsync();
            var healthTask = Client.HealthAsync();
            var capabilitiesTask = Client.CapabilitiesAsync();
            var settingsTask = Client.SettingsAsync();
            await Task.WhenAll(statusTask, healthTask, capabilitiesTask, settingsTask);
            (status, health, capabilities, configuration) = (statusTask.Result, healthTask.Result, capabilitiesTask.Result, settingsTask.Result);
        }, message);
        Children.Clear();
        Children.Add(message);
        if (!loaded && status is null) return;
        if (powerOnly)
        {
            if (localHosting is not null) Children.Add(localHosting);
            else if (Hosting is ServerHosting.MacApp or ServerHosting.DesktopApp)
                Children.Add(Section("When the Server Runs", Block(Note("This server runs in Aurelia on another computer. Whether it keeps running when Aurelia is closed is chosen in Aurelia on that computer."))));
            if (await PowerAsync() is { } unused) Children.Add(unused);
            else if (localHosting is null)
                Children.Add(Section("When Nobody Uses Aurelia", Block(Note("This server can't save power from Aurelia: it follows its computer's own energy settings."))));
            return;
        }
        Children.Add(Summary());
        Children.Add(Health());
        if (await PerformanceAsync() is { } performance) Children.Add(performance);
        if (Hosting == ServerHosting.LinuxPackage) Children.Add(await UpdatesAsync());
        Children.Add(await EssentialsAsync());
        Children.Add(await ScrubPreviewsAsync());
        if (scope.IsOwner && Client.Library.Supports(ServerFeatures.MediaSegments)) Children.Add(await ServerSegmentsSection.BuildAsync(scope));
        if (scope.IsOwner && Client.Library.Supports(ServerFeatures.ServerSpeech)) Children.Add(await ServerSpeechSection.BuildAsync(scope));
        if (await VideoConversionAsync() is { } conversion) Children.Add(conversion);
        if (scope.IsOwner && Client.Library.Supports(ServerFeatures.Automation)) Children.Add(new AutomationSection(scope));
        var advanced = new Expander { Header = "Advanced Settings", IsExpanded = showsAdvanced, HorizontalAlignment = HorizontalAlignment.Stretch };
        var advancedContent = new StackPanel { Spacing = 22, Margin = new Thickness(0, 12, 0, 0) };
        advanced.Content = advancedContent;
        advanced.Expanding += async (_, _) =>
        {
            showsAdvanced = true;
            if (advancedContent.Children.Count == 0) await FillAdvancedAsync(advancedContent);
        };
        advanced.Collapsing += (_, _) => showsAdvanced = false;
        if (showsAdvanced) await FillAdvancedAsync(advancedContent);
        Children.Add(advanced);
    }

    private async Task FillAdvancedAsync(StackPanel content)
    {
        content.Children.Add(Details());
        content.Children.Add(Network());
        content.Children.Add(Limits());
        content.Children.Add(await MaintenanceAsync());
        content.Children.Add(await BackupsAsync());
        content.Children.Add(await DiagnosticsAsync());
    }

    private Border Summary()
    {
        var current = status!;
        var state = current.Readiness?.State ?? current.State;
        var healthy = state.ToLowerInvariant() is "ready" or "running";
        var name = Active["serverName"]?.GetValue<string>() ?? scope.ServerName;
        var lan = Active["lanAccessEnabled"]?.GetValue<bool>() == true;
        var stack = new StackPanel { Spacing = 14 };
        stack.Children.Add(new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 6,
                    VerticalAlignment = VerticalAlignment.Top,
                    Children =
                    {
                        new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Color.Parse(healthy ? "#4CD964" : "#FF9F0A")), VerticalAlignment = VerticalAlignment.Center },
                        new TextBlock { Text = Capitalize(state), FontWeight = FontWeight.SemiBold },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                new StackPanel
                {
                    Spacing = 4,
                    Children =
                    {
                        new TextBlock { Text = "Your Server", FontSize = 18, FontWeight = FontWeight.Bold },
                        new TextBlock { Text = string.Join(" · ", new[] { name, ServerHostingKind.Location(Hosting) }.Where(part => part is not null)), Classes = { "subdued" } },
                    },
                },
            },
        });
        foreach (var component in current.Readiness?.Components.Where(c => c.State != "ready") ?? [])
        {
            stack.Children.Add(new TextBlock { Text = "⚠ " + (component.Reason ?? Capitalize(component.Id) + " is " + component.State + "."), Foreground = new SolidColorBrush(Color.Parse("#FF9F0A")), TextWrapping = TextWrapping.Wrap });
        }
        stack.Children.Add(new TextBlock
        {
            Text = lan ? "Devices on your home network can connect." : "Only the server computer itself can connect.",
            Classes = { "subdued" },
        });
        var facts = new UniformGrid { Columns = 4 };
        facts.Children.Add(Fact("Profiles", current.Users.ToString(CultureInfo.InvariantCulture)));
        facts.Children.Add(Fact("Libraries", current.Libraries.ToString(CultureInfo.InvariantCulture)));
        facts.Children.Add(Fact("Free Space", current.FreeDiskBytes is { } free ? Bytes(free) : "—"));
        facts.Children.Add(Fact("Playing Now", current.ActiveStreams.ToString(CultureInfo.InvariantCulture)));
        stack.Children.Add(facts);
        if (current.FreeDiskBytes is < 1024L * 1024 * 1024)
        {
            stack.Children.Add(new TextBlock { Text = "⚠ The server's disk is almost full. Backups and library updates may fail.", Foreground = new SolidColorBrush(Color.Parse("#FF9F0A")), TextWrapping = TextWrapping.Wrap });
        }
        var restartMessage = new TextBlock { Classes = { "subdued" }, FontSize = 12, IsVisible = false, TextWrapping = TextWrapping.Wrap };
        var canRestart = capabilities?.NativeHostOperations == true || Hosting == ServerHosting.LinuxPackage;
        var restart = Button("Restart Server", async () =>
        {
            if (!await scope.Sheets.ConfirmAsync("Restart the server?", "Playback on every device stops for a moment. Aurelia reconnects by itself.", "Restart Server", destructive: false)) return;
            if (await scope.RunAsync(() => Client.RestartAsync(), restartMessage))
            {
                restartMessage.Text = Hosting == ServerHosting.LinuxPackage
                    ? "Restarting. Aurelia reconnects by itself in a few seconds."
                    : "Restart requested. Reconnect after the server has restarted.";
                restartMessage.IsVisible = true;
            }
        });
        restart.IsEnabled = canRestart;
        AutomationProperties.SetName(restart, "Restart Server");
        stack.Children.Add(new DockPanel
        {
            Children =
            {
                Buttons(Button("Refresh", ReloadAsync), restart).Also(p => DockPanel.SetDock(p, Dock.Right)),
                new TextBlock { Text = $"Version {current.Version} · Running for {Duration(current.UptimeSeconds)}", Classes = { "subdued" }, FontSize = 12, VerticalAlignment = VerticalAlignment.Center },
            },
        });
        stack.Children.Add(restartMessage);
        return new Border { Classes = { "card" }, Padding = new Thickness(18), Child = stack };
    }

    private Border Health()
    {
        var current = health!;
        var jobs = current.BackgroundJobs.ActiveScans + current.BackgroundJobs.ActiveMetadataJobs + current.BackgroundJobs.ActiveScrubPreviewJobs;
        var backup = current.Backup switch
        {
            null => "None",
            { LastAttemptFailed: true } => "Last Failed",
            { TotalBackups: 0, Enabled: var enabled } => enabled ? "Scheduled" : "Disabled",
            var summary => $"{summary.TotalBackups} backups ({Bytes(summary.TotalBackupBytes)})",
        };
        var grid = new UniformGrid { Columns = 4 };
        grid.Children.Add(Fact("Uptime", Duration(current.UptimeSeconds), small: true));
        grid.Children.Add(Fact("Free Disk Space", current.FreeDiskBytes is { } free ? Bytes(free) : "—", small: true));
        grid.Children.Add(Fact("Database", Bytes(current.DatabaseBytes), small: true));
        grid.Children.Add(Fact("Playing / Converting", $"{current.ActiveStreams} / {current.ActiveLiveConversions}", small: true));
        grid.Children.Add(Fact("Scrub Previews", current.ScrubPreviewTitleCount == 0 ? "None" : $"{current.ScrubPreviewTitleCount} titles ({Bytes(current.ScrubPreviewBytes)})", small: true));
        grid.Children.Add(Fact("Last Scan", current.LastScan is { } scan ? $"{Capitalize(scan.State)} (+{scan.AddedFiles}, -{scan.MissingFiles})" : "None", small: true));
        grid.Children.Add(Fact("Database Backups", backup, small: true));
        grid.Children.Add(Fact("Background Jobs", jobs == 0 ? "Idle" : $"{jobs} active", small: true));
        var stack = new StackPanel { Spacing = 14, Children = { new TextBlock { Text = "Server Health", FontSize = 18, FontWeight = FontWeight.Bold }, grid } };
        if (current.OfflineMediaCount > 0)
        {
            stack.Children.Add(Note($"{current.OfflineMediaCount} {(current.OfflineMediaCount == 1 ? "title is" : "titles are")} offline. Their details and progress stay."));
        }
        if (current.RecentIssues.Count > 0)
        {
            var issues = new StackPanel { Spacing = 4, Children = { new TextBlock { Text = "Recent Warnings & Errors", FontWeight = FontWeight.SemiBold, Classes = { "subdued" }, FontSize = 12 } } };
            foreach (var issue in current.RecentIssues.Take(5))
            {
                issues.Children.Add(new DockPanel
                {
                    Children =
                    {
                        new TextBlock { Text = Date(issue.At), Classes = { "subdued" }, FontSize = 11 }.Also(t => DockPanel.SetDock(t, Dock.Right)),
                        new TextBlock { Text = (issue.Severity == "error" ? "⛔ " : "⚠ ") + issue.Code, FontFamily = new FontFamily("monospace"), FontSize = 12 },
                    },
                });
            }
            stack.Children.Add(issues);
        }
        return new Border { Classes = { "card" }, Padding = new Thickness(18), Child = stack };
    }

    private static Border Fact(string title, string value, bool small = false) => new()
    {
        Background = Application.Current?.FindResource("AureliaRaisedSurfaceBrush") as IBrush ?? new SolidColorBrush(Color.Parse("#2A2E33")),
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(12, small ? 8 : 10),
        Margin = new Thickness(0, 0, 10, 10),
        Child = new StackPanel
        {
            Spacing = 3,
            Children =
            {
                new TextBlock { Text = value, FontSize = small ? 14 : 18, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = title, Classes = { "subdued" }, FontSize = 11 },
            },
        },
    };

    private async Task<Control> UpdatesAsync()
    {
        var note = Message();
        ServerUpdateStatus? updates = null;
        await scope.RunAsync(async () => updates = await Client.UpdatesAsync(), note);
        if (updates is not { Available: true })
        {
            return Section("Server Updates", Block(Note("This server cannot update itself from here."), note));
        }
        var state = new TextBlock { Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        var panel = Block();
        void Show(ServerUpdateStatus current)
        {
            state.Text = current.State switch
            {
                "checking" => "Looking for a new version…",
                "installing" => $"Installing {current.Newest ?? "the update"}…",
                "failed" => current.Message ?? "The last update did not work.",
                _ when current.CheckedAt is { } checkedAt => $"Up to date · checked {Date(checkedAt)}",
                _ => "Not checked yet.",
            };
            if (current.State == "idle" && current.UpdateAvailable && current.Newest is { } newest) state.Text = $"Aurelia Server {newest} is available.";
        }
        Show(updates);
        var install = Button("Install Update…", async () =>
        {
            if (!await scope.Sheets.ConfirmAsync($"Install Aurelia Server {updates.Newest}?",
                "The server stops for about a minute while it updates; playback pauses meanwhile. Accounts, library and settings stay.", "Install Update", destructive: false)) return;
            await scope.RunAsync(async () => Show(updates = await Client.InstallUpdateAsync()), note);
        }, "primary");
        install.IsVisible = updates.UpdateAvailable;
        panel.Children.Add(Note("Aurelia Server looks for a new version once a day. Installing waits for you."));
        panel.Children.Add(new StackPanel { Spacing = 2, Children = { Value("Installed", updates.Installed), Value("Available", updates.Newest ?? "—") } });
        panel.Children.Add(state);
        panel.Children.Add(Buttons(Button("Check Now", async () => await scope.RunAsync(async () =>
        {
            Show(updates = await Client.CheckUpdatesAsync());
            install.IsVisible = updates.UpdateAvailable;
        }, note)), install));
        panel.Children.Add(note);
        return Section("Server Updates", panel);
    }

    private async Task<Control?> PowerAsync()
    {
        var note = Message();
        ServerPowerSettings? power = null;
        if (!await scope.RunAsync(async () => power = await Client.PowerAsync(), note) || power is not { Available: true }) return null;
        var mode = power.Mode;
        var idle = power.IdleMinutes;
        string? from = power.AwakeFrom;
        string? until = power.AwakeUntil;
        var wakeOnAccess = power.WakeOnAccess;
        var afterSleepTimer = power.AfterSleepTimer;
        var byApp = HostedByApp(power.Hosting);
        var computer = power.Hosting == "macApp" ? "the Mac" : power.Hosting == "linuxApp" ? "the Linux PC" : "the server computer";
        var panel = Block();
        var checkPanel = Block();
        var checkSection = Section("Wake-on-LAN Check", checkPanel);
        void Build()
        {
            BuildWakeCheck(checkPanel, checkSection, power, mode);
            panel.Children.Clear();
            panel.Children.Add(Note(byApp
                ? $"Aurelia Server runs inside the Aurelia app on {computer}. It can stop when nobody uses it, so the computer may sleep."
                : "What the server computer does while nobody watches, browses or changes anything."));
            panel.Children.Add(Choice("When Unused", null, [.. PowerModes(byApp).Select(value => (value, PowerModeLabel(value, byApp)))], mode,
                value => { mode = value; Build(); }).Also(r => r.Margin = new Thickness(0)));
            panel.Children.Add(Note(PowerExplanation(mode, byApp, computer)));
            if (mode != "off")
            {
                var choices = IdleChoices.Contains(idle) ? IdleChoices : [.. IdleChoices.Append(idle).Order()];
                panel.Children.Add(Choice("After", "Without anyone watching, browsing or changing settings on any device. An app that is only open doesn't count, and nothing happens while a title plays.",
                    [.. choices.Select(m => (m, IdleLabel(m)))], idle, value => idle = value).Also(r => r.Margin = new Thickness(0)));
                panel.Children.Add(Toggle("Also After a Sleep Timer Ends",
                    "When a player's sleep timer ends and nothing plays for five more minutes, it happens right away, at any time of day.",
                    afterSleepTimer, enabled => afterSleepTimer = enabled).Also(r => r.Margin = new Thickness(0)));
                panel.Children.Add(Toggle("Keep Running at Set Hours", null, from is not null, enabled =>
                {
                    from = enabled ? "17:00" : null;
                    until = enabled ? "23:00" : null;
                    Build();
                }).Also(r => r.Margin = new Thickness(0)));
                if (from is not null)
                {
                    var fromBox = new TextBox { Text = from, Width = 90, PlaceholderText = "17:00" };
                    var untilBox = new TextBox { Text = until, Width = 90, PlaceholderText = "23:00" };
                    AutomationProperties.SetName(fromBox, "From");
                    AutomationProperties.SetName(untilBox, "Until");
                    fromBox.TextChanged += (_, _) => from = fromBox.Text;
                    untilBox.TextChanged += (_, _) => until = untilBox.Text;
                    panel.Children.Add(new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 10,
                        Children = { new TextBlock { Text = "From", VerticalAlignment = VerticalAlignment.Center }, fromBox, new TextBlock { Text = "Until", VerticalAlignment = VerticalAlignment.Center }, untilBox },
                    });
                    panel.Children.Add(Note(mode == "stop"
                        ? "Aurelia Server never stops during these hours."
                        : "It never powers down during these hours and wakes itself at their start, so an Apple TV finds it then."));
                }
                if (OffersWakeOnAccess(mode, power.WakeSupport))
                {
                    panel.Children.Add(Toggle("Wake When a Device Connects",
                        "Opening Aurelia in a browser wakes the server too, from a device that reached it within the last minutes. Other devices still use Wake-on-LAN. Stray network traffic can wake it now and then; it powers down again after five unused minutes.",
                        wakeOnAccess, enabled => wakeOnAccess = enabled).Also(r => r.Margin = new Thickness(0)));
                }
            }
            panel.Children.Add(Button("Save Power Settings", async () =>
            {
                if (from is not null && (!IsTime(from) || !IsTime(until) || from == until))
                {
                    note.Text = "Enter two different times such as 17:00 and 23:00.";
                    note.IsVisible = true;
                    return;
                }
                await scope.RunAsync(async () => power = await Client.SavePowerAsync(new UpdateServerPowerSettingsRequest(mode, idle, from, until,
                    !byApp && (power.WakeSupport ?? "").Contains('u', StringComparison.Ordinal) ? wakeOnAccess : null, afterSleepTimer)), note);
            }, "primary"));
            panel.Children.Add(note);
        }
        Build();
        return new StackPanel { Spacing = 22, Children = { Section("When Nobody Uses Aurelia", panel), checkSection } };
    }

    private static void BuildWakeCheck(StackPanel panel, Control section, ServerPowerSettings power, string mode)
    {
        var items = WakeCheckText.Items(power, mode);
        section.IsVisible = items is not null;
        panel.Children.Clear();
        if (items is null) return;
        panel.Children.Add(Note(WakeCheckText.Intro));
        foreach (var item in items)
        {
            var (glyph, label, color) = WakeCheckText.Mark(item.State);
            var mark = new TextBlock { Text = glyph, Width = 18, FontWeight = FontWeight.Bold, Foreground = new SolidColorBrush(Color.Parse(color)) };
            AutomationProperties.SetName(mark, label);
            var text = new StackPanel { Spacing = 2, Children = { new TextBlock { Text = item.Title, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap }, Note(item.Detail) } };
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("24,*") };
            Grid.SetColumn(text, 1);
            row.Children.Add(mark);
            row.Children.Add(text);
            panel.Children.Add(row);
        }
        panel.Children.Add(Note(WakeCheckText.Footer));
    }

    /// <summary>A server the Aurelia app hosts on a Mac or Linux PC only keeps running or stops.</summary>
    internal static bool HostedByApp(string? hosting) => hosting is "macApp" or "linuxApp";

    internal static string[] PowerModes(bool byApp) => byApp ? ["off", "stop"] : ["off", "stop", "sleep", "shutdown"];

    internal static string PowerModeLabel(string mode, bool byApp) => mode switch
    {
        "stop" => byApp ? "Stop Aurelia Server" : "Stop Only Aurelia Server",
        "sleep" => "Put the Computer to Sleep",
        "shutdown" => "Shut Down the Computer",
        _ => "Keep Running",
    };

    internal static string PowerExplanation(string mode, bool byApp, string computer) => (mode, byApp) switch
    {
        ("stop", true) => $"Aurelia Server stops, and {computer} may sleep as usual. Other devices then show “Start Aurelia on {computer}”; opening Aurelia there starts it again. Nothing can wake it over the network.",
        ("stop", false) => "Only Aurelia Server stops; the computer stays on for its other work, such as a NAS. It starts again within seconds when any device connects, a browser too.",
        ("sleep", _) => "The whole computer sleeps: fans and disks stop, and it uses only a few watts. Aurelia on a computer wakes it when you open it, and so can a router such as a FRITZ!Box (Wake-on-LAN); an Apple TV can't, so open Aurelia on a computer first. Waking takes about 10 to 20 seconds. Usually the best choice.",
        ("shutdown", _) => "The computer turns off and uses almost nothing. Aurelia on a computer starts it with Wake-on-LAN, which takes 30 to 60 seconds because the whole computer starts up, and only if its BIOS allows Wake-on-LAN while it is off (see the check below).",
        (_, true) => $"Aurelia Server runs as long as the Aurelia app does. While the computer sleeps or is turned off, other devices show “Start Aurelia on {computer}”.",
        _ => "Aurelia Server and the computer keep running: ready at any moment, using the most power.",
    };

    /// <summary>Waking on a direct connection matters only while the computer sleeps or is off, on a card that can.</summary>
    internal static bool OffersWakeOnAccess(string mode, string? wakeSupport) =>
        mode is "sleep" or "shutdown" && (wakeSupport ?? "").Contains('u', StringComparison.Ordinal);

    internal static bool IsTime(string? text) =>
        text is { Length: 5 } && TimeOnly.TryParseExact(text, "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out _);

    internal static string IdleLabel(int minutes) =>
        minutes < 60 || minutes % 60 != 0 ? $"{minutes} minutes" : minutes == 60 ? "1 hour" : $"{minutes / 60} hours";

    private async Task<Control> EssentialsAsync()
    {
        var note = Message();
        var last = new TextBlock { Classes = { "subdued" }, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        async Task ShowLastAsync()
        {
            IReadOnlyList<ServerBackupSummary> backups = [];
            await scope.RunAsync(async () => backups = await Client.BackupsAsync(), note);
            last.Text = backups.Count == 0 ? "No backup yet." : "Last backup: " + Date(backups[0].CreatedAt);
        }
        await ShowLastAsync();
        return Section("Devices & Backups",
            Toggle("Allow New Devices to Connect", "Turn this off once your TVs, computers and other devices are set up. Devices that are already connected keep working.",
                Stored["pairingEnabled"]?.GetValue<bool>() ?? true, value => _ = SaveAsync(settings => settings["pairingEnabled"] = value, note)),
            Toggle("Back Up Automatically", "Aurelia regularly saves a checked copy of its library database. Your videos are never copied.",
                Stored["automaticBackupsEnabled"]?.GetValue<bool>() ?? true, value => _ = SaveAsync(settings => settings["automaticBackupsEnabled"] = value, note)),
            Block(new DockPanel
            {
                Children =
                {
                    Button("Back Up Now", async () =>
                    {
                        if (await scope.RunAsync(() => Client.BackUpNowAsync(), note))
                        {
                            await ShowLastAsync();
                            note.Text = "Backup created and checked.";
                            note.IsVisible = true;
                        }
                    }).Also(b => DockPanel.SetDock(b, Dock.Right)),
                    last,
                },
            }, note));
    }

    /// <summary>Changes the stored settings and saves them, keeping fields this app does not know.</summary>
    private async Task<bool> SaveAsync(Action<JsonObject> change, TextBlock note, bool reload = false)
    {
        var settings = (JsonObject)Stored.DeepClone();
        change(settings);
        var saved = await scope.RunAsync(async () => configuration = await Client.SaveSettingsAsync(settings), note);
        if (saved && reload) await ReloadAsync();
        return saved;
    }

    /// <summary>How the server converts video; older servers without the status show nothing.</summary>
    /// <summary>Performance: response times per endpoint and slow database queries, measured by the server.</summary>
    private async Task<Control?> PerformanceAsync()
    {
        ServerPerformanceResponse current;
        try { current = await Client.PerformanceAsync(); }
        catch (Exception error) when (error is AureliaApiException or HttpRequestException or TaskCanceledException) { return null; }
        var slow = current.SlowQueries.Count(query => !query.WarmUp);
        var grid = new UniformGrid { Columns = 3 };
        grid.Children.Add(Fact("Requests", current.Requests.ToString("N0", System.Globalization.CultureInfo.InvariantCulture), small: true));
        grid.Children.Add(Fact("95 % Answered Within", PerformanceText.Duration(current.P95Milliseconds), small: true));
        grid.Children.Add(Fact("Slow Queries", slow.ToString(System.Globalization.CultureInfo.InvariantCulture), small: true));
        var panel = Block(Note($"How long the server takes to answer, measured by the server since {Date(current.Since)}. Streams and waiting requests are left out."), grid);
        if (current.Endpoints.Count == 0) panel.Children.Add(Note("Nothing measured yet."));
        else
        {
            var table = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto,Auto,Auto"), ColumnSpacing = 14, RowSpacing = 4 };
            var headers = new[] { "Slowest Endpoints", "Requests", "Median", "95 %", "Queries" };
            for (var column = 0; column < headers.Length; column++)
                table.Children.Add(Cell(headers[column], 0, column, subdued: true));
            var row = 1;
            foreach (var endpoint in current.Endpoints.Take(10))
            {
                table.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
                table.Children.Add(Cell($"{endpoint.Method} {PerformanceText.Route(endpoint.Route)}", row, 0));
                table.Children.Add(Cell(endpoint.Count.ToString(System.Globalization.CultureInfo.InvariantCulture), row, 1));
                table.Children.Add(Cell(PerformanceText.Duration(endpoint.MedianMilliseconds), row, 2));
                table.Children.Add(Cell(PerformanceText.Duration(endpoint.P95Milliseconds), row, 3));
                table.Children.Add(Cell(endpoint.QueriesPerRequest.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture), row, 4));
                row++;
            }
            table.RowDefinitions.Insert(0, new RowDefinition(GridLength.Auto));
            panel.Children.Add(table);
        }
        if (current.SlowQueries.Count > 0)
        {
            var queries = new StackPanel { Spacing = 8 };
            foreach (var query in current.SlowQueries.Take(50))
                queries.Children.Add(new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock { Text = $"{PerformanceText.Duration(query.Milliseconds)} · {query.Kind}{(query.WarmUp ? " · while starting" : "")} · {Date(query.At)}", FontWeight = FontWeight.SemiBold, FontSize = 12 },
                        new TextBlock { Text = query.Endpoint ?? "Background work", Classes = { "subdued" }, FontSize = 11 },
                        new SelectableTextBlock { Text = query.Statement, FontFamily = new FontFamily("monospace"), FontSize = 11, TextWrapping = TextWrapping.Wrap },
                    },
                });
            panel.Children.Add(new Expander { Header = $"Slow Database Queries ({current.SlowQueries.Count}, over {current.SlowQueryMilliseconds} ms)", Content = queries, HorizontalAlignment = HorizontalAlignment.Stretch });
        }
        if (scope.IsOwner)
            panel.Children.Add(Buttons(Button("Reset Measurements", async () =>
            {
                if (await scope.RunAsync(() => Client.ResetPerformanceAsync(), message)) await ReloadAsync();
            })));
        return Section("Performance", panel);

        static TextBlock Cell(string text, int row, int column, bool subdued = false)
        {
            var cell = new TextBlock { Text = text, FontSize = subdued ? 11 : 12, TextTrimming = TextTrimming.CharacterEllipsis };
            if (subdued) cell.Classes.Add("subdued");
            if (column > 0) cell.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetRow(cell, row);
            Grid.SetColumn(cell, column);
            return cell;
        }
    }

    private async Task<Control?> VideoConversionAsync()
    {
        TranscodingStatusResponse status;
        try { status = await Client.TranscodingAsync(); }
        catch (Exception error) when (error is AureliaApiException or HttpRequestException or TaskCanceledException) { return null; }
        var grid = new UniformGrid { Columns = 2 };
        grid.Children.Add(Fact("Encoder", TranscodingText.Encoder(status), small: true));
        grid.Children.Add(Fact("Converting Now", TranscodingText.Running(status), small: true));
        foreach (var session in status.Sessions) grid.Children.Add(Fact(session.Title, TranscodingText.Session(session), small: true));
        var panel = Block(Note("Converts titles for web browsers and for apps set to a streaming quality, in memory only."), grid);
        if (status.Hint is { } hint) panel.Children.Add(Note(hint));
        return Section("Video Conversion", panel);
    }

    private async Task<Control> ScrubPreviewsAsync()
    {
        var note = Message();
        ScrubPreviewSettingsResponse? stored = null;
        await scope.RunAsync(async () => stored = await Client.ScrubPreviewsAsync(), note);
        var panel = Block();
        if (stored is null) return Section("Scrub Previews", Block(note));
        var mode = stored.Mode;
        var interval = stored.IntervalSeconds;
        var cap = stored.StorageCapMegabytes;
        void Build()
        {
            panel.Children.Clear();
            panel.Children.Add(Note("Small timeline preview images prepared by the server so scrubbing shows a frame right away."));
            if (!stored.Available) panel.Children.Add(Note("FFmpeg is not installed on this server, so timeline previews are decoded on each device instead."));
            panel.Children.Add(Choice("Generate Previews", null, [("off", "Off"), ("onOpenOrPlay", "When a Title Is Opened or Played"), ("afterImport", "After Import")], mode, value => { mode = value; Build(); }).Also(r => r.Margin = new Thickness(0)));
            panel.Children.Add(Note(mode switch
            {
                "onOpenOrPlay" => "Prepares a compact preview strip in the server data folder when a title is opened or played. Converted video is never stored.",
                "afterImport" => "Prepares preview strips in the background after library scans, starting with the largest files, and pauses automatically while anyone is watching.",
                _ => "No preview strips are stored on disk. Timeline previews stay in memory only while scrubbing.",
            }));
            if (mode != "off")
            {
                int[] intervals = IntervalChoices.Contains(interval) ? IntervalChoices : [.. IntervalChoices.Append(interval).Order()];
                int[] caps = CapChoices.Contains(cap) ? CapChoices : [.. CapChoices.Append(cap).Order()];
                panel.Children.Add(Choice("Frame Interval", null, [.. intervals.Select(s => (s, $"Every {s} seconds"))], interval, value => interval = value).Also(r => r.Margin = new Thickness(0)));
                panel.Children.Add(Choice("Storage Limit", null, [.. caps.Select(m => (m, FormatCap(m)))], cap, value => cap = value).Also(r => r.Margin = new Thickness(0)));
            }
            panel.Children.Add(Note($"{stored.StoredTitleCount} {(stored.StoredTitleCount == 1 ? "title" : "titles")} · {Bytes(stored.StoredBytes)} of {FormatCap(cap)} used"));
            var total = stored.TotalScheduledCount;
            if (total > 0 && stored.CompletedCount < total)
            {
                panel.Children.Add(Note(stored.PausedForPlayback
                    ? $"Paused while playback is active ({stored.CompletedCount} of {total} prepared)"
                    : $"Preparing previews… ({stored.CompletedCount} of {total})"));
            }
            var delete = Button("Delete All Previews", async () =>
            {
                if (!await scope.Sheets.ConfirmAsync("Delete all scrub previews?", "The preview images are removed from the server. Videos are not touched.", "Delete All Previews", destructive: true)) return;
                if (await scope.RunAsync(() => Client.DeleteScrubPreviewsAsync(), note))
                {
                    stored = await Client.ScrubPreviewsAsync();
                    Build();
                }
            }, "destructive");
            delete.IsEnabled = stored.StoredTitleCount > 0 || stored.StoredBytes > 0;
            panel.Children.Add(Buttons(Button("Save Scrub Preview Settings", async () =>
            {
                if (await scope.RunAsync(async () => stored = await Client.SaveScrubPreviewsAsync(new UpdateScrubPreviewSettingsRequest(mode, interval, cap)), note)) Build();
            }, "primary"), delete));
            panel.Children.Add(note);
        }
        Build();
        return Section("Scrub Previews", panel);
    }

    internal static string FormatCap(int megabytes) => megabytes >= 1_000 && megabytes % 1_000 == 0 ? $"{megabytes / 1_000} GB" : $"{megabytes} MB";

    private StackPanel Details()
    {
        var current = status!;
        return Section("Server Details",
            Value("State", Capitalize(current.Readiness?.State ?? current.State)),
            Value("Version", current.Version),
            Value("Active stream requests", current.ActiveStreams.ToString(CultureInfo.InvariantCulture)),
            Value("TLS certificate expires", current.CertificateExpiresAt is { } expires ? Date(new DateTimeOffset(DateTime.SpecifyKind(expires, DateTimeKind.Utc))) : "—"),
            Value("Host addresses", current.NetworkAddresses.Count == 0 ? "—" : string.Join(", ", current.NetworkAddresses)),
            Value("Fingerprint", ServerIdentity.Display(scope.Client.Library.Server.Fingerprint)));
    }

    /// <summary>
    /// Hosted servers use a reversible trial; a standalone Linux service is configured on its computer.
    /// </summary>
    private StackPanel Network()
    {
        if (capabilities?.NativeHostOperations == true)
            return new NetworkSettingsSection(scope, Stored, Active, ReloadAsync);
        var lan = Active["lanAccessEnabled"]?.GetValue<bool>() == true;
        var port = Active["lanHttpsPort"]?.GetValue<int>() ?? 43111;
        var networks = Stored["allowedNetworks"] is JsonArray list && list.Count > 0 ? string.Join(", ", list.Select(n => n?.GetValue<string>())) : "Any private network";
        return Section("Network",
            Value("Active name", Active["serverName"]?.GetValue<string>() ?? scope.ServerName),
            Value("Connected address", scope.Client.Library.Server.Address.Authority),
            Value("Home network access", lan ? "On" : "Off"),
            Value("Port", port.ToString(CultureInfo.InvariantCulture)),
            Value("Advertised on the network", Stored["bonjourEnabled"]?.GetValue<bool>() != false ? "On" : "Off"),
            Value("Allowed networks", networks),
            Block(Note(Hosting == ServerHosting.LinuxPackage
                ? "A Linux server's network access is set up on the server itself with “sudo aurelia setup”."
                : "Change the network settings on the computer the server runs on. Local access is always retained; public Internet addresses are blocked.")));
    }

    private StackPanel Limits()
    {
        var note = Message();
        var days = Number(Stored["deviceSessionDays"]?.GetValue<int>() ?? 90, 1, 365, 1);
        var global = Number(Stored["globalStreamLimit"]?.GetValue<int>() ?? 32, 1, 128, 1);
        var perUser = Number(Stored["userStreamLimit"]?.GetValue<int>() ?? 4, 1, 16, 1);
        return Section("Sign-In & Streaming Limits",
            Row("Keep new devices signed in", "Days", days),
            Row("Streams at the same time in total", null, global),
            Row("Streams at the same time per profile", null, perUser),
            Block(Note("Existing sessions keep their current expiry. New pairing codes expire after five minutes. Device revocation stops affected streams immediately."),
                Button("Save Limits", async () =>
                {
                    if (perUser.Value > global.Value)
                    {
                        note.Text = "A profile cannot have more streams than the server in total.";
                        note.IsVisible = true;
                        return;
                    }
                    await SaveAsync(settings =>
                    {
                        settings["deviceSessionDays"] = (int)days.Value!;
                        settings["globalStreamLimit"] = (int)global.Value!;
                        settings["userStreamLimit"] = (int)perUser.Value!;
                    }, note);
                }, "primary"), note));
    }

    private async Task<Control> MaintenanceAsync()
    {
        var note = Message();
        var monitoring = new ToggleSwitch { IsChecked = Stored["monitoringEnabled"]?.GetValue<bool>() != false, OnContent = "", OffContent = "" };
        var check = Number(Stored["reconciliationMinutes"]?.GetValue<int>() ?? 360, 15, 10080, 15);
        var start = Number(Stored["maintenanceStartHour"]?.GetValue<int>() ?? 0, 0, 23, 1);
        var end = Number(Stored["maintenanceEndHour"]?.GetValue<int>() ?? 24, 1, 24, 1);
        var queue = Number(Stored["jobQueueLimit"]?.GetValue<int>() ?? 1000, 10, 10000, 10);
        var jobs = new StackPanel { Spacing = 6 };
        async Task ShowJobsAsync()
        {
            ServerJobHistory? history = null;
            IReadOnlyList<LibrarySummary> libraries = [];
            if (!await scope.RunAsync(async () =>
            {
                history = await Client.JobsAsync();
                libraries = await Client.LibrariesAsync();
            }, note)) return;
            jobs.Children.Clear();
            foreach (var library in libraries)
            {
                jobs.Children.Add(new DockPanel
                {
                    Children =
                    {
                        Button("Scan", async () => { if (await scope.RunAsync(() => Client.ScanAsync(library.Id), note)) await ShowJobsAsync(); }).Also(b => DockPanel.SetDock(b, Dock.Right)),
                        Toggle(library.Name, library.Path, library.MonitoringEnabled, value => _ = scope.RunAsync(() => Client.SetMonitoringAsync(library.Id, value), note)).Also(r => r.Margin = new Thickness(0)),
                    },
                });
            }
            foreach (var scan in history!.Scans.Take(8))
            {
                var row = new DockPanel { Children = { new TextBlock { Text = $"Scan · {ScanState(scan.State)} · {scan.FilesDiscovered} files", FontSize = 12, VerticalAlignment = VerticalAlignment.Center } } };
                if (scan.State is LibraryScanState.Queued or LibraryScanState.Running or LibraryScanState.WaitingForStorage)
                {
                    row.Children.Insert(0, Button("Cancel", async () => { if (await scope.RunAsync(() => Client.CancelScanAsync(scan.Id), note)) await ShowJobsAsync(); }).Also(b => DockPanel.SetDock(b, Dock.Right)));
                }
                else if (scan.State is LibraryScanState.Failed or LibraryScanState.Interrupted)
                {
                    row.Children.Insert(0, Button("Retry", async () => { if (await scope.RunAsync(() => Client.ScanAsync(scan.LibraryId), note)) await ShowJobsAsync(); }).Also(b => DockPanel.SetDock(b, Dock.Right)));
                }
                jobs.Children.Add(row);
            }
            foreach (var job in history.Metadata.Take(8))
            {
                var text = $"Metadata · {job.State} · {job.ItemsProcessed}/{job.ItemsTotal}" + (job.ItemsSkipped > 0 ? $" · {job.ItemsSkipped} skipped" : "");
                var row = new DockPanel { Children = { new TextBlock { Text = text, FontSize = 12, VerticalAlignment = VerticalAlignment.Center } } };
                if (job.State is MetadataJobState.Queued or MetadataJobState.Running)
                {
                    row.Children.Insert(0, Button("Cancel", async () => { if (await scope.RunAsync(() => Client.CancelMetadataJobAsync(job.Id), note)) await ShowJobsAsync(); }).Also(b => DockPanel.SetDock(b, Dock.Right)));
                }
                else if (job.State is MetadataJobState.Failed or MetadataJobState.Interrupted)
                {
                    row.Children.Insert(0, Button("Retry", async () => { if (await scope.RunAsync(() => Client.RetryMetadataJobAsync(job.Id), note)) await ShowJobsAsync(); }).Also(b => DockPanel.SetDock(b, Dock.Right)));
                }
                jobs.Children.Add(row);
            }
        }
        await ShowJobsAsync();
        return Section("Library Maintenance",
            Row("Notice New and Removed Files Automatically", null, monitoring),
            Row("Full check every", "Minutes", check),
            Row("Maintenance from", "Hour of the day", start),
            Row("Maintenance until", "Hour of the day", end),
            Row("Maximum waiting tasks", null, queue),
            Block(Note("Maintenance hours use the server's local time. Manual scans remain available. Media is read directly; Aurelia does not copy videos."),
                Buttons(Button("Save Maintenance Settings", () => SaveAsync(settings =>
                {
                    settings["monitoringEnabled"] = monitoring.IsChecked == true;
                    settings["reconciliationMinutes"] = (int)check.Value!;
                    settings["maintenanceStartHour"] = (int)start.Value!;
                    settings["maintenanceEndHour"] = (int)end.Value!;
                    settings["jobQueueLimit"] = (int)queue.Value!;
                }, note), "primary"), Button("Refresh Queue", ShowJobsAsync)),
                jobs, note));
    }

    internal static string ScanState(LibraryScanState state) => state switch
    {
        LibraryScanState.WaitingForStorage => "Waiting for Storage",
        _ => state.ToString(),
    };

    private async Task<Control> BackupsAsync()
    {
        var note = Message();
        var interval = Number(Stored["backupIntervalHours"]?.GetValue<int>() ?? 24, 1, 168, 1);
        var daily = Number(Stored["dailyBackupsRetained"]?.GetValue<int>() ?? 7, 1, 30, 1);
        var weekly = Number(Stored["weeklyBackupsRetained"]?.GetValue<int>() ?? 4, 1, 12, 1);
        var list = new StackPanel { Spacing = 4 };
        async Task ShowBackupsAsync()
        {
            IReadOnlyList<ServerBackupSummary> backups = [];
            if (!await scope.RunAsync(async () => backups = await Client.BackupsAsync(), note)) return;
            list.Children.Clear();
            foreach (var backup in backups.Take(8))
            {
                list.Children.Add(new DockPanel
                {
                    Children =
                    {
                        Button("Verify", async () =>
                        {
                            if (await scope.RunAsync(() => Client.VerifyBackupAsync(backup.Name), note))
                            {
                                note.Text = "Backup integrity and schema verified.";
                                note.IsVisible = true;
                            }
                        }).Also(b => DockPanel.SetDock(b, Dock.Right)),
                        new TextBlock { Text = $"{Capitalize(backup.Kind)} · {Date(backup.CreatedAt)} · {Bytes(backup.Bytes)}", FontSize = 12, VerticalAlignment = VerticalAlignment.Center },
                    },
                });
            }
        }
        await ShowBackupsAsync();
        var passphrase = new TextBox { PasswordChar = '•', PlaceholderText = "Backup passphrase (at least 12 characters)" };
        var repeat = new TextBox { PasswordChar = '•', PlaceholderText = "Repeat passphrase for export" };
        AutomationProperties.SetName(passphrase, "Backup Passphrase");
        AutomationProperties.SetName(repeat, "Repeat Passphrase");
        var signsOut = new CheckBox { Content = "Restoring signs out every device; I will sign in and review trust again" };
        var otherServer = new CheckBox { Content = "Allow a backup from another server (changes server identity and trust)" };
        PreparedRestore? prepared = null;
        var apply = Button("Restore Verified Backup & Restart", async () =>
        {
            if (prepared is null || signsOut.IsChecked != true) return;
            if (!await scope.Sheets.ConfirmAsync("Restore this backup?", "The server replaces its library and settings with the backup and restarts. Every device is signed out.", "Restore & Restart", destructive: true)) return;
            if (await scope.RunAsync(() => Client.ApplyRestoreAsync(prepared.Id), note))
            {
                prepared = null;
                note.Text = "Restore requested. Connect and sign in again after the server restarts.";
                note.IsVisible = true;
            }
        }, "destructive");
        apply.IsVisible = false;
        var export = Button("Export Encrypted Backup…", async () =>
        {
            if ((passphrase.Text?.Length ?? 0) < 12 || passphrase.Text != repeat.Text)
            {
                note.Text = "Enter the same passphrase twice, with at least 12 characters.";
                note.IsVisible = true;
                return;
            }
            var storage = TopLevel.GetTopLevel(this)?.StorageProvider;
            if (storage is null) return;
            var file = await storage.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = "Aurelia-Server.aureliabackup", Title = "Export Encrypted Backup" });
            if (file is null) return;
            byte[] bytes = [];
            if (!await scope.RunAsync(async () => bytes = await Client.ExportBackupAsync(passphrase.Text!), note)) return;
            await using (var stream = await file.OpenWriteAsync())
            {
                await stream.WriteAsync(bytes);
            }
            passphrase.Text = repeat.Text = "";
            note.Text = "Encrypted backup saved. No media files were copied.";
            note.IsVisible = true;
        });
        var restore = Button("Choose Backup & Verify Restore…", async () =>
        {
            if ((passphrase.Text?.Length ?? 0) < 12 || signsOut.IsChecked != true)
            {
                note.Text = "Enter the backup's passphrase and confirm that every device is signed out.";
                note.IsVisible = true;
                return;
            }
            var storage = TopLevel.GetTopLevel(this)?.StorageProvider;
            if (storage is null) return;
            var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = false, Title = "Choose Backup" });
            if (files.Count == 0) return;
            byte[] bytes;
            await using (var stream = await files[0].OpenReadAsync())
            {
                using var copy = new MemoryStream();
                await stream.CopyToAsync(copy);
                bytes = copy.ToArray();
            }
            if (await scope.RunAsync(async () => prepared = await Client.PrepareRestoreAsync(bytes, passphrase.Text!, otherServer.IsChecked == true), note))
            {
                passphrase.Text = repeat.Text = "";
                apply.IsVisible = true;
                note.Text = "Backup verified in a private staging area. Active data has not changed.";
                note.IsVisible = true;
            }
        });
        restore.IsEnabled = capabilities?.EncryptedBackups != false;
        return Section("Backup Details",
            Row("Automatic backup every", "Hours", interval),
            Row("Keep daily backups", null, daily),
            Row("Keep weekly backups", null, weekly),
            Block(Buttons(Button("Save Backup Settings", () => SaveAsync(settings =>
                {
                    settings["backupIntervalHours"] = (int)interval.Value!;
                    settings["dailyBackupsRetained"] = (int)daily.Value!;
                    settings["weeklyBackupsRetained"] = (int)weekly.Value!;
                }, note), "primary"), Button("Refresh Backups", ShowBackupsAsync)),
                list),
            Block(new TextBlock { Text = "Encrypted Full Server Backup", FontWeight = FontWeight.SemiBold },
                Note("Includes the database, configuration, TLS identity, server secrets, and your imported images and crops. Videos and downloadable artwork are excluded. Keep the passphrase safely; it cannot be recovered."),
                passphrase, repeat, export, signsOut, otherServer, restore, apply, note));
    }

    private async Task<Control> DiagnosticsAsync()
    {
        var note = Message();
        var retention = Number(Stored["eventRetentionDays"]?.GetValue<int>() ?? 30, 1, 90, 1);
        var maximum = Number(Stored["maximumEvents"]?.GetValue<int>() ?? 10000, 100, 10000, 100);
        var events = new StackPanel { Spacing = 2 };
        async Task ShowEventsAsync()
        {
            IReadOnlyList<ServerEventSummary> list = [];
            if (!await scope.RunAsync(async () => list = await Client.DiagnosticsAsync(), note)) return;
            events.Children.Clear();
            foreach (var item in list.Take(12))
            {
                events.Children.Add(new TextBlock { Text = $"{Date(item.At)} · {item.Severity} · {item.Code}", FontFamily = new FontFamily("monospace"), FontSize = 11 });
            }
            if (list.Count == 0) events.Children.Add(Note("No events recorded."));
        }
        await ShowEventsAsync();
        return Section("Diagnostics",
            Row("Keep events for", "Days", retention),
            Row("Maximum events", null, maximum),
            Block(Buttons(
                    Button("Save Diagnostic Settings", () => SaveAsync(settings =>
                    {
                        settings["eventRetentionDays"] = (int)retention.Value!;
                        settings["maximumEvents"] = (int)maximum.Value!;
                    }, note), "primary"),
                    Button("Refresh Events", ShowEventsAsync),
                    Button("Export Sanitized Diagnostics…", async () =>
                    {
                        var storage = TopLevel.GetTopLevel(this)?.StorageProvider;
                        if (storage is null) return;
                        var file = await storage.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = "Aurelia-Server-Diagnostics.json", Title = "Export Diagnostics" });
                        if (file is null) return;
                        byte[] bytes = [];
                        if (!await scope.RunAsync(async () => bytes = await Client.ExportDiagnosticsAsync(), note)) return;
                        await using var stream = await file.OpenWriteAsync();
                        await stream.WriteAsync(bytes);
                    })),
                events, note));
    }

    private static NumericUpDown Number(int value, int minimum, int maximum, int step) => new()
    {
        Value = Math.Clamp(value, minimum, maximum),
        Minimum = minimum,
        Maximum = maximum,
        Increment = step,
        FormatString = "0",
        Width = 150,
    };

    internal static string Capitalize(string text) => text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];
}
