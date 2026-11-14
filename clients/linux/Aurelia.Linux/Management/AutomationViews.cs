using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>
/// Settings › Server › Smart Home for the owner ("automation-v1"), as on the Mac: webhooks for
/// Home Assistant and other receivers, keys for Home Assistant and shortcuts, and turning the
/// server on and off.
/// </summary>
public sealed class AutomationSection : StackPanel
{
    private readonly AdminScope scope;
    private readonly TextBlock message = Message();
    private readonly StackPanel hooks = new() { Spacing = 8 };
    private readonly StackPanel tokens = new() { Spacing = 8 };
    private readonly StackPanel power = new() { Spacing = 8 };
    private AutomationOverview? overview;

    public AutomationSection(AdminScope scope)
    {
        this.scope = scope;
        Spacing = 0;
        Children.Add(Section("Smart Home",
            Block(Note("Aurelia tells Home Assistant and other automations the moment a movie starts, pauses or ends, or a new title arrives, so lights and scenes can follow. Home Assistant can also wake the server and turn it off."),
                message,
                new TextBlock { Text = "Webhooks", FontWeight = FontWeight.SemiBold },
                Note("Each webhook gets the events you choose, signed so the receiver can check they came from your server."),
                hooks, Button("Add Webhook…", () => EditAsync(null), "primary")),
            Block(new TextBlock { Text = "Keys for Home Assistant and Shortcuts", FontWeight = FontWeight.SemiBold },
                Note("For the other direction: Home Assistant reads what plays, or turns the server off, with a key you create here."),
                tokens, Button("Create Key…", CreateTokenAsync)),
            Block(new TextBlock { Text = "Turning the Server On and Off", FontWeight = FontWeight.SemiBold }, power)));
        Loading = ReloadAsync();
    }

    internal Task Loading { get; private set; }

    private ManagementClient Client => scope.Client;

    public async Task ReloadAsync()
    {
        AutomationOverview? loaded = null;
        if (!await scope.RunAsync(async () => loaded = await Client.AutomationOverviewAsync(), message) || loaded is null) return;
        overview = loaded;
        FillHooks(loaded);
        FillTokens(loaded);
        FillPower(loaded);
    }

    private void FillHooks(AutomationOverview current)
    {
        hooks.Children.Clear();
        foreach (var hook in current.Webhooks)
        {
            var status = AutomationText.Status(hook);
            var events = string.Join(", ", hook.Events.Select(kind => current.Events.FirstOrDefault(e => e.Kind == kind)?.Title ?? kind));
            var actions = Buttons(
                Button("Send Test", () => TestAsync(hook)),
                Button("Deliveries…", () => DeliveriesAsync(hook)),
                Button("Edit…", () => EditAsync(hook)),
                Button("New Secret…", () => RotateAsync(hook)),
                Button("Remove…", () => RemoveAsync(hook), "destructive"));
            var detail = $"{AutomationText.Host(hook.Url)} · {events}" + (hook.PausedReason is { } reason ? "\n" + reason : "");
            hooks.Children.Add(Card($"{hook.Name} · {status.Text}", detail, actions, status.Warning));
        }
        if (hooks.Children.Count == 0)
            hooks.Children.Add(Note("No webhooks yet. In Home Assistant create an automation with a Webhook trigger, then add it here with its ID."));
    }

    private void FillTokens(AutomationOverview current)
    {
        tokens.Children.Clear();
        foreach (var token in current.Tokens)
        {
            var scopes = string.Join(", ", token.Scopes.Select(s => AutomationText.Scopes.FirstOrDefault(item => item.Id == s).Title ?? s));
            var used = token.LastUsedAt is { } at ? "last used " + Date(at) : "never used";
            tokens.Children.Add(Card(token.Name, $"{scopes} · {used}",
                Button("Remove…", async () =>
                {
                    if (!await scope.Sheets.ConfirmAsync($"Remove the key “{token.Name}”?", "Whatever uses it stops working at once.", "Remove", destructive: true)) return;
                    await RunAndReloadAsync(() => Client.RevokeIntegrationTokenAsync(token.Id));
                }, "destructive"), highlighted: false));
        }
        if (tokens.Children.Count == 0) tokens.Children.Add(Note("No keys yet."));
    }

    private void FillPower(AutomationOverview current)
    {
        power.Children.Clear();
        power.Children.Add(Value("Network Card", current.WakeOnLanAddresses.Count == 0 ? "Not reported" : string.Join(", ", current.WakeOnLanAddresses)));
        power.Children.Add(Note(current.WakeOnLanAddresses.Count == 0
            ? "This server doesn't report a network card that can be woken, for example when it runs in an app or a container."
            : "Home Assistant's Wake on LAN integration (wake_on_lan.send_magic_packet) starts the server with this MAC address, as every Aurelia app does."));
        if (current.PowerActions.Count == 0)
            power.Children.Add(Note("This server can't turn itself off; it runs as a service that something else starts and stops."));
        var buttons = Buttons(current.PowerActions.Select(action => (Control)Button(AutomationText.PowerTitle(action), () => PowerAsync(action),
            action == PowerNowActions.Stop ? "chip" : "destructive")).ToArray());
        power.Children.Add(buttons);
    }

    private async Task PowerAsync(string action)
    {
        if (!await scope.Sheets.ConfirmAsync(AutomationText.PowerTitle(action) + "?", AutomationText.PowerDetail(action), AutomationText.PowerTitle(action), destructive: true)) return;
        try
        {
            Show((await Client.PowerNowAsync(action)).Message);
        }
        catch (AureliaApiException exception) when (exception.Code == "playback_active")
        {
            if (await scope.Sheets.ConfirmAsync("Someone is watching", "Turn it off anyway? Their playback stops.", AutomationText.PowerTitle(action), destructive: true))
                await scope.RunAsync(async () => Show((await Client.PowerNowAsync(action, force: true)).Message), message);
        }
        catch (Exception exception) when (exception is AureliaApiException or HttpRequestException)
        {
            Show(exception.Message);
        }
    }

    private async Task TestAsync(AutomationWebhookSummary hook)
    {
        AutomationDeliverySummary? delivery = null;
        if (!await scope.RunAsync(async () => delivery = await Client.TestWebhookAsync(hook.Id), message) || delivery is null) return;
        Show(delivery.State == AutomationDeliveryStates.Succeeded
            ? $"“{hook.Name}”: delivered in {delivery.DurationMilliseconds ?? 0} ms."
            : $"“{hook.Name}”: not delivered. {delivery.Error ?? "No answer."}");
        await ReloadAsync();
    }

    private async Task RemoveAsync(AutomationWebhookSummary hook)
    {
        if (!await scope.Sheets.ConfirmAsync($"Remove “{hook.Name}”?", "It stops getting events at once. Your automation in Home Assistant stays.", "Remove", destructive: true)) return;
        await RunAndReloadAsync(() => Client.DeleteWebhookAsync(hook.Id));
    }

    private async Task RotateAsync(AutomationWebhookSummary hook)
    {
        AutomationSecretResponse? secret = null;
        if (!await scope.RunAsync(async () => secret = await Client.RotateWebhookSecretAsync(hook.Id), message) || secret is null) return;
        await ShowValueAsync("New Secret", "The old secret no longer works. Give this one to your receiver if it checks signatures.", secret.Secret, null);
    }

    private async Task EditAsync(AutomationWebhookSummary? hook)
    {
        if (overview is not { } current) return;
        var parts = AutomationText.SplitHomeAssistantUrl(hook?.Url ?? "");
        var name = new TextBox { Text = hook?.Name ?? "Home Assistant", MaxLength = 64 };
        AutomationProperties.SetName(name, "Name");
        var preset = new ComboBox { ItemsSource = new[] { "Home Assistant", "Other Receiver" }, SelectedIndex = hook?.Preset == AutomationPresets.Generic ? 1 : 0, MinWidth = 200 };
        AutomationProperties.SetName(preset, "Receiver");
        var address = new TextBox { Text = parts.Address, PlaceholderText = "homeassistant.local:8123" };
        AutomationProperties.SetName(address, "Home Assistant Address");
        var hookId = new TextBox { Text = parts.WebhookId, PlaceholderText = "aurelia_movie_lights" };
        AutomationProperties.SetName(hookId, "Webhook ID");
        var url = new TextBox { Text = hook?.Url ?? "", PlaceholderText = "https://…" };
        AutomationProperties.SetName(url, "Address");
        var home = new StackPanel
        {
            Spacing = 6,
            Children = { Label("Home Assistant Address"), address, Label("Webhook ID"), hookId,
            Note("Home Assistant's address as you open it in a browser, and the ID of the automation's Webhook trigger (letters, digits, - and _).") }
        };
        var generic = new StackPanel
        {
            Spacing = 6,
            Children = { Label("Address"), url,
            Note("Receives a signed JSON POST for each event. Use https:// outside your home network.") }
        };
        void UpdatePreset() { home.IsVisible = preset.SelectedIndex == 0; generic.IsVisible = preset.SelectedIndex == 1; }
        preset.SelectionChanged += (_, _) => UpdatePreset();
        UpdatePreset();
        var chosenEvents = new HashSet<string>(hook?.Events ?? [AutomationEvents.PlaybackStarted, AutomationEvents.PlaybackPaused,
            AutomationEvents.PlaybackResumed, AutomationEvents.PlaybackStopped, AutomationEvents.PlaybackFinished]);
        var events = new StackPanel { Spacing = 4 };
        foreach (var description in current.Events) events.Children.Add(Check(description.Title, description.Detail, chosenEvents, description.Kind));
        var chosenDevices = new HashSet<Guid>(hook?.DeviceIds ?? []);
        var chosenProfiles = new HashSet<Guid>(hook?.ProfileIds ?? []);
        var filters = new StackPanel { Spacing = 4 };
        filters.Children.Add(Note("With none chosen, events come from every device and profile."));
        foreach (var device in current.Devices) filters.Children.Add(Check(device.Name, device.Detail, chosenDevices, device.Id));
        foreach (var profile in current.Profiles) filters.Children.Add(Check(profile.Name, profile.Detail, chosenProfiles, profile.Id));
        var titles = new CheckBox { IsChecked = hook?.IncludeTitles ?? true, Content = "Send Titles and Profile Names" };
        var children = new CheckBox { IsChecked = hook?.ExcludeChildren ?? false, Content = "Leave Out Children's Profiles" };
        var enabled = new CheckBox { IsChecked = hook?.Enabled ?? true, Content = "On" };
        var problem = Message();
        var save = new Button { Content = hook is null ? "Add Webhook" : "Save", Classes = { "primary" }, IsDefault = true };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => scope.Sheets.Close(false);
        AutomationWebhookCreated? created = null;
        save.Click += async (_, _) =>
        {
            var target = preset.SelectedIndex == 0 ? AutomationText.HomeAssistantUrl(address.Text ?? "", hookId.Text ?? "") : url.Text?.Trim();
            if (string.IsNullOrEmpty(target))
            {
                problem.Text = preset.SelectedIndex == 0 ? "Enter Home Assistant's address and the webhook ID." : "Enter the address.";
                problem.IsVisible = true;
                return;
            }
            if (chosenEvents.Count == 0)
            {
                problem.Text = "Choose at least one event.";
                problem.IsVisible = true;
                return;
            }
            var request = new SaveAutomationWebhookRequest((name.Text ?? "").Trim(), target,
                preset.SelectedIndex == 0 ? AutomationPresets.HomeAssistant : AutomationPresets.Generic,
                current.Events.Select(e => e.Kind).Where(chosenEvents.Contains).ToList(), chosenDevices.ToList(), chosenProfiles.ToList(),
                titles.IsChecked == true, children.IsChecked == true, enabled.IsChecked == true);
            save.IsEnabled = false;
            var saved = await scope.RunAsync(async () =>
            {
                if (hook is null) created = await Client.CreateWebhookAsync(request);
                else await Client.SaveWebhookAsync(hook.Id, request);
            }, problem);
            save.IsEnabled = true;
            if (saved) scope.Sheets.Close(true);
        };
        var done = await scope.Sheets.ShowAsync(new StackPanel
        {
            Spacing = 10,
            Width = 600,
            Children =
            {
                new TextBlock { Text = hook is null ? "Add a Webhook" : $"Edit “{hook.Name}”", FontSize = 18, FontWeight = FontWeight.Bold },
                Note("Aurelia sends an event the moment it happens, such as a movie starting on the living room TV, so lights or scenes can follow."),
                new ScrollViewer
                {
                    MaxHeight = 480,
                    Content = new StackPanel
                    {
                        Spacing = 8,
                        Children =
                        {
                            Label("Name"), name, Label("Receiver"), preset, home, generic,
                            Label("Events"), events,
                            new Expander { Header = "Only Some Devices or Profiles", Content = filters },
                            Label("Privacy"), titles, Note("Off sends only which device played, not what or who."),
                            children, Note("Nothing is sent while a children's profile watches."), enabled,
                        },
                    },
                },
                problem,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, save } },
            },
        });
        if (!done) return;
        if (created is not null)
            await ShowValueAsync("Webhook Saved",
                "Every event carries a signature made with this secret (header X-Aurelia-Signature). Keep it if your receiver checks signatures; it is shown only now.",
                created.Secret,
                created.Webhook.Preset == AutomationPresets.HomeAssistant
                    ? AutomationText.HomeAssistantExample(AutomationText.SplitHomeAssistantUrl(created.Webhook.Url).WebhookId) : null);
        await ReloadAsync();
    }

    private async Task CreateTokenAsync()
    {
        var name = new TextBox { Text = "Home Assistant", MaxLength = 64 };
        AutomationProperties.SetName(name, "Name");
        var chosen = new HashSet<string> { IntegrationScopes.Status };
        var scopes = new StackPanel { Spacing = 4 };
        foreach (var item in AutomationText.Scopes) scopes.Children.Add(Check(item.Title, item.Detail, chosen, item.Id));
        var problem = Message();
        var create = new Button { Content = "Create Key", Classes = { "primary" }, IsDefault = true };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => scope.Sheets.Close(false);
        IntegrationTokenCreated? created = null;
        create.Click += async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(name.Text) || chosen.Count == 0)
            {
                problem.Text = "Give the key a name and choose what it may do.";
                problem.IsVisible = true;
                return;
            }
            var request = new CreateIntegrationTokenRequest(name.Text.Trim(), AutomationText.Scopes.Select(s => s.Id).Where(chosen.Contains).ToList());
            if (await scope.RunAsync(async () => created = await Client.CreateIntegrationTokenAsync(request), problem)) scope.Sheets.Close(true);
        };
        var done = await scope.Sheets.ShowAsync(new StackPanel
        {
            Spacing = 10,
            Width = 480,
            Children =
            {
                new TextBlock { Text = "Create a Key", FontSize = 18, FontWeight = FontWeight.Bold },
                Note("A key lets Home Assistant or a shortcut talk to Aurelia without a profile. It can do only what you allow here, and you can remove it any time."),
                Label("Name"), name, Label("What the Key May Do"), scopes, problem,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, create } },
            },
        });
        if (!done || created is null) return;
        await ShowValueAsync("Key Created",
            "Copy the key now: it is shown only once. Aurelia keeps only a fingerprint of it. Send it as “Authorization: Bearer <key>”.", created.Value, null);
        await ReloadAsync();
    }

    private async Task DeliveriesAsync(AutomationWebhookSummary hook)
    {
        var list = new StackPanel { Spacing = 6 };
        var problem = Message();
        var close = new Button { Content = "Done", Classes = { "primary" }, IsDefault = true, IsCancel = true };
        close.Click += (_, _) => scope.Sheets.Close(true);
        var shown = scope.Sheets.ShowAsync(new StackPanel
        {
            Spacing = 10,
            Width = 600,
            Children =
            {
                new TextBlock { Text = $"Deliveries of “{hook.Name}”", FontSize = 18, FontWeight = FontWeight.Bold },
                Note("The last 100 deliveries of the past seven days, with how long the receiver took. The events themselves are not kept."),
                problem,
                new ScrollViewer { MaxHeight = 420, Content = list },
                new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { close } },
            },
        });
        IReadOnlyList<AutomationDeliverySummary> deliveries = [];
        if (await scope.RunAsync(async () => deliveries = await Client.WebhookDeliveriesAsync(hook.Id), problem))
        {
            foreach (var delivery in deliveries)
            {
                var parts = new[]
                {
                    delivery.State == AutomationDeliveryStates.Succeeded ? "Delivered" : delivery.State == AutomationDeliveryStates.Pending ? "Trying again" : "Failed",
                    delivery.StatusCode is { } code ? $"HTTP {code}" : null,
                    delivery.DurationMilliseconds is { } ms ? $"{ms} ms" : null,
                    delivery.Attempt > 1 ? $"attempt {delivery.Attempt}" : null,
                    delivery.Error,
                    Date(delivery.At),
                }.Where(part => !string.IsNullOrEmpty(part));
                list.Children.Add(new StackPanel
                {
                    Spacing = 2,
                    Children = { new TextBlock { Text = delivery.Event, FontWeight = FontWeight.SemiBold }, Note(string.Join(" · ", parts)) },
                });
            }
            if (list.Children.Count == 0) list.Children.Add(Note("Nothing sent yet."));
        }
        await shown;
    }

    private Task<bool> ShowValueAsync(string title, string explanation, string value, string? example)
    {
        var done = new Button { Content = "Done", Classes = { "primary" }, IsDefault = true, IsCancel = true };
        done.Click += (_, _) => scope.Sheets.Close(true);
        var panel = new StackPanel
        {
            Spacing = 10,
            Width = 560,
            Children =
            {
                new TextBlock { Text = title, FontSize = 18, FontWeight = FontWeight.Bold },
                new TextBlock { Text = explanation, TextWrapping = TextWrapping.Wrap },
                new SelectableTextBlock { Text = value, FontFamily = new FontFamily("monospace"), TextWrapping = TextWrapping.Wrap },
                Button("Copy", () => CopyAsync(value)),
            },
        };
        if (example is not null)
        {
            panel.Children.Add(new TextBlock { Text = "Example Automation", FontWeight = FontWeight.SemiBold });
            panel.Children.Add(Note("In Home Assistant: Settings › Automations › Create Automation › ⋮ › Edit in YAML, paste this and change the lights to yours."));
            panel.Children.Add(new ScrollViewer
            {
                MaxHeight = 240,
                Content = new SelectableTextBlock { Text = example, FontFamily = new FontFamily("monospace"), FontSize = 12 },
            });
            panel.Children.Add(Button("Copy Example", () => CopyAsync(example)));
        }
        panel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { done } });
        return scope.Sheets.ShowAsync(panel);
    }

    private async Task CopyAsync(string text)
    {
        if (TopLevel.GetTopLevel(this)?.Clipboard is { } clipboard) await clipboard.SetTextAsync(text);
    }

    private async Task RunAndReloadAsync(Func<Task> action)
    {
        if (await scope.RunAsync(action, message)) await ReloadAsync();
    }

    private void Show(string text)
    {
        message.Text = text;
        message.Foreground = null;
        message.IsVisible = true;
    }

    private static TextBlock Label(string text) => new() { Text = text, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 4, 0, 0) };

    private static CheckBox Check<T>(string title, string? detail, HashSet<T> chosen, T value)
    {
        var box = new CheckBox
        {
            IsChecked = chosen.Contains(value),
            Content = new StackPanel
            {
                Spacing = 1,
                Children = { new TextBlock { Text = title }, detail is null ? new TextBlock { IsVisible = false } : Note(detail) },
            },
        };
        AutomationProperties.SetName(box, title);
        box.IsCheckedChanged += (_, _) => { if (box.IsChecked == true) chosen.Add(value); else chosen.Remove(value); };
        return box;
    }

    private static Border Card(string title, string detail, Control actions, bool highlighted) => new()
    {
        Classes = { "card" },
        Padding = new Thickness(12),
        BorderThickness = new Thickness(highlighted ? 1 : 0),
        BorderBrush = highlighted ? new SolidColorBrush(Color.Parse("#FFB547")) : null,
        Child = new StackPanel
        {
            Spacing = 6,
            Children =
            {
                new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap },
                Note(detail),
                actions,
            },
        },
    };
}
