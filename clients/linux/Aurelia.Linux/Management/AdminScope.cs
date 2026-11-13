using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Library;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Management;

/// <summary>
/// What every management screen shares: the client for owner and administrator requests, the
/// Server Password prompt it opens when management is locked, and plain messages for failures.
/// </summary>
public sealed class AdminScope
{
    private readonly AppSession session;

    public AdminScope(AppSession session, SheetHost sheets)
    {
        this.session = session;
        Sheets = sheets;
        var library = session.Library ?? throw new InvalidOperationException("Open a profile first.");
        Client = new ManagementClient(session.Api, library.Client, AskPasswordAsync, ConfirmElsewhereAsync);
    }

    public ManagementClient Client { get; private set; }

    public void RefreshClient() => Client = new ManagementClient(session.Api,
        (session.Library ?? throw new InvalidOperationException("Open a profile first.")).Client, AskPasswordAsync, ConfirmElsewhereAsync);

    public SheetHost Sheets { get; }

    public AppSession Session => session;

    public UserSummary User => Client.Library.Profile.User;

    public bool IsOwner => User.Role == UserRole.Owner;

    /// <summary>An owner, or an administrator who manages the whole library rather than selected titles.</summary>
    public bool CanManageStorage => IsOwner || (User.Role == UserRole.Admin && User.AccessMode != ProfileAccessMode.SelectedTitles);

    public string ServerName => session.Server?.Name ?? "Aurelia";

    /// <summary>Runs an action and shows its failure in <paramref name="message"/>; true when it worked.</summary>
    public async Task<bool> RunAsync(Func<Task> action, TextBlock? message = null)
    {
        if (message is not null) message.IsVisible = false;
        try
        {
            await action();
            return true;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
        catch (Exception failure) when (failure is AureliaApiException or HttpRequestException)
        {
            if (failure is AureliaApiException { Status: 401 } expired && expired.Code != "invalid_credentials")
            {
                session.HandleSessionFailure(expired);
                return false;
            }
            if (message is not null)
            {
                message.Text = Describe(failure);
                message.IsVisible = true;
            }
            return false;
        }
    }

    public static string Describe(Exception failure) => failure switch
    {
        AureliaApiException { Code: "management_locked" } => "Management is locked. Enter the Server Password to continue.",
        AureliaApiException { Code: "invalid_password" or "invalid_credentials" } => "The Server Password is not correct.",
        AureliaApiException { Code: "passkey_required" } => "Face ID or Touch ID is required to manage this server. Confirm on an iPhone, iPad or Mac.",
        AureliaApiException { Code: "device_blocked" } => "The owner has blocked this device.",
        AureliaApiException { Status: 403 } api when api.Code is "forbidden" or "owner_required" => "Only the server's owner can do this.",
        AureliaApiException api => api.Message,
        _ => "The server could not be reached. Check that it is running and try again.",
    };

    /// <summary>
    /// The Server Password prompt. Unlike the Mac app's, it does not claim a network trial: it
    /// appears whenever the server asks for the password before a protected change.
    /// </summary>
    private async Task<string?> AskPasswordAsync(string reason)
    {
        var password = new TextBox { PasswordChar = '•', PlaceholderText = "Server Password", Width = 360 };
        AutomationProperties.SetName(password, "Server Password");
        var unlock = new Button { Content = "Unlock", Classes = { "primary" }, IsDefault = true };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        unlock.Click += (_, _) => Sheets.Close(!string.IsNullOrEmpty(password.Text));
        cancel.Click += (_, _) => Sheets.Close(false);
        var entered = await Sheets.ShowAsync(new StackPanel
        {
            Spacing = 14,
            Width = 420,
            Children =
            {
                new TextBlock { Text = "Unlock Server Management", FontSize = 18, FontWeight = FontWeight.Bold },
                new TextBlock
                {
                    Text = $"Enter the Server Password for {ServerName} to unlock management for ten minutes. Your Profile PIN cannot unlock management.",
                    Classes = { "subdued" },
                    TextWrapping = TextWrapping.Wrap,
                },
                password,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, unlock } },
            },
        });
        return entered ? password.Text : null;
    }

    /// <summary>
    /// "Confirm on Another Device": when Face ID or Touch ID is required for administrators, an
    /// iPhone, iPad or Mac of this profile (or the owner's) confirms, and this computer waits.
    /// </summary>
    internal async Task<bool> ConfirmElsewhereAsync(ManagementClient client)
    {
        RemoteUnlockStartResponse request;
        try
        {
            request = await client.StartRemoteUnlockAsync();
        }
        catch (AureliaApiException)
        {
            return false;
        }
        using var waiting = new CancellationTokenSource(request.ExpiresAt - DateTimeOffset.UtcNow + TimeSpan.FromSeconds(5));
        var status = new TextBlock { Text = SecurityText.RemoteUnlockState("pending"), Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => Sheets.Close(false);
        var sheet = new StackPanel
        {
            Spacing = 14,
            Width = 420,
            Children =
            {
                new TextBlock { Text = "Confirm on Another Device", FontSize = 18, FontWeight = FontWeight.Bold },
                new TextBlock
                {
                    Text = $"{ServerName} requires Face ID or Touch ID to manage it. Confirm on an iPhone, iPad or Mac where you set it up, and check that it shows this code:",
                    Classes = { "subdued" },
                    TextWrapping = TextWrapping.Wrap,
                },
                new TextBlock { Text = request.Code, FontSize = 40, FontWeight = FontWeight.Bold, HorizontalAlignment = HorizontalAlignment.Center }
                    .Also(code => AutomationProperties.SetName(code, "Confirmation code " + request.Code)),
                status,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel } },
            },
        };
        var shown = Sheets.ShowAsync(sheet);
        var answered = client.WaitForRemoteUnlockAsync(request.Id, TimeSpan.FromSeconds(2), waiting.Token);
        var first = await Task.WhenAny(shown, answered);
        if (first == shown)
        {
            await waiting.CancelAsync();
            return false;
        }
        bool approved;
        try
        {
            approved = await answered;
        }
        catch (Exception failure) when (failure is OperationCanceledException or AureliaApiException or HttpRequestException)
        {
            approved = false;
        }
        if (approved)
        {
            Sheets.Close(true);
            return true;
        }
        status.Text = SecurityText.RemoteUnlockState(waiting.IsCancellationRequested ? "expired" : "denied");
        cancel.Content = "Close";
        await shown;
        return false;
    }

    public static TextBlock Message() => new()
    {
        IsVisible = false,
        TextWrapping = TextWrapping.Wrap,
        Foreground = new SolidColorBrush(Color.Parse("#FFB36B")),
    };

    public static TextBlock Note(string text) => new() { Text = text, Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap };

    public static string Bytes(long bytes)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }
        return unit == 0 ? $"{bytes} bytes" : value.ToString(value >= 100 ? "0" : "0.#", System.Globalization.CultureInfo.InvariantCulture) + " " + units[unit];
    }

    public static string Date(DateTimeOffset value) => value.ToLocalTime().ToString("d MMM yyyy, HH:mm", System.Globalization.CultureInfo.InvariantCulture);

    public static string Duration(double seconds)
    {
        var span = TimeSpan.FromSeconds(Math.Max(60, seconds));
        if (span.TotalDays >= 1) return $"{(int)span.TotalDays} {Plural((int)span.TotalDays, "day")}, {span.Hours} {Plural(span.Hours, "hour")}";
        if (span.TotalHours >= 1) return $"{(int)span.TotalHours} {Plural((int)span.TotalHours, "hour")}, {span.Minutes} {Plural(span.Minutes, "minute")}";
        return $"{span.Minutes} {Plural(span.Minutes, "minute")}";
    }

    private static string Plural(int count, string word) => count == 1 ? word : word + "s";

    /// <summary>A row of buttons, used under the management sections.</summary>
    public static WrapPanel Buttons(params Control[] buttons)
    {
        var panel = new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 8, LineSpacing = 8 };
        foreach (var button in buttons) panel.Children.Add(button);
        return panel;
    }

    /// <summary>A padded block inside a settings section.</summary>
    public static StackPanel Block(params Control[] children)
    {
        var panel = new StackPanel { Spacing = 10, Margin = new Thickness(16, 12) };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    public static Button Button(string label, Func<Task> action, string classes = "chip")
    {
        var button = new Button { Content = label, Classes = { classes } };
        button.Click += async (_, _) =>
        {
            button.IsEnabled = false;
            try
            {
                await action();
            }
            finally
            {
                button.IsEnabled = true;
            }
        };
        return button;
    }
}
