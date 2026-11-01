using System.Globalization;
using System.Text.Json.Nodes;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>The host's network editor, including a fresh authenticated connection before a trial is kept.</summary>
internal sealed class NetworkSettingsSection : StackPanel
{
    public NetworkSettingsSection(AdminScope scope, JsonObject stored, JsonObject active, Func<Task> reload)
    {
        var session = scope.Session;
        var original = session.Server!;
        var owner = session.Profile!;
        var name = new TextBox { Text = stored["serverName"]?.GetValue<string>() ?? scope.ServerName, Width = 260, MaxLength = 128 };
        var lan = new ToggleSwitch { IsChecked = stored["lanAccessEnabled"]?.GetValue<bool>() == true, OnContent = "", OffContent = "" };
        var port = new NumericUpDown { Value = stored["lanHttpsPort"]?.GetValue<int>() ?? 43111, Minimum = 1024, Maximum = 65535, Increment = 1, FormatString = "0", Width = 140 };
        var advertise = new ToggleSwitch { IsChecked = stored["bonjourEnabled"]?.GetValue<bool>() != false, OnContent = "", OffContent = "" };
        var ranges = new TextBox
        {
            Text = stored["allowedNetworks"] is JsonArray list ? string.Join("\n", list.Select(n => n?.GetValue<string>())) : "",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 72,
            MaxLength = 4096,
            PlaceholderText = "192.168.1.0/24 (optional)",
        };
        AutomationProperties.SetName(ranges, "Allowed private networks");
        var disconnect = new CheckBox { Content = "I understand that remote devices will lose access" };
        var note = Message();
        var editor = new StackPanel { Spacing = 0 };
        var pending = new StackPanel { Spacing = 10, IsVisible = false };
        var trial = new NetworkTrial(session.Api, original, owner);
        var trialDeadline = new TextBlock { TextWrapping = TextWrapping.Wrap, Classes = { "subdued" } };
        var activeLan = active["lanAccessEnabled"]?.GetValue<bool>() == true;
        var isLocal = original.LocallyManaged || ServerAddress.IsLoopback(original.Address);
        lan.IsEnabled = isLocal || !activeLan;
        void UpdateDisconnect() => disconnect.IsVisible = activeLan && lan.IsChecked != true;
        lan.IsCheckedChanged += (_, _) => UpdateDisconnect();
        UpdateDisconnect();

        editor.Children.Add(Row("Server name", null, name));
        editor.Children.Add(Row("Home network access", "HTTPS from LAN and private VPN", lan));
        editor.Children.Add(Row("HTTPS port", null, port));
        editor.Children.Add(Row("Advertise on the network", null, advertise));
        editor.Children.Add(Block(Note("Allowed private networks (one CIDR per line, optional)"), ranges,
            Note("Local HTTPS access is always retained. Public Internet addresses are blocked."), disconnect,
            Button("Try Network Settings (60-second rollback)", async () =>
            {
                if (activeLan && lan.IsChecked != true && disconnect.IsChecked != true)
                {
                    note.Text = "Confirm that remote devices will lose access before starting the trial.";
                    note.IsVisible = true;
                    return;
                }
                var started = await scope.RunAsync(async () =>
                {
                    var settings = NetworkTrial.Settings(stored, name.Text ?? "", lan.IsChecked == true,
                        (int)(port.Value ?? 0), advertise.IsChecked == true, ranges.Text ?? "");
                    var operation = await trial.StartAsync(scope.Client, settings, disconnect.IsChecked == true);
                    session.BeginNetworkConfirmation(operation.ConfirmBefore!.Value);
                    trialDeadline.Text = $"Reconnect to {trial.Candidate!.Address.Authority} and confirm before {operation.ConfirmBefore.Value.ToLocalTime().ToString("HH:mm:ss", CultureInfo.InvariantCulture)}. The previous network settings return automatically after 60 seconds unless confirmed.";
                }, note);
                if (!started) return;
                editor.IsVisible = false;
                pending.IsVisible = true;
            }, "primary")));
        pending.Children.Add(trialDeadline);
        pending.Children.Add(Note("The server restarts for this trial. Verify the new connection with your Profile PIN and Server Password to keep the settings."));
        pending.Children.Add(Button("Verify New Connection & Keep Settings", async () =>
        {
            if (!session.NetworkConfirmationPending)
            {
                note.Text = "The trial ended. Open your profile again before changing network settings.";
                note.IsVisible = true;
                return;
            }
            var pin = new TextBox { PasswordChar = '•', PlaceholderText = "Profile PIN", MaxLength = 8 };
            var password = new TextBox { PasswordChar = '•', PlaceholderText = "Server Password" };
            AutomationProperties.SetName(pin, "Profile PIN");
            AutomationProperties.SetName(password, "Server Password");
            var confirm = new Button { Content = "Verify & Keep Settings", Classes = { "primary" }, IsDefault = true };
            var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
            confirm.Click += (_, _) => scope.Sheets.Close(true);
            cancel.Click += (_, _) => scope.Sheets.Close(false);
            var accepted = await scope.Sheets.ShowAsync(new StackPanel
            {
                Width = 420,
                Spacing = 14,
                Children =
                {
                    new TextBlock { Text = "Verify New Connection", FontSize = 18, FontWeight = FontWeight.Bold },
                    Note($"Verify {owner.User.Username}'s profile on {trial.Candidate!.Address.Authority}. The trusted server key must match before credentials are sent."),
                    pin, password,
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, confirm } },
                },
            });
            if (!accepted) { pin.Text = password.Text = ""; return; }
            var kept = await scope.RunAsync(async () =>
            {
                var confirmed = await trial.ConfirmAsync(pin.Text ?? "", password.Text ?? "", session.Capabilities);
                var adopted = false;
                try
                {
                    await session.AcceptConfirmedNetworkAsync(confirmed);
                    scope.RefreshClient();
                    adopted = true;
                }
                finally
                {
                    if (!adopted)
                    {
                        try { await session.Api.EndProfileAsync(confirmed.Server, confirmed.Profile, CancellationToken.None); }
                        catch (AureliaApiException) { }
                    }
                }
            }, note);
            pin.Text = password.Text = "";
            if (kept) await reload();
        }, "primary"));
        Children.Add(Section("Network",
            Value("Active name", active["serverName"]?.GetValue<string>() ?? scope.ServerName),
            Value("Connected address", original.Address.Authority), editor, Block(pending, note)));
    }
}
