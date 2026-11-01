using System.ComponentModel;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Library;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Data;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Library;

/// <summary>
/// Shows one sheet at a time over the window, dimming what is behind it: confirmations and
/// editors. Escape cancels, as Return confirms in the Mac app's sheets.
/// </summary>
public sealed class SheetHost : Panel
{
    // Sheets stack: the Server Password prompt can open above an editor and return to it.
    private readonly Stack<(Control Frame, TaskCompletionSource<bool> Result)> open = new();

    public SheetHost()
    {
        IsVisible = false;
        Background = new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0));
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close(false);
                e.Handled = true;
            }
        };
    }

    public bool IsShowing => IsVisible;

    internal Control? Current => open.Count > 0 ? open.Peek().Frame : null;

    public Task<bool> ShowAsync(Control sheet)
    {
        if (open.Count > 0) open.Peek().Frame.IsVisible = false;
        var frame = new Border
        {
            Classes = { "sheet" },
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Child = sheet,
        };
        var result = new TaskCompletionSource<bool>();
        open.Push((frame, result));
        Children.Add(frame);
        IsVisible = true;
        Avalonia.Threading.Dispatcher.UIThread.Post(() => sheet.GetVisualDescendantsOfType<TextBox>().FirstOrDefault()?.Focus());
        return result.Task;
    }

    /// <summary>Closes the topmost sheet; the one below it, if any, shows again.</summary>
    public void Close(bool result)
    {
        if (open.Count == 0)
        {
            IsVisible = false;
            return;
        }
        var (frame, pending) = open.Pop();
        Children.Remove(frame);
        if (open.Count > 0) open.Peek().Frame.IsVisible = true;
        else IsVisible = false;
        pending.TrySetResult(result);
    }

    /// <summary>A question with a confirm and a Cancel button.</summary>
    public Task<bool> ConfirmAsync(string title, string message, string confirmLabel, bool destructive)
    {
        var confirm = new Button { Content = confirmLabel, Classes = { destructive ? "destructive" : "primary" }, IsDefault = true };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        confirm.Click += (_, _) => Close(true);
        cancel.Click += (_, _) => Close(false);
        return ShowAsync(new StackPanel
        {
            Spacing = 14,
            Width = 420,
            Children =
            {
                new TextBlock { Text = title, FontSize = 18, FontWeight = FontWeight.Bold, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = message, Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap },
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, confirm } },
            },
        });
    }
}

internal static class VisualExtensions
{
    public static IEnumerable<T> GetVisualDescendantsOfType<T>(this Visual visual) where T : Visual =>
        Avalonia.VisualTree.VisualExtensions.GetVisualDescendants(visual).OfType<T>();
}

/// <summary>The collection editor sheet: name, standard or smart, the titles or rules, sharing and delete.</summary>
public sealed class CollectionEditorSheet : UserControl
{
    private readonly CollectionEditorModel model;
    private readonly LibraryContext context;
    private readonly SheetHost host;
    private readonly StackPanel body = new() { Spacing = 12 };
    private readonly TextBlock problem = new() { Foreground = new SolidColorBrush(Color.Parse("#FF8A8A")) };
    private readonly TextBlock preview = new() { Classes = { "subdued" } };
    private readonly Button save = new() { Content = "Save", Classes = { "primary" }, IsDefault = true };
    private string filter = "";

    public CollectionEditorSheet(LibraryContext context, SheetHost host, CollectionSummary? existing, CatalogItemSummary? preselected)
    {
        this.context = context;
        this.host = host;
        model = new CollectionEditorModel(context.Store.Catalog, existing, preselected, context.Store.CanManageMedia);
        DataContext = model;
        Width = 720;
        Height = 640;
        var nameBox = new TextBox { PlaceholderText = "Name" };
        nameBox[!TextBox.TextProperty] = new Binding(nameof(CollectionEditorModel.Name)) { Mode = BindingMode.TwoWay };
        AutomationProperties.SetName(nameBox, "Collection Name");
        var standard = new ToggleButton { Content = "Standard Collection", Classes = { "chip" }, IsChecked = !model.IsSmart };
        var smart = new ToggleButton { Content = "Smart List", Classes = { "chip" }, IsChecked = model.IsSmart };
        standard.Click += (_, _) => { model.IsSmart = false; smart.IsChecked = false; standard.IsChecked = true; BuildBody(); };
        smart.Click += (_, _) => { model.IsSmart = true; standard.IsChecked = false; smart.IsChecked = true; BuildBody(); };
        var shared = new CheckBox { Content = "Shared Collection (visible to all profiles)", IsVisible = model.CanShare };
        shared[!ToggleButton.IsCheckedProperty] = new Binding(nameof(CollectionEditorModel.IsShared)) { Mode = BindingMode.TwoWay };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => host.Close(false);
        save.Click += async (_, _) => await SaveAsync();
        var footer = new DockPanel { LastChildFill = false };
        if (existing is not null)
        {
            var delete = new Button { Content = "Delete Collection", Classes = { "destructive" } };
            delete.Click += async (_, _) =>
            {
                host.Close(false);
                if (await context.Navigator.ConfirmAsync($"Delete “{existing.Name}”?", "The titles stay in the library.", "Delete", destructive: true))
                {
                    await context.Store.DeleteCollectionAsync(existing.Id);
                    context.Navigator.Back();
                }
            };
            footer.Children.Add(delete.Also(d => DockPanel.SetDock(d, Dock.Left)));
        }
        footer.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { cancel, save } }.Also(p => DockPanel.SetDock(p, Dock.Right)));
        Content = new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Spacing = 12,
                    Children =
                    {
                        new TextBlock { Text = existing is null ? "New Collection" : "Edit Collection", FontSize = 20, FontWeight = FontWeight.Bold },
                        nameBox,
                        new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { standard, smart } },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new StackPanel { Spacing = 8, Margin = new Thickness(0, 10, 0, 0), Children = { shared, problem, footer } }.Also(p => DockPanel.SetDock(p, Dock.Bottom)),
                new ScrollViewer { Content = body, Margin = new Thickness(0, 12, 0, 0) },
            },
        };
        model.PropertyChanged += OnModelChanged;
        BuildBody();
        Update();
    }

    internal CollectionEditorModel Model => model;

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Update();

    private void Update()
    {
        problem.Text = model.Problem;
        problem.IsVisible = model.Problem is not null && (model.Name.Length > 0 || model.Selected.Count > 0);
        save.IsEnabled = model.CanSave;
        preview.Text = model.MatchingCount == 1 ? "Matching 1 title" : $"Matching {model.MatchingCount} titles";
    }

    private void BuildBody()
    {
        body.Children.Clear();
        if (model.IsSmart) BuildRules();
        else BuildTitles();
    }

    private void BuildTitles()
    {
        var search = new TextBox { PlaceholderText = "Find titles", Text = filter };
        AutomationProperties.SetName(search, "Find Titles");
        var list = new StackPanel { Spacing = 2 };
        void Fill()
        {
            list.Children.Clear();
            foreach (var selected in model.Selected.ToList())
            {
                var up = new Button { Content = "▲", Classes = { "link" } };
                var down = new Button { Content = "▼", Classes = { "link" } };
                AutomationProperties.SetName(up, "Move Up, " + selected.Title);
                AutomationProperties.SetName(down, "Move Down, " + selected.Title);
                up.Click += (_, _) => { model.Move(selected, -1); Fill(); };
                down.Click += (_, _) => { model.Move(selected, 1); Fill(); };
                list.Children.Add(Row(selected, true, Fill, up, down));
            }
            if (model.Selected.Count > 0) list.Children.Add(new Separator { Margin = new Thickness(0, 6) });
            foreach (var candidate in model.Candidates.Where(c => !model.Contains(c) && (filter.Length == 0 || c.Title.Contains(filter, StringComparison.CurrentCultureIgnoreCase))).Take(200))
            {
                list.Children.Add(Row(candidate, false, Fill));
            }
        }
        search.TextChanged += (_, _) => { filter = search.Text ?? ""; Fill(); };
        Fill();
        body.Children.Add(search);
        body.Children.Add(list);
    }

    private DockPanel Row(CatalogItemSummary item, bool chosen, Action refill, params Button[] extra)
    {
        var check = new CheckBox { IsChecked = chosen, Content = $"{item.Title}{(item.Year is { } y ? $" ({y})" : "")}" };
        check.IsCheckedChanged += (_, _) => { model.Toggle(item); refill(); };
        var row = new DockPanel();
        if (extra.Length > 0) row.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Children = { extra[0], extra[1] } }.Also(p => DockPanel.SetDock(p, Dock.Right)));
        row.Children.Add(check);
        return row;
    }

    private void BuildRules()
    {
        Control Field(string label, Control input) => new DockPanel
        {
            Children = { new TextBlock { Text = label, Width = 150, VerticalAlignment = VerticalAlignment.Center }.Also(t => DockPanel.SetDock(t, Dock.Left)), input },
        };
        TextBox Text(string property, string placeholder)
        {
            var box = new TextBox { PlaceholderText = placeholder };
            box[!TextBox.TextProperty] = new Binding(property) { Mode = BindingMode.TwoWay };
            AutomationProperties.SetName(box, placeholder);
            return box;
        }
        ComboBox Choice(string property, (string Value, string Label)[] options)
        {
            var box = new ComboBox { ItemsSource = options.Select(o => o.Label).ToList(), MinWidth = 200 };
            var current = typeof(CollectionEditorModel).GetProperty(property)!.GetValue(model)?.ToString();
            box.SelectedIndex = Math.Max(0, Array.FindIndex(options, o => o.Value == current));
            box.SelectionChanged += (_, _) =>
            {
                if (box.SelectedIndex < 0) return;
                var info = typeof(CollectionEditorModel).GetProperty(property)!;
                var value = options[box.SelectedIndex].Value;
                info.SetValue(model, info.PropertyType == typeof(int) ? int.Parse(value, System.Globalization.CultureInfo.InvariantCulture) : info.PropertyType == typeof(bool) ? value == "true" : value);
            };
            return box;
        }
        var favorites = new CheckBox { Content = "Favorites Only" };
        favorites[!ToggleButton.IsCheckedProperty] = new Binding(nameof(CollectionEditorModel.FavoritesOnly)) { Mode = BindingMode.TwoWay };
        body.Children.Add(Field("Match", Choice(nameof(CollectionEditorModel.MatchAny), [("false", "All rules (AND)"), ("true", "Any rule (OR)")])));
        body.Children.Add(Field("Media Type", Choice(nameof(CollectionEditorModel.Kind), [("all", "Movies and TV Shows"), ("movie", "Movies"), ("series", "TV Shows")])));
        body.Children.Add(Field("Genre", Text(nameof(CollectionEditorModel.Genres), "For example Comedy, Drama")));
        body.Children.Add(Field("Min Year", Text(nameof(CollectionEditorModel.YearMin), "Any")));
        body.Children.Add(Field("Max Year", Text(nameof(CollectionEditorModel.YearMax), "Any")));
        body.Children.Add(Field("Min Rating", Text(nameof(CollectionEditorModel.RatingMin), "0–10")));
        body.Children.Add(Field("Watched", Choice(nameof(CollectionEditorModel.Watched), [("any", "Any"), ("unwatched", "Unwatched"), ("watched", "Watched")])));
        body.Children.Add(Field("Added Within", Choice(nameof(CollectionEditorModel.AddedWithinDays), [("0", "Any Time"), ("30", "30 Days"), ("90", "90 Days"), ("365", "One Year")])));
        body.Children.Add(Field("Title Contains", Text(nameof(CollectionEditorModel.TitleContains), "Any text")));
        body.Children.Add(favorites);
        body.Children.Add(preview);
    }

    private async Task SaveAsync()
    {
        if (!model.CanSave) return;
        save.IsEnabled = false;
        var saved = await context.Store.SaveCollectionAsync(model.Existing?.Id, model.Request());
        if (saved is not null) host.Close(true);
        else save.IsEnabled = true;
    }
}
