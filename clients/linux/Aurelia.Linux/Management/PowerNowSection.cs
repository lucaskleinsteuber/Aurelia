using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Management;
using Avalonia.Controls;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>
/// Settings › Power › Right Now for the owner: Sleep, Turn Off or Stop Now, without waiting for
/// the unused minutes ("power-now-v1"), as on the Mac and in the browser.
/// </summary>
public sealed class PowerNowSection : StackPanel
{
    private readonly AdminScope scope;
    private readonly TextBlock message = Message();
    private readonly StackPanel actions = new() { Spacing = 8 };

    public PowerNowSection(AdminScope scope)
    {
        this.scope = scope;
        Children.Add(Section("Right Now", Block(Note("Without waiting for the unused minutes."), message, actions)));
        Loading = ReloadAsync();
    }

    internal Task Loading { get; private set; }

    private ManagementClient Client => scope.Client;

    public async Task ReloadAsync()
    {
        IReadOnlyList<string>? loaded = null;
        if (!await scope.RunAsync(async () => loaded = PowerNowText.Known(await Client.PowerNowActionsAsync()), message) || loaded is null) return;
        actions.Children.Clear();
        if (loaded.Count == 0)
        {
            actions.Children.Add(Note("This server can't turn itself off; it runs as a service that something else starts and stops."));
            return;
        }
        foreach (var action in loaded)
        {
            actions.Children.Add(Value(PowerNowText.Title(action), PowerNowText.Detail(action)));
            actions.Children.Add(Buttons(Button(PowerNowText.Title(action), () => PowerAsync(action), "destructive")));
        }
    }

    private async Task PowerAsync(string action)
    {
        var title = PowerNowText.Title(action);
        if (!await scope.Sheets.ConfirmAsync(title + "?", PowerNowText.Detail(action), title, destructive: true)) return;
        try
        {
            Show((await Client.PowerNowAsync(action)).Message);
        }
        catch (AureliaApiException exception) when (exception.Code == "playback_active")
        {
            if (await scope.Sheets.ConfirmAsync("Someone Is Watching", "Turn it off anyway? Their playback stops.", title, destructive: true))
                await scope.RunAsync(async () => Show((await Client.PowerNowAsync(action, force: true)).Message), message);
        }
        catch (Exception exception) when (exception is AureliaApiException or HttpRequestException)
        {
            Show(exception.Message);
        }
    }

    private void Show(string text)
    {
        message.Text = text;
        message.Foreground = null;
        message.IsVisible = true;
    }
}
