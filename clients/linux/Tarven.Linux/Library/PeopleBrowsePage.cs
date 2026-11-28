using System.Globalization;
using Tarven.Contracts;
using Tarven.Linux.Controls;
using Tarven.Linux.Core.Api;
using Tarven.Linux.Core.Library;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Threading;

namespace Tarven.Linux.Library;

/// <summary>
/// People ("people-v1"): everyone TMDB identified in the library's credits, those in the most
/// titles first, with a search. A person opens the same page as from Cast &amp; Crew.
/// </summary>
public sealed class PeopleBrowsePage : LibraryPageBase, IDisposable
{
    private readonly TextBox search = new TextBox { PlaceholderText = "Find a Person", Width = 260 }.WithGlass();
    private List<PersonSummary> people = [];
    private int total;
    private bool loaded;
    private string? error;
    private CancellationTokenSource? request;

    public PeopleBrowsePage(LibraryContext context) : base(context)
    {
        AutomationProperties.SetName(search, "Find a Person");
        search.TextChanged += (_, _) => _ = LoadAsync(reset: true, debounce: true);
        // Shown again later: the list is asked again quietly and stays until the answer replaces it.
        AttachedToVisualTree += (_, _) => _ = LoadAsync(reset: true, debounce: false);
        DetachedFromVisualTree += (_, _) => request?.Cancel();
    }

    public void Dispose()
    {
        request?.Cancel();
        request?.Dispose();
        request = null;
    }

    internal IReadOnlyList<PersonSummary> People => people;

    /// <summary>Ctrl+F lands here.</summary>
    public void FocusSearch() => search.Focus();

    /// <summary>People change only with the library's metadata; the page asks again when it is shown.</summary>
    protected override void OnStoreChanged()
    {
    }

    internal async Task LoadAsync(bool reset, bool debounce)
    {
        var previous = request;
        previous?.Cancel();
        var mine = request = new CancellationTokenSource();
        previous?.Dispose();
        var token = mine.Token;
        try
        {
            if (debounce) await Task.Delay(250, token);
            var page = await Context.Store.Client.PeopleAsync(search.Text, reset ? 0 : people.Count, PeoplePresentation.PageSize, token);
            if (token.IsCancellationRequested) return;
            if (reset) people = [.. page.Items];
            else
            {
                var known = people.Select(person => person.PersonKey).ToHashSet(StringComparer.Ordinal);
                people.AddRange(page.Items.Where(person => known.Add(person.PersonKey)));
            }
            total = page.Total;
            error = null;
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (TarvenApiException failure)
        {
            if (token.IsCancellationRequested) return;
            error = failure.Message;
            if (failure.IsAuthenticationFailure) Context.Store.Report(failure);
        }
        loaded = true;
        Rebuild();
    }

    protected override Control Build()
    {
        // The search field moves into the new page; typing goes on where it was.
        var typing = search.IsFocused;
        if (search.Parent is Panel old) old.Children.Remove(search);
        var page = new StackPanel { Spacing = 22, Margin = new Thickness(0, 64, 0, 48) };
        page.Children.Add(new DockPanel
        {
            Margin = Inset(),
            LastChildFill = false,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 12,
                    Children =
                    {
                        PageTitle("People"),
                        new TextBlock { Text = loaded ? total.ToString(CultureInfo.InvariantCulture) : "", Classes = { "subdued" }, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 8) },
                    },
                }.Also(panel => DockPanel.SetDock(panel, Dock.Left)),
                new StackPanel { Orientation = Orientation.Horizontal, Children = { search } }.Also(panel => DockPanel.SetDock(panel, Dock.Right)),
            },
        });
        if (typing) Dispatcher.UIThread.Post(() => search.Focus());
        if (!loaded) return page;
        var query = search.Text?.Trim() ?? "";
        if (error is not null && people.Count == 0)
        {
            var retry = new Button { Content = "Try Again", Classes = { "primary" } };
            retry.Click += (_, _) => _ = LoadAsync(reset: true, debounce: false);
            page.Children.Add(EmptyState("Couldn’t Load People", error, retry));
            return page;
        }
        if (people.Count == 0)
        {
            page.Children.Add(query.Length == 0
                ? EmptyState("No People Yet", "People appear here once TMDB has identified the titles in your library.")
                : EmptyState("No One Found", $"No one in your library matches “{query}”."));
            return page;
        }
        page.Children.Add(Grid(people, person => MediaCards.Person(Context, person)));
        if (people.Count < total)
        {
            var more = new Button { Content = "Load More", Classes = { "chip" }, Margin = Inset(), HorizontalAlignment = HorizontalAlignment.Left };
            more.Click += (_, _) =>
            {
                more.IsEnabled = false;
                _ = LoadAsync(reset: false, debounce: false);
            };
            page.Children.Add(more);
        }
        if (error is not null) page.Children.Add(new TextBlock { Text = error, Classes = { "subdued" }, Margin = Inset(), TextWrapping = Avalonia.Media.TextWrapping.Wrap });
        return page;
    }
}
