using System.ComponentModel;
using Tarven.Linux.Core.Hosting;
using Tarven.Linux.Core.Moving;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;

namespace Tarven.Linux.Views;

/// <summary>
/// The Mac app's NativeHostSetupView for this computer's server: starting, "Set Up This PC" with the
/// Server Password, the owner's name and the server's name (both already filled in from this
/// computer; the port is chosen by itself), "Welcome Back", the owner's PIN reset, help
/// when the server cannot start, and another Tarven Server already running here. "Move from
/// Another Tarven Server" takes over an existing server instead (docs/SERVER_MOVE.md): the old
/// server picked nearby or typed with its move code, or a moving file with its passphrase; the
/// progress; a folder on this PC for each storage location; and the restart.
/// </summary>
public sealed class HostSetupView : UserControl
{
    private readonly HostSetupModel model;
    private readonly StackPanel body = new() { Spacing = 18, Width = 460, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock error = new() { Foreground = new SolidColorBrush(Color.Parse("#FFB36B")), TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center };
    private HostPhase? shown;
    private readonly Dictionary<Guid, TextBlock> previews = [];
    private ProgressBar? moveBar;
    private TextBlock? moveNote;
    private TextBlock? moveDetail;

    /// <param name="connectToOther">Leaves hosting for the connection screen, prefilled with this computer when another server runs here.</param>
    public HostSetupView(HostSetupModel model, Action<bool> connectToOther)
    {
        this.model = model;
        ConnectToOther = connectToOther;
        Content = ScreenParts.Backdrop(new ScrollViewer
        {
            Content = new StackPanel
            {
                Spacing = 18,
                Margin = new Thickness(40, 70, 40, 40),
                VerticalAlignment = VerticalAlignment.Center,
                Children = { body, error },
            },
        });
        model.PropertyChanged += OnChanged;
        DetachedFromVisualTree += (_, _) => model.PropertyChanged -= OnChanged;
        Build();
    }

    internal HostSetupModel Model => model;

    private Action<bool> ConnectToOther { get; }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        error.Text = model.Error;
        error.IsVisible = model.Error is not null;
        if (e.PropertyName is nameof(HostSetupModel.MoveFraction) or nameof(HostSetupModel.MoveProgress) or nameof(HostSetupModel.StatusMessage)
            && model.Phase == HostPhase.MoveProgress && shown == HostPhase.MoveProgress)
        {
            ShowMoveProgress();
            return;
        }
        if (e.PropertyName == nameof(HostSetupModel.MovePreviews))
        {
            foreach (var (id, text) in previews) text.Text = model.MovePreviews.TryGetValue(id, out var preview) ? preview : "";
            return;
        }
        if (e.PropertyName is nameof(HostSetupModel.Phase) or nameof(HostSetupModel.StatusTitle) or nameof(HostSetupModel.StatusMessage)
            && (shown != model.Phase || model.Phase is HostPhase.Starting or HostPhase.Failed or HostPhase.PortInUse or HostPhase.MoveApplying)) Build();
    }

    private void Build()
    {
        shown = model.Phase;
        error.Text = model.Error;
        error.IsVisible = model.Error is not null;
        body.Children.Clear();
        body.Width = model.Phase == HostPhase.MoveLocations ? 640 : 460;
        previews.Clear();
        switch (model.Phase)
        {
            case HostPhase.MoveStart:
                MoveStart();
                return;
            case HostPhase.MoveProgress:
                MoveProgress();
                return;
            case HostPhase.MoveLocations:
                MoveLocations();
                return;
            case HostPhase.MoveApplying:
                body.Children.Add(ScreenParts.Symbol("IconServer", 50));
                body.Children.Add(new Tarven.Linux.Controls.Spinner { HorizontalAlignment = HorizontalAlignment.Center });
                body.Children.Add(ScreenParts.Title(model.StatusTitle));
                body.Children.Add(ScreenParts.Detail(model.StatusMessage ?? "Tarven applies the moved data. The server restarts in a moment."));
                return;
            case HostPhase.Starting:
                body.Children.Add(ScreenParts.Symbol("IconServer", 50));
                body.Children.Add(new Tarven.Linux.Controls.Spinner { HorizontalAlignment = HorizontalAlignment.Center });
                body.Children.Add(ScreenParts.Title(model.StatusTitle));
                if (model.StatusMessage is { } detail) body.Children.Add(ScreenParts.Detail(detail));
                return;
            case HostPhase.Failed:
                body.Children.Add(ScreenParts.Symbol("IconServer", 50, new SolidColorBrush(Color.Parse("#FF9F0A"))));
                body.Children.Add(ScreenParts.Title("Server Host Needs Attention"));
                body.Children.Add(ScreenParts.Detail(model.StatusMessage ?? "The server could not start."));
                body.Children.Add(Primary("Try Again", model.RetryAsync));
                break;
            case HostPhase.PortInUse:
                body.Children.Add(ScreenParts.Symbol("IconServer", 50));
                body.Children.Add(ScreenParts.Title("Tarven Server Is Already Running"));
                body.Children.Add(ScreenParts.Detail((model.StatusMessage ?? "Another Tarven Server runs on this computer.")
                    + " Connect to it, or stop it (sudo systemctl disable --now tarven) and try again."));
                body.Children.Add(Primary("Connect to It", () =>
                {
                    ConnectToOther(true);
                    return Task.CompletedTask;
                }));
                body.Children.Add(Link("Try Again", model.RetryAsync));
                return;
            case HostPhase.OwnerSetup:
                OwnerSetup();
                break;
            case HostPhase.SignIn:
                SignIn();
                break;
            case HostPhase.ResetPin:
                ResetPin();
                return;
        }
        body.Children.Add(Link("Connect to Another Server", () =>
        {
            ConnectToOther(false);
            return Task.CompletedTask;
        }));
    }

    private void OwnerSetup()
    {
        var password = Secret("Server Password (at least 12 characters)", "Server Password");
        var show = new CheckBox { Content = "Show Password", HorizontalAlignment = HorizontalAlignment.Left };
        show.IsCheckedChanged += (_, _) => password.PasswordChar = show.IsChecked == true ? '\0' : '•';
        var hint = new TextBlock { Text = "Use at least 12 characters.", Foreground = new SolidColorBrush(Color.Parse("#FFB36B")), FontSize = 12, IsVisible = false };
        var name = Field(model.ServerName, "Server name", "Server Name");
        var owner = Field(model.OwnerName, "Your name", "Owner Name");
        name.TextChanged += (_, _) => model.ServerName = name.Text ?? "";
        owner.TextChanged += (_, _) => model.OwnerName = owner.Text ?? "";
        var cont = new Button { Content = "Continue", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, IsDefault = true, IsEnabled = false, Margin = new Thickness(0, 6, 0, 0) };
        AutomationProperties.SetName(cont, "Continue");
        void Check()
        {
            var length = password.Text?.Length ?? 0;
            hint.IsVisible = length is > 0 and < HostSetupModel.MinimumPasswordLength;
            cont.IsEnabled = length >= HostSetupModel.MinimumPasswordLength && !model.IsBusy;
        }
        password.TextChanged += (_, _) => Check();
        cont.Click += async (_, _) =>
        {
            cont.IsEnabled = false;
            await model.SetUpAsync(password.Text ?? "");
            Check();
        };
        body.Children.Add(ScreenParts.Symbol("IconServer", 50));
        body.Children.Add(ScreenParts.Title("Set Up This PC"));
        body.Children.Add(ScreenParts.Detail("Choose a Server Password. It protects the server's settings; everyone who watches gets a profile with a PIN later."));
        body.Children.Add(Labeled("Server Password", new StackPanel { Spacing = 8, Children = { password, show, hint } }));
        body.Children.Add(Labeled("Your Name", owner, "You sign in with it as the server's owner."));
        body.Children.Add(Labeled("Server Name", name, "How your devices show this server."));
        body.Children.Add(cont);
        if (!model.CanMove) return;
        body.Children.Add(new TextBlock { Text = "Already have a Tarven server?", Classes = { "subdued" }, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) });
        body.Children.Add(Chip("Move from Another Tarven Server…", model.BeginMoveAsync,
            "Titles, progress, profiles, settings and every device's sign-in come along. Media files stay where they are."));
    }

    /// <summary>How the old server's data comes: picked nearby or typed with its move code, or a moving file.</summary>
    private void MoveStart()
    {
        var network = new RadioButton { Content = "Over the Network", GroupName = "move-method", IsChecked = true };
        var file = new RadioButton { Content = "From a Moving File", GroupName = "move-method" };
        AutomationProperties.SetName(network, "Over the Network");
        AutomationProperties.SetName(file, "From a Moving File");
        var address = Field("", "192.168.1.20", "Old Server Address");
        var code = Field("", "ABCD-EFGH-JKMN", "Move Code");
        code.TextChanged += (_, _) =>
        {
            var formatted = ServerMoveText.FormatCode(code.Text);
            if (code.Text != formatted)
            {
                code.Text = formatted;
                code.CaretIndex = formatted.Length;
            }
        };
        var nearby = new StackPanel { Spacing = 6 };
        void ShowNearby()
        {
            nearby.Children.Clear();
            var servers = model.NearbyServers;
            if (servers.Count == 0) nearby.Children.Add(new TextBlock { Text = "No Tarven server found nearby. Type the old server's address instead.", Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap });
            foreach (var server in servers)
            {
                var pick = new Button { Content = $"{server.Name} · {server.Address.Host}", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Stretch };
                AutomationProperties.SetName(pick, "Use " + server.Name);
                pick.Click += (_, _) => address.Text = server.Address.GetLeftPart(UriPartial.Authority);
                nearby.Children.Add(pick);
            }
        }
        ShowNearby();
        var searchAgain = new Button { Content = "Search Again", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Left };
        searchAgain.Click += (_, _) => ShowNearby();
        var networkPart = new StackPanel
        {
            Spacing = 14,
            Children =
            {
                Labeled("Servers Nearby", new StackPanel { Spacing = 6, Children = { nearby, searchAgain } }),
                Labeled("Old Server's Address", address, "Pick it above, or type the address the old server's Move window shows."),
                Labeled("Move Code", code, "The 12 characters the old server shows. A code works once and for 15 minutes."),
            },
        };
        IStorageFile? chosen = null;
        var fileName = new TextBlock { Text = "No file chosen.", Classes = { "subdued" }, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
        var choose = new Button { Content = "Choose Moving File…", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetName(choose, "Choose Moving File");
        choose.Click += async (_, _) =>
        {
            var storage = TopLevel.GetTopLevel(this)?.StorageProvider;
            if (storage is null) return;
            var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = false, Title = "Choose the Moving File" });
            if (files.Count == 0) return;
            chosen = files[0];
            fileName.Text = chosen.Name;
        };
        var passphrase = Secret("Passphrase", "Passphrase");
        var filePart = new StackPanel
        {
            Spacing = 14,
            IsVisible = false,
            Children =
            {
                Labeled("Moving File", new StackPanel { Spacing = 6, Children = { choose, fileName } }, "The file the old server saved, for example on a USB stick."),
                Labeled("Passphrase", passphrase, "The passphrase chosen when the moving file was saved."),
            },
        };
        network.IsCheckedChanged += (_, _) =>
        {
            networkPart.IsVisible = network.IsChecked == true;
            filePart.IsVisible = network.IsChecked != true;
        };
        var start = new Button { Content = "Start Move", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, IsDefault = true };
        start.Click += async (_, _) =>
        {
            start.IsEnabled = false;
            try
            {
                if (network.IsChecked == true)
                {
                    await model.StartNetworkMoveAsync(address.Text ?? "", code.Text ?? "");
                }
                else if (chosen is null)
                {
                    error.Text = "Choose the moving file.";
                    error.IsVisible = true;
                }
                else
                {
                    Stream stream;
                    try
                    {
                        stream = await chosen.OpenReadAsync();
                    }
                    catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
                    {
                        error.Text = "The moving file couldn't be read. Choose it again.";
                        error.IsVisible = true;
                        return;
                    }
                    await using (stream)
                    {
                        await model.StartFileMoveAsync(stream, passphrase.Text ?? "");
                    }
                    passphrase.Text = "";
                }
            }
            finally
            {
                start.IsEnabled = true;
            }
        };
        body.Children.Add(ScreenParts.Symbol("IconServer", 50));
        body.Children.Add(ScreenParts.Title("Move from Another Tarven Server"));
        body.Children.Add(ScreenParts.Detail("This PC's server takes over the old one: its library, profiles, settings and identity. Devices switch on their own. "
            + "On the old server, choose Settings › Server › Move to a New Server… first."));
        body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18, HorizontalAlignment = HorizontalAlignment.Center, Children = { network, file } });
        body.Children.Add(networkPart);
        body.Children.Add(filePart);
        body.Children.Add(start);
        body.Children.Add(Link("Back", model.CancelMoveAsync));
    }

    /// <summary>The old server's data arriving, with its size once known.</summary>
    private void MoveProgress()
    {
        moveBar = new ProgressBar { Minimum = 0, Maximum = 1, Height = 6, Width = 360, HorizontalAlignment = HorizontalAlignment.Center };
        AutomationProperties.SetName(moveBar, "Move Progress");
        moveNote = new TextBlock { Classes = { "subdued" }, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };
        moveDetail = ScreenParts.Detail("");
        body.Children.Add(ScreenParts.Symbol("IconServer", 50));
        body.Children.Add(ScreenParts.Title(model.StatusTitle));
        body.Children.Add(moveDetail);
        body.Children.Add(moveBar);
        body.Children.Add(moveNote);
        body.Children.Add(Link("Cancel Move", model.CancelMoveAsync));
        ShowMoveProgress();
    }

    private void ShowMoveProgress()
    {
        if (moveBar is null || moveNote is null || moveDetail is null) return;
        moveBar.IsIndeterminate = model.MoveFraction is null;
        moveBar.Value = model.MoveFraction ?? 0;
        moveNote.Text = model.MoveProgress;
        moveDetail.Text = model.StatusMessage ?? "Receiving the data from the old server. Keep both servers on.";
    }

    /// <summary>One card per storage location: its best folder on this PC, the others, another folder, or Later.</summary>
    private void MoveLocations()
    {
        body.Children.Add(ScreenParts.Symbol("IconLibrary", 50));
        body.Children.Add(ScreenParts.Title(model.StatusTitle));
        if (model.StatusMessage is { } detail) body.Children.Add(ScreenParts.Detail(detail));
        if (model.MoveLocations.Count == 0)
            body.Children.Add(ScreenParts.Detail("The old server had no storage locations."));
        foreach (var location in model.MoveLocations) body.Children.Add(LocationCard(location));
        var finish = new Button { Content = "Finish Move", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, IsDefault = true };
        finish.Click += async (_, _) =>
        {
            finish.IsEnabled = false;
            await model.FinishMoveAsync();
            finish.IsEnabled = true;
        };
        body.Children.Add(finish);
        body.Children.Add(Link("Cancel Move", model.CancelMoveAsync));
    }

    private Border LocationCard(SetupMoveLocation location)
    {
        var group = "move-location-" + location.Id.ToString("N");
        var options = new StackPanel { Spacing = 8 };
        var current = model.MoveChoices.TryGetValue(location.Id, out var choice) ? choice : ServerMoveText.InitialChoice(location);
        foreach (var suggestion in ServerMoveText.Ranked(location.Suggestions))
        {
            var radio = new RadioButton
            {
                GroupName = group,
                IsChecked = current.Kind == MoveChoiceKind.Suggestion && current.Path == suggestion.Path,
                Content = new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock { Text = suggestion.Path, FontFamily = new FontFamily("monospace"), TextWrapping = TextWrapping.Wrap },
                        new TextBlock { Text = ServerMoveText.MatchText(suggestion.Matched, location.Sampled), Classes = { "subdued" }, FontSize = 12 },
                    },
                },
            };
            AutomationProperties.SetName(radio, $"{location.Name}: {suggestion.Path}");
            radio.IsCheckedChanged += (_, _) =>
            {
                if (radio.IsChecked == true) model.ChooseMoveFolder(location.Id, new MoveChoice(MoveChoiceKind.Suggestion, suggestion.Path));
            };
            options.Children.Add(radio);
        }
        var other = new RadioButton { GroupName = group, Content = "Another folder", IsChecked = current.Kind == MoveChoiceKind.Folder };
        AutomationProperties.SetName(other, $"{location.Name}: Another folder");
        var path = Field(current.Kind == MoveChoiceKind.Folder ? current.Path ?? "" : "", "/path/on/this/PC", $"Other Folder for {location.Name}");
        path.FontFamily = new FontFamily("monospace");
        var result = new TextBlock { Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        result.Text = model.MovePreviews.TryGetValue(location.Id, out var shownPreview) ? shownPreview : "";
        previews[location.Id] = result;
        other.IsCheckedChanged += (_, _) =>
        {
            if (other.IsChecked == true) model.ChooseMoveFolder(location.Id, new MoveChoice(MoveChoiceKind.Folder, path.Text));
        };
        path.TextChanged += (_, _) =>
        {
            // The toolkit reports a change later; a folder just chosen and previewed stays as it is.
            if (string.IsNullOrEmpty(path.Text)
                || model.MoveChoices.TryGetValue(location.Id, out var chosen) && chosen.Kind == MoveChoiceKind.Folder && chosen.Path == path.Text.Trim()) return;
            other.IsChecked = true;
            model.ChooseMoveFolder(location.Id, new MoveChoice(MoveChoiceKind.Folder, path.Text));
            result.Text = "";
        };
        var browse = new Button { Content = "Choose…", Classes = { "chip" } };
        AutomationProperties.SetName(browse, $"Choose Folder for {location.Name}");
        browse.Click += async (_, _) =>
        {
            var storage = TopLevel.GetTopLevel(this)?.StorageProvider;
            if (storage is null) return;
            var folders = await storage.OpenFolderPickerAsync(new FolderPickerOpenOptions { AllowMultiple = false, Title = $"Folder for {location.Name}" });
            if (folders.Count == 0 || folders[0].TryGetLocalPath() is not { } local) return;
            path.Text = local;
            await model.PreviewMoveFolderAsync(location.Id, local);
        };
        var preview = new Button { Content = "Preview", Classes = { "chip" } };
        AutomationProperties.SetName(preview, $"Preview Folder for {location.Name}");
        preview.Click += async (_, _) => await model.PreviewMoveFolderAsync(location.Id, path.Text ?? "");
        options.Children.Add(other);
        options.Children.Add(new DockPanel
        {
            Margin = new Thickness(26, 0, 0, 0),
            Children =
            {
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(8, 0, 0, 0), Children = { browse, preview } }
                    .Also(p => DockPanel.SetDock(p, Dock.Right)),
                path,
            },
        });
        options.Children.Add(result.Also(r => r.Margin = new Thickness(26, 0, 0, 0)));
        var later = new RadioButton
        {
            GroupName = group,
            IsChecked = current.Kind == MoveChoiceKind.Later,
            Content = new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    new TextBlock { Text = "Later" },
                    new TextBlock { Text = "The location stays offline with its titles until Storage Location Moved… points it at the new folder.", Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap },
                },
            },
        };
        AutomationProperties.SetName(later, $"{location.Name}: Later");
        later.IsCheckedChanged += (_, _) =>
        {
            if (later.IsChecked == true) model.ChooseMoveFolder(location.Id, MoveChoice.Later);
        };
        options.Children.Add(later);
        return new Border
        {
            Classes = { "card" },
            Padding = new Thickness(16, 12),
            Child = new StackPanel
            {
                Spacing = 6,
                Children =
                {
                    new TextBlock { Text = location.Name, FontSize = 16, FontWeight = FontWeight.SemiBold },
                    new TextBlock { Text = "Was " + (location.OldPath ?? ""), Classes = { "subdued" }, FontSize = 12, FontFamily = new FontFamily("monospace"), TextWrapping = TextWrapping.Wrap },
                    options,
                },
            },
        };
    }

    /// <summary>A field with its name above and an optional hint below, as in the Mac's setup sheets.</summary>
    private static StackPanel Labeled(string label, Control field, string? hint = null)
    {
        var panel = new StackPanel { Spacing = 6, Children = { new TextBlock { Text = label, FontSize = 13, FontWeight = FontWeight.SemiBold, Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)) }, field } };
        if (hint is not null) panel.Children.Add(new TextBlock { Text = hint, Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        return panel;
    }

    private void SignIn()
    {
        var owner = Field(model.OwnerName, "Owner name", "Owner Name");
        var password = Secret("Server Password", "Server Password");
        owner.TextChanged += (_, _) => model.OwnerName = owner.Text ?? "";
        var sign = new Button { Content = "Sign In", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, IsDefault = true };
        sign.Click += async (_, _) =>
        {
            if (string.IsNullOrEmpty(owner.Text) || string.IsNullOrEmpty(password.Text)) return;
            sign.IsEnabled = false;
            await model.SignInAsync(password.Text);
            sign.IsEnabled = true;
        };
        body.Children.Add(ScreenParts.Symbol("IconServer", 50));
        body.Children.Add(ScreenParts.Title("Welcome Back"));
        body.Children.Add(ScreenParts.Detail(model.MovedIn
            ? "The move is done. Sign in with the owner name and Server Password of the server you moved."
            : "Sign in to the Tarven server already stored on this PC."));
        body.Children.Add(owner);
        body.Children.Add(password);
        body.Children.Add(sign);
    }

    private void ResetPin()
    {
        var password = Secret("Server Password", "Server Password");
        var pin = Secret("New owner PIN (4–8 digits)", "New PIN");
        var confirm = Secret("Confirm PIN", "Confirm PIN");
        pin.MaxLength = confirm.MaxLength = 8;
        var save = new Button { Content = "Set New PIN", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, IsDefault = true };
        save.Click += async (_, _) =>
        {
            save.IsEnabled = false;
            await model.ResetPinAsync(password.Text ?? "", pin.Text ?? "", confirm.Text ?? "");
            save.IsEnabled = true;
        };
        body.Children.Add(ScreenParts.Symbol("IconPerson", 50));
        body.Children.Add(ScreenParts.Title("Reset Owner PIN"));
        body.Children.Add(ScreenParts.Detail("Enter the Server Password of this PC's server and choose a new PIN for the owner's profile."));
        body.Children.Add(password);
        body.Children.Add(pin);
        body.Children.Add(confirm);
        body.Children.Add(save);
        body.Children.Add(Link("Cancel", () =>
        {
            model.CancelPinReset();
            return Task.CompletedTask;
        }));
    }

    private static TextBox Field(string text, string placeholder, string name)
    {
        var box = new TextBox { Text = text, PlaceholderText = placeholder };
        AutomationProperties.SetName(box, name);
        return box;
    }

    private static TextBox Secret(string placeholder, string name)
    {
        var box = new TextBox { PasswordChar = '•', PlaceholderText = placeholder };
        AutomationProperties.SetName(box, name);
        return box;
    }

    private static Button Primary(string label, Func<Task> action)
    {
        var button = new Button { Content = label, Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center };
        button.Click += async (_, _) => await action();
        return button;
    }

    /// <summary>A secondary choice with a line that explains it.</summary>
    private static StackPanel Chip(string label, Func<Task> action, string detail)
    {
        var button = new Button { Content = label, Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Center };
        AutomationProperties.SetName(button, label);
        button.Click += async (_, _) => await action();
        return new StackPanel
        {
            Spacing = 4,
            Children =
            {
                button,
                new TextBlock { Text = detail, Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center },
            },
        };
    }

    private static Button Link(string label, Func<Task> action)
    {
        var button = new Button { Content = label, Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        button.Click += async (_, _) => await action();
        return button;
    }
}
