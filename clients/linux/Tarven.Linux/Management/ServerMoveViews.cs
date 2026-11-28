using Tarven.Contracts;
using Tarven.Linux.Core.Api;
using Tarven.Linux.Core.Management;
using Tarven.Linux.Core.Moving;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using static Tarven.Linux.Management.AdminScope;
using static Tarven.Linux.Settings.SettingsRows;

namespace Tarven.Linux.Management;

/// <summary>
/// Settings › Server › Move to a New Server (owner, docs/SERVER_MOVE.md), as on the Mac and in the
/// browser: the move's state and the actions that fit it. Over the network this server shows a
/// one-use code with its countdown; a moving file is saved with a passphrase typed twice. A waiting
/// move can be cancelled, a moving file marked as moved, and a finished move undone after
/// confirming that the new server is off.
/// </summary>
public sealed class ServerMoveSection : StackPanel
{
    private readonly AdminScope scope;
    private readonly IReadOnlyList<string> addresses;
    private readonly TextBlock summary = Note("Checking…");
    private readonly WrapPanel actions = Buttons();
    private readonly TextBlock message = Message();

    /// <param name="addresses">This server's network addresses, for the new server to type.</param>
    public ServerMoveSection(AdminScope scope, IReadOnlyList<string>? addresses = null)
    {
        this.scope = scope;
        this.addresses = addresses ?? [];
        Children.Add(Section("Move to a New Server", Block(
            Note("Takes this server to another computer: titles, progress, favorites, collections, profiles, settings, its identity and every device's sign-in. Media files are never copied; on the new computer each storage location is pointed at its folder."),
            summary, actions, message)));
        Loading = ReloadAsync();
    }

    internal Task Loading { get; private set; }

    internal ServerMoveStatus? Status { get; private set; }

    private ManagementClient Client => scope.Client;

    public Task ReloadAsync() => Loading = LoadAsync();

    private async Task LoadAsync()
    {
        var unsupported = false;
        await scope.RunAsync(async () =>
        {
            try
            {
                Status = await Client.ServerMoveAsync();
            }
            catch (TarvenApiException failure) when (failure.Status == 404 && failure.Code is null or "http_404")
            {
                unsupported = true;
            }
        }, message);
        if (unsupported)
        {
            summary.Text = "This server's version can't move to another computer yet. Update it first.";
            actions.Children.Clear();
            return;
        }
        Show(Status);
    }

    internal void Show(ServerMoveStatus? status)
    {
        Status = status;
        var view = ServerMoveText.OwnerView(status, DateTimeOffset.UtcNow);
        summary.Text = view.Summary;
        actions.Children.Clear();
        foreach (var action in view.Actions)
        {
            actions.Children.Add(action switch
            {
                ServerMoveAction.Start => Named(Button("Move to a New Server…", MoveAsync), "Move to a New Server"),
                ServerMoveAction.NewCode => Named(Button("New Move Code…", MoveAsync, "primary"), "New Move Code"),
                ServerMoveAction.Cancel => Named(Button("Cancel Move", CancelAsync), "Cancel Move"),
                ServerMoveAction.MarkMoved => Named(Button("Mark as Moved…", MarkMovedAsync), "Mark as Moved"),
                _ => Named(Button("Undo Move…", UndoAsync, "destructive"), "Undo Move"),
            });
        }
    }

    private static Button Named(Button button, string name)
    {
        AutomationProperties.SetName(button, name);
        return button;
    }

    private async Task MoveAsync()
    {
        await scope.Sheets.ShowAsync(new MoveServerSheet(scope, addresses));
        await ReloadAsync();
    }

    private async Task CancelAsync()
    {
        if (!await scope.Sheets.ConfirmAsync("Cancel the move?", "The move code or moving file stops working. This server stays as it is.", "Cancel Move", destructive: false)) return;
        if (await scope.RunAsync(Client.EndMoveAsync, message)) await ReloadAsync();
    }

    private async Task MarkMovedAsync()
    {
        if (!await scope.Sheets.ConfirmAsync("Mark this server as moved?",
            "Use this when the new server runs with the moving file but couldn't reach this one. This server then stops offering itself on the network and sends devices to the new one.",
            "Mark as Moved", destructive: true)) return;
        ServerMoveStatus? moved = null;
        if (await scope.RunAsync(async () => moved = await Client.MarkMovedAsync(), message)) Show(moved);
    }

    private async Task UndoAsync()
    {
        if (await scope.Sheets.ShowAsync(new UndoMoveSheet(scope))) await ReloadAsync();
    }
}

/// <summary>Move to a New Server…: over the network with a code, or with a moving file.</summary>
public sealed class MoveServerSheet : UserControl
{
    private readonly AdminScope scope;
    private readonly IReadOnlyList<string> addresses;
    private readonly StackPanel body = new() { Spacing = 14 };
    private readonly TextBlock message = Message();
    private readonly DispatcherTimer tick;
    private readonly DispatcherTimer watch;
    private ServerMoveStarted? started;
    private TextBlock? code;
    private TextBlock? left;
    private TextBlock? state;

    public MoveServerSheet(AdminScope scope, IReadOnlyList<string> addresses)
    {
        this.scope = scope;
        this.addresses = addresses;
        Width = 480;
        tick = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => ShowCountdown());
        watch = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, async (_, _) => await WatchAsync());
        DetachedFromVisualTree += (_, _) =>
        {
            tick.Stop();
            watch.Stop();
        };
        var close = new Button { Content = "Close", Classes = { "chip" }, IsCancel = true };
        close.Click += (_, _) => scope.Sheets.Close(true);
        Content = new StackPanel
        {
            Spacing = 14,
            Children =
            {
                new TextBlock { Text = "Move to a New Server", FontSize = 18, FontWeight = FontWeight.Bold },
                body,
                message,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { close } },
            },
        };
        Choose();
    }

    /// <summary>The code being shown, for tests.</summary>
    internal string? Code => code?.Text;

    internal Task Working { get; private set; } = Task.CompletedTask;

    private void Choose()
    {
        body.Children.Clear();
        body.Children.Add(new TextBlock
        {
            Text = "Everything but the media files moves. On the new computer, choose Move from Another Tarven Server while setting it up.",
            Classes = { "subdued" },
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(Choice("Over the Network", "Both servers are on. This server shows a code that you type on the new one.", () => Working = NetworkAsync()));
        body.Children.Add(Choice("With a Moving File", "An encrypted file for a USB stick or a network share, protected by a passphrase.", MovingFile));
    }

    private static Button Choice(string title, string detail, Action chosen)
    {
        var button = new Button
        {
            Classes = { "chip" },
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Content = new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    new TextBlock { Text = title, FontWeight = FontWeight.SemiBold },
                    new TextBlock { Text = detail, Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap },
                },
            },
        };
        AutomationProperties.SetName(button, title);
        button.Click += (_, _) => chosen();
        return button;
    }

    private async Task NetworkAsync()
    {
        tick.Stop();
        watch.Stop();
        body.Children.Clear();
        code = new TextBlock { Text = "…", FontSize = 36, FontWeight = FontWeight.Bold, HorizontalAlignment = HorizontalAlignment.Center, FontFamily = new FontFamily("monospace") };
        AutomationProperties.SetName(code, "Move Code");
        left = new TextBlock { Classes = { "subdued" }, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };
        state = new TextBlock { TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center };
        var where = addresses.Count > 0
            ? $"On the new server, pick this server nearby or type its address ({string.Join(", ", addresses.Take(3))}), then this code."
            : "On the new server, pick this server nearby or type its address, then this code.";
        body.Children.Add(new TextBlock { Text = where, Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap });
        body.Children.Add(code);
        body.Children.Add(left);
        body.Children.Add(state);
        body.Children.Add(Buttons(Button("New Code", NetworkAsync)));
        ServerMoveStarted? answer = null;
        if (!await scope.RunAsync(async () => answer = await scope.Client.StartNetworkMoveAsync(), message) || answer is null) return;
        started = answer;
        code.Text = ServerMoveText.FormatCode(answer.Code);
        state.Text = "Waiting for the new server…";
        ShowCountdown();
        tick.Start();
        watch.Start();
    }

    private void ShowCountdown()
    {
        if (left is null || started?.ExpiresAt is not { } expires) return;
        var remaining = expires - DateTimeOffset.UtcNow;
        if (remaining > TimeSpan.Zero)
        {
            left.Text = $"The code works once, for {ServerMoveText.Countdown(remaining)}.";
            return;
        }
        left.Text = "This code has expired. Choose New Code.";
        if (code is not null) code.Opacity = 0.4;
        tick.Stop();
    }

    /// <summary>Follows the move while the code shows: the new server receiving, then moved.</summary>
    internal async Task WatchAsync()
    {
        if (state is null) return;
        ServerMoveStatus status;
        try
        {
            status = await scope.Client.ServerMoveAsync();
        }
        catch (Exception failure) when (failure is TarvenApiException or HttpRequestException)
        {
            return;
        }
        switch (status.State)
        {
            case "transferring":
                state.Text = "The new server is receiving the data…";
                break;
            case "moved":
                tick.Stop();
                watch.Stop();
                if (code is not null) code.Opacity = 0.4;
                if (left is not null) left.Text = "";
                state.Text = ServerMoveText.OwnerView(status, DateTimeOffset.UtcNow).Summary;
                break;
            case "none":
                tick.Stop();
                watch.Stop();
                state.Text = "The move was cancelled.";
                break;
        }
    }

    private void MovingFile()
    {
        body.Children.Clear();
        var first = new TextBox { PasswordChar = '•', PlaceholderText = "Passphrase (at least 12 characters)" };
        var second = new TextBox { PasswordChar = '•', PlaceholderText = "Repeat passphrase" };
        AutomationProperties.SetName(first, "Moving File Passphrase");
        AutomationProperties.SetName(second, "Repeat Moving File Passphrase");
        var save = Button("Save Moving File…", async () =>
        {
            message.IsVisible = false;
            if ((first.Text?.Length ?? 0) < 12 || first.Text != second.Text)
            {
                message.Text = "Enter the same passphrase twice, with at least 12 characters.";
                message.IsVisible = true;
                return;
            }
            var storage = TopLevel.GetTopLevel(this)?.StorageProvider;
            if (storage is null) return;
            var file = await storage.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Save Moving File",
                SuggestedFileName = $"Tarven-Move-{DateTime.Now:yyyy-MM-dd}.tarvenmove",
            });
            if (file is null) return;
            var passphrase = first.Text!;
            var saved = await scope.RunAsync(async () =>
            {
                await using var stream = await file.OpenWriteAsync();
                await scope.Client.SaveMovingFileAsync(passphrase, stream);
            }, message);
            if (!saved) return;
            first.Text = second.Text = "";
            body.Children.Clear();
            body.Children.Add(new TextBlock { Text = "Moving file saved. Set up the new server, choose Move from Another Tarven Server and open this file with its passphrase.", TextWrapping = TextWrapping.Wrap });
            body.Children.Add(Note("When the new server can reach this one, this server learns about the move by itself. Otherwise choose Mark as Moved here afterwards."));
        }, "primary");
        AutomationProperties.SetName(save, "Save Moving File");
        body.Children.Add(new TextBlock { Text = "The moving file holds the whole server, encrypted with your passphrase. Media files are not included.", Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap });
        body.Children.Add(first);
        body.Children.Add(second);
        body.Children.Add(Note("Tarven can't recover the passphrase."));
        body.Children.Add(save);
    }
}

/// <summary>Undo Move: this server takes back its library and identity, once the new server is off.</summary>
public sealed class UndoMoveSheet : UserControl
{
    public UndoMoveSheet(AdminScope scope)
    {
        Width = 460;
        var message = Message();
        var off = new CheckBox { Content = "The new server is turned off" };
        AutomationProperties.SetName(off, "The new server is turned off");
        var undo = new Button { Content = "Undo Move", Classes = { "destructive" }, IsEnabled = false };
        AutomationProperties.SetName(undo, "Undo Move");
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        off.IsCheckedChanged += (_, _) => undo.IsEnabled = off.IsChecked == true;
        cancel.Click += (_, _) => scope.Sheets.Close(false);
        undo.Click += async (_, _) =>
        {
            if (off.IsChecked != true) return;
            undo.IsEnabled = false;
            if (await scope.RunAsync(scope.Client.EndMoveAsync, message)) scope.Sheets.Close(true);
            else undo.IsEnabled = true;
        };
        Content = new StackPanel
        {
            Spacing = 14,
            Children =
            {
                new TextBlock { Text = "Undo the Move", FontSize = 18, FontWeight = FontWeight.Bold },
                new TextBlock
                {
                    Text = "This server takes back its library and identity. Two copies of the same server must never run at once: turn the new server off first. Changes made on the new server since the move are not brought back.",
                    Classes = { "subdued" },
                    TextWrapping = TextWrapping.Wrap,
                },
                off,
                message,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, undo } },
            },
        };
    }
}

/// <summary>
/// Storage Location Moved…: the server's suggestions for where a location's files are now, another
/// folder picked on the server and previewed, and the confirmation. A folder without any matching
/// sample file needs a second, explicit confirmation.
/// </summary>
public sealed class StorageLocationMovedSheet : UserControl
{
    private readonly AdminScope scope;
    private readonly LibrarySummary library;
    private readonly RelocateModel model = new();
    private readonly StackPanel suggestions = new() { Spacing = 8 };
    private readonly TextBox path = new() { PlaceholderText = "/path/on/the/server", FontFamily = new FontFamily("monospace") };
    private readonly TextBlock result = new() { Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap };
    private readonly CheckBox empty = new() { Content = "No sample file is there. Point the location at this folder anyway.", IsVisible = false };
    private readonly Button confirm = new() { Content = "Move Location", Classes = { "primary" }, IsEnabled = false, IsDefault = true };
    private readonly TextBlock message = Message();

    public StorageLocationMovedSheet(AdminScope scope, LibrarySummary library)
    {
        this.scope = scope;
        this.library = library;
        Width = 560;
        AutomationProperties.SetName(path, "New Folder");
        AutomationProperties.SetName(empty, "Point it there anyway");
        AutomationProperties.SetName(confirm, "Move Location");
        path.TextChanged += (_, _) =>
        {
            // The toolkit reports a change later: a folder just chosen or previewed is not a new one.
            if ((path.Text ?? "") == model.Path) return;
            model.Path = path.Text ?? "";
            empty.IsChecked = false;
            Update();
        };
        empty.IsCheckedChanged += (_, _) =>
        {
            model.ConfirmedEmpty = empty.IsChecked == true;
            Update();
        };
        var browse = Button("Choose Folder…", BrowseAsync);
        AutomationProperties.SetName(browse, "Choose Folder on the Server");
        var preview = Button("Preview", PreviewAsync);
        AutomationProperties.SetName(preview, "Preview Folder");
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => scope.Sheets.Close(false);
        confirm.Click += async (_, _) => await ConfirmAsync();
        Content = new StackPanel
        {
            Spacing = 12,
            Children =
            {
                new TextBlock { Text = $"{library.Name} Moved", FontSize = 18, FontWeight = FontWeight.Bold },
                new TextBlock
                {
                    Text = "When this location's files are now in another folder (a new disk or computer), point it there. Titles, progress and artwork stay; a scan then finds the files by their path. Media files are only read.",
                    Classes = { "subdued" },
                    TextWrapping = TextWrapping.Wrap,
                },
                new TextBlock { Text = "Now: " + library.Path, Classes = { "subdued" }, FontSize = 12, FontFamily = new FontFamily("monospace"), TextWrapping = TextWrapping.Wrap },
                suggestions,
                new DockPanel
                {
                    Children =
                    {
                        new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(8, 0, 0, 0), Children = { browse, preview } }
                            .Also(p => DockPanel.SetDock(p, Dock.Right)),
                        path,
                    },
                },
                result,
                empty,
                message,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, confirm } },
            },
        };
        Update();
        Loading = LoadAsync();
    }

    internal Task Loading { get; }

    internal RelocateModel Model => model;

    private async Task LoadAsync()
    {
        RelocateSuggestions? answer = null;
        await scope.RunAsync(async () => answer = await scope.Client.RelocateSuggestionsAsync(library.Id), message);
        if (answer is null) return;
        model.Load(answer);
        suggestions.Children.Clear();
        if (model.Suggestions.Count == 0)
            suggestions.Children.Add(Note("No folder with these files was found. Choose one yourself."));
        foreach (var suggestion in model.Suggestions)
        {
            var radio = new RadioButton
            {
                GroupName = "relocate-" + library.Id.ToString("N"),
                Content = new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock { Text = suggestion.Path, FontFamily = new FontFamily("monospace"), TextWrapping = TextWrapping.Wrap },
                        new TextBlock { Text = ServerMoveText.MatchText(suggestion.Matched, model.Sampled), Classes = { "subdued" }, FontSize = 12 },
                    },
                },
            };
            AutomationProperties.SetName(radio, "Use " + suggestion.Path);
            radio.IsCheckedChanged += (_, _) =>
            {
                if (radio.IsChecked != true) return;
                model.Choose(suggestion);
                SetPath(suggestion.Path);
                empty.IsChecked = false;
                Update();
            };
            suggestions.Children.Add(radio);
        }
    }

    private void SetPath(string value) => path.Text = value;

    private async Task BrowseAsync()
    {
        var picker = new ServerFolderPicker(scope);
        if (!await scope.Sheets.ShowAsync(picker) || picker.Chosen is not { } chosen) return;
        SetPath(chosen);
        model.Path = chosen;
        await PreviewAsync();
    }

    internal async Task PreviewAsync()
    {
        var folder = (path.Text ?? "").Trim();
        if (folder.Length == 0)
        {
            result.Text = "Choose or type a folder first.";
            return;
        }
        model.Path = folder;
        result.Text = "Comparing…";
        MoveMatch? match = null;
        if (await scope.RunAsync(async () => match = await scope.Client.PreviewRelocationAsync(library.Id, folder), message) && match is not null)
            model.Previewed(folder, match);
        empty.IsChecked = false;
        Update();
    }

    private void Update()
    {
        var decision = model.Decision;
        result.Text = decision.Text;
        empty.IsVisible = decision.NeedsSecondConfirmation;
        confirm.IsEnabled = decision.CanConfirm;
    }

    private async Task ConfirmAsync()
    {
        if (model.Request is not { } request) return;
        // A folder without any matching file: one more, explicit question before it is forced.
        if (request.Force && !await scope.Sheets.ConfirmAsync($"Point {library.Name} at a folder without its files?",
            $"None of the sample files were found in {request.Path}. Its titles stay offline until the files are there.", "Move Location Anyway", destructive: true)) return;
        confirm.IsEnabled = false;
        if (await scope.RunAsync(() => scope.Client.RelocateAsync(library.Id, request.Path, request.Force), message))
        {
            scope.Sheets.Close(true);
            return;
        }
        Update();
    }
}
