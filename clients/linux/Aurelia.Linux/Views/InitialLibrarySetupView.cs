using Aurelia.Contracts;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Library;
using Aurelia.Linux.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;

namespace Aurelia.Linux.Views;

/// <summary>
/// The Mac app's InitialLibrarySetupView, after this computer's new server is set up: choose drives or
/// folders on this PC, analyze them in an import preview, or skip for now. Media files are only read.
/// </summary>
public sealed class InitialLibrarySetupView : UserControl
{
    private readonly AppSession session;
    private readonly SheetHost sheets = new();
    private readonly AdminScope scope;
    private readonly List<StorageLocationDraft> drafts = [];
    private readonly StackPanel list = new() { Spacing = 8, Width = 560 };
    private readonly StackPanel waiting = new() { Spacing = 8, Width = 560 };
    private readonly TextBlock message = AdminScope.Message();
    private readonly Button analyze = new() { Content = "Analyze and Preview", Classes = { "primary" }, IsEnabled = false };

    public InitialLibrarySetupView(AppSession session)
    {
        this.session = session;
        scope = new AdminScope(session, sheets);
        var choose = new Button { Content = "Choose Storage Locations…", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Center };
        choose.Click += async (_, _) => await ChooseAsync();
        var skip = new Button { Content = "Skip for Now", Classes = { "link" } };
        skip.Click += (_, _) => session.CompleteInitialLibrarySetup();
        AutomationProperties.SetName(analyze, "Analyze and Preview");
        analyze.Click += async (_, _) => await AnalyzeAsync();
        Content = new Panel
        {
            Children =
            {
                ScreenParts.Backdrop(new ScrollViewer
                {
                    Content = new StackPanel
                    {
                        Spacing = 20,
                        Margin = new Thickness(40, 70, 40, 40),
                        HorizontalAlignment = HorizontalAlignment.Center,
                        VerticalAlignment = VerticalAlignment.Center,
                        Children =
                        {
                            ScreenParts.Symbol("IconServer", 48),
                            ScreenParts.Title("Choose Storage Locations"),
                            ScreenParts.Detail("Select a drive or folder. Aurelia will recognize movies and TV shows for you."),
                            list,
                            choose,
                            new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14, HorizontalAlignment = HorizontalAlignment.Center, Children = { skip, analyze } },
                            waiting,
                            message.Also(m => m.HorizontalAlignment = HorizontalAlignment.Center),
                        },
                    },
                }),
                sheets,
            },
        };
        Fill();
    }

    internal SheetHost Sheets => sheets;

    internal IReadOnlyList<StorageLocationDraft> Drafts => drafts;

    /// <summary>Adds folders of this computer; the server runs here, so their paths are the server's too.</summary>
    internal void Add(IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            if (drafts.All(d => d.Path != path)) drafts.Add(new StorageLocationDraft(path, null, LibraryKind.Automatic));
        }
        Fill();
    }

    private async Task ChooseAsync()
    {
        var storage = TopLevel.GetTopLevel(this)?.StorageProvider;
        if (storage is null) return;
        var folders = await storage.OpenFolderPickerAsync(new FolderPickerOpenOptions { AllowMultiple = true, Title = "Choose Storage Locations" });
        Add(folders.Select(folder => folder.TryGetLocalPath()).OfType<string>());
    }

    private void Fill()
    {
        list.Children.Clear();
        for (var index = 0; index < drafts.Count; index++)
        {
            var position = index;
            var draft = drafts[index];
            var kind = Settings.SettingsRows.Choice("Type", null, [(LibraryKind.Automatic, "Movies and TV Shows"), (LibraryKind.Movies, "Movies"), (LibraryKind.TvShows, "TV Shows")],
                draft.Kind, value => drafts[position] = drafts[position] with { Kind = value });
            var remove = new Button { Content = "Remove", Classes = { "link" } };
            AutomationProperties.SetName(remove, "Remove " + draft.SuggestedName);
            remove.Click += (_, _) =>
            {
                drafts.RemoveAt(position);
                Fill();
            };
            list.Children.Add(new Border
            {
                Classes = { "card" },
                Padding = new Thickness(12, 6),
                Child = new DockPanel
                {
                    Children =
                    {
                        remove.Also(b => DockPanel.SetDock(b, Dock.Right)),
                        new StackPanel
                        {
                            Children =
                            {
                                new TextBlock { Text = draft.SuggestedName, FontWeight = FontWeight.SemiBold },
                                new TextBlock { Text = draft.Path, Classes = { "subdued" }, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis },
                                kind.Also(k => k.Margin = new Thickness(0, 4, 0, 0)),
                            },
                        },
                    },
                },
            });
        }
        analyze.IsEnabled = drafts.Count > 0;
    }

    /// <summary>Registers each folder, waiting for its import preview, and opens the first preview.</summary>
    private async Task AnalyzeAsync()
    {
        analyze.IsEnabled = false;
        var created = new List<LibrarySummary>();
        await scope.RunAsync(async () =>
        {
            foreach (var draft in drafts.ToList())
            {
                created.Add(await scope.Client.CreateLibraryAsync(new CreateLibraryRequest(draft.SuggestedName, draft.Path, draft.Kind, RequireImportPreview: true)));
                drafts.Remove(draft);
            }
        }, message);
        Fill();
        await ShowWaitingAsync();
        if (created.Count > 0) await PreviewAsync(created[0]);
    }

    private async Task PreviewAsync(LibrarySummary library)
    {
        if (await sheets.ShowAsync(new ImportPreviewSheet(scope, new ImportPreviewModel(scope.Client, library))))
        {
            await ShowWaitingAsync();
            if (waiting.Children.Count == 0) session.CompleteInitialLibrarySetup();
        }
    }

    /// <summary>Locations still waiting for an import confirmation, each with Review Import.</summary>
    private async Task ShowWaitingAsync()
    {
        IReadOnlyList<LibrarySummary> libraries = [];
        if (!await scope.RunAsync(async () => libraries = await scope.Client.LibrariesAsync(), message)) return;
        waiting.Children.Clear();
        foreach (var library in libraries.Where(l => l.ImportPreviewRequired))
        {
            var review = new Button { Content = "Review Import…", Classes = { "chip" } };
            AutomationProperties.SetName(review, "Review Import " + library.Name);
            review.Click += async (_, _) => await PreviewAsync(library);
            waiting.Children.Add(new DockPanel
            {
                Children =
                {
                    review.Also(b => DockPanel.SetDock(b, Dock.Right)),
                    new TextBlock { Text = library.Name, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center },
                },
            });
        }
    }
}
