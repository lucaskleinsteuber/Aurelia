using System.Text.Json;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Hosting;
using Aurelia.Linux.Core.Moving;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Management;
using Aurelia.Linux.Settings;
using Aurelia.Linux.Views;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.VisualTree;
using Xunit;

using static Aurelia.Linux.Tests.TestWindows;

namespace Aurelia.Linux.Tests;

/// <summary>The production move screens with a scripted server and invented data (docs/SERVER_MOVE.md).</summary>
public sealed class ServerMoveScreenTests
{
    private static readonly Guid FilmsId = Guid.Parse("b0000000-0000-4000-8000-000000000001");

    private static IEnumerable<T> All<T>(Control root) where T : Control => root.GetVisualDescendants().OfType<T>().Where(c => c.IsEffectivelyVisible);

    private static Button NamedButton(Control root, string name) =>
        All<Button>(root).First(b => AutomationProperties.GetName(b) == name || b.Content as string == name);

    private static TextBox Field(Control root, string name) => All<TextBox>(root).Single(t => AutomationProperties.GetName(t) == name);

    private static bool Shows(Control root, string text) => All<TextBlock>(root).Any(t => t.Text?.Contains(text, StringComparison.Ordinal) == true);

    private static Control? Sheet(SettingsView settings) => (settings.Sheets.Current as Border)?.Child;

    private static void Click(Button button)
    {
        button.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => false, rounds: 30);
    }

    private static void Snapshot(Control shown, string name)
    {
        using var frame = HostOf(shown).CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, name);
    }

    private static string Json<T>(T value) => JsonSerializer.Serialize(value, AureliaJson.Options);

    [AvaloniaFact]
    public void ThisPcTakesOverAnotherServerAndSignsInAsItsOwner()
    {
        var move = new HostSetupMoveTests.ScriptedMove().Then(new SetupMoveStatus("idle"), new SetupMoveStatus("fetching", new SetupMoveProgress(1, 4)),
            HostSetupMoveTests.Received());
        var host = new HostingScreenTests.ScriptedHost(LocalServerState.SetupRequired) { SetupMove = move };
        var settings = new MemorySettingsStore();
        settings.Write(AppFlow.OperatingModeKey, "host");
        var window = TestWindows.Show(AppServices.ForTests(settings, transport: FakeLibrary.Create(pictures: false), host: host));
        FakeLibrary.Pump(() => window.Hosting?.Phase == HostPhase.OwnerSetup);
        window.Hosting!.MovePollInterval = TimeSpan.FromMilliseconds(1);
        Assert.True(Shows(window, "Already have an Aurelia server?"));

        Click(NamedButton(window, "Move from Another Aurelia Server…"));
        FakeLibrary.Pump(() => Shows(window, "Servers Nearby"));
        Assert.True(Shows(window, "No Aurelia server found nearby."));
        Field(window, "Old Server Address").Text = "192.168.1.20";
        Field(window, "Move Code").Text = "abcdefghjkmn";
        FakeLibrary.Pump(() => false, rounds: 3);
        Assert.Equal("ABCD-EFGH-JKMN", Field(window, "Move Code").Text);
        Snapshot(window, "host-move-start");
        Click(NamedButton(window, "Start Move"));
        FakeLibrary.Pump(() => window.Hosting.Phase == HostPhase.MoveLocations);
        Assert.Equal((new Uri("https://192.168.1.20:43111"), "ABCD-EFGH-JKMN"), move.Network);
        Assert.True(Shows(window, "Where Are Your Media Files Now?"));
        Assert.True(Shows(window, "412 of 415 sample files found"));
        Assert.True(Shows(window, "Was /synthetic/old/Shows"));

        Field(window, "Other Folder for Shows").Text = "/srv/shows";
        FakeLibrary.Pump(() => false, rounds: 3);
        Click(NamedButton(window, "Preview Folder for Shows"));
        FakeLibrary.Pump(() => Shows(window, "18 of 20 sample files found"));
        Assert.True(Shows(window, "18 of 20 sample files found"));
        Snapshot(window, "host-move-locations");

        host.AfterStart = LocalServerState.Running;
        move.Then(new SetupMoveStatus("done"));
        Click(NamedButton(window, "Finish Move"));
        FakeLibrary.Pump(() => window.Hosting.Phase == HostPhase.SignIn);
        Assert.Equal("/srv/shows", move.Finished!.Mappings.Single(m => m.Path != "/mnt/media/Movies").Path);
        Assert.True(Shows(window, "The move is done."));
        window.Quit();
    }

    [AvaloniaFact]
    public void TheOwnerShowsAMoveCodeAndFollowsTheNewServer()
    {
        var server = ManagementScreenTests.Server()
            .Answer("GET", "/api/v1/server/move", """{"state":"none"}""")
            .Answer("POST", "/api/v1/server/move", Json(new ServerMoveStarted("waiting", "network", "ABCDEFGHJKMN", DateTimeOffset.UtcNow.AddMinutes(15))));
        var window = FakeLibrary.ShowLibrary(server);
        var settings = window.OpenSettings(SettingsCategory.Server);
        var page = settings.Page!;
        FakeLibrary.Pump(() => Shows(page, "Not moved. Start a move"), rounds: 400);
        Click(NamedButton(page, "Move to a New Server"));
        var sheet = Assert.IsType<MoveServerSheet>(Sheet(settings));
        Click(NamedButton(sheet, "Over the Network"));
        FakeLibrary.Pump(() => sheet.Code == "ABCD-EFGH-JKMN");
        Assert.Equal("ABCD-EFGH-JKMN", sheet.Code);
        Assert.True(Shows(sheet, "The code works once, for 1"));
        Assert.True(Shows(sheet, "192.168.1.20"));
        Assert.Contains("\"method\":\"network\"", server.Bodies["POST /api/v1/server/move"], StringComparison.Ordinal);
        Snapshot(settings, "server-move-code");

        server.Replace("GET", "/api/v1/server/move", Json(new ServerMoveStatus("moved", "network", MovedTo: new MovedServer(Guid.NewGuid(), "Synthetic Basement", ["https://192.168.1.40:43111"]))));
        var watching = sheet.WatchAsync();
        FakeLibrary.Pump(() => watching.IsCompleted);
        Assert.True(Shows(sheet, "This server moved to “Synthetic Basement”"));
        window.Quit();
    }

    [AvaloniaFact]
    public void UndoMoveWaitsForTheNewServerToBeOff()
    {
        var server = ManagementScreenTests.Server()
            .Answer("GET", "/api/v1/server/move", Json(new ServerMoveStatus("moved", "file", MovedTo: new MovedServer(Guid.NewGuid(), "Synthetic Basement", []))))
            .Answer("DELETE", "/api/v1/server/move", "{}");
        var window = FakeLibrary.ShowLibrary(server);
        var settings = window.OpenSettings(SettingsCategory.Server);
        var page = settings.Page!;
        FakeLibrary.Pump(() => Shows(page, "Synthetic Basement"), rounds: 400);
        Click(NamedButton(page, "Undo Move"));
        var sheet = Assert.IsType<UndoMoveSheet>(Sheet(settings));
        var undo = NamedButton(sheet, "Undo Move");
        Assert.False(undo.IsEnabled);
        All<CheckBox>(sheet).Single().IsChecked = true;
        Assert.True(undo.IsEnabled);
        Click(undo);
        FakeLibrary.Pump(() => server.Requests.Contains("DELETE /api/v1/server/move"));
        Assert.Contains("DELETE /api/v1/server/move", server.Requests);
        window.Quit();
    }

    [AvaloniaFact]
    public void AStorageLocationIsPointedAtItsNewFolderAndAnEmptyFolderNeedsTwoConfirmations()
    {
        var server = ManagementScreenTests.Server()
            .Answer("GET", $"/api/v1/libraries/{FilmsId}/relocate/suggestions", Json(new RelocateSuggestions(20, [new MoveSuggestion("/mnt/new/Films", 19)])))
            .Answer("POST", $"/api/v1/libraries/{FilmsId}/relocate/preview", Json(new MoveMatch(20, 0)))
            .Answer("POST", $"/api/v1/libraries/{FilmsId}/relocate", "{}");
        var window = FakeLibrary.ShowLibrary(server);
        var settings = window.OpenSettings(SettingsCategory.Library);
        var page = settings.Page!;
        FakeLibrary.Pump(() => Shows(page, "/srv/media/Films"), rounds: 400);
        Click(NamedButton(page, "Storage Location Moved Films"));
        var sheet = Assert.IsType<StorageLocationMovedSheet>(Sheet(settings));
        FakeLibrary.Pump(() => Shows(sheet, "19 of 20 sample files found"));
        var confirm = NamedButton(sheet, "Move Location");
        Assert.False(confirm.IsEnabled);
        All<RadioButton>(sheet).Single().IsChecked = true;
        FakeLibrary.Pump(() => false, rounds: 3);
        Assert.True(confirm.IsEnabled);
        Assert.Equal("/mnt/new/Films", Field(sheet, "New Folder").Text);
        Snapshot(settings, "storage-location-moved");

        Field(sheet, "New Folder").Text = "/srv/empty";
        FakeLibrary.Pump(() => false, rounds: 3);
        Assert.False(confirm.IsEnabled);
        Click(NamedButton(sheet, "Preview Folder"));
        FakeLibrary.Pump(() => Shows(sheet, "This may be the wrong folder."));
        Assert.False(confirm.IsEnabled);
        All<CheckBox>(sheet).Single(c => AutomationProperties.GetName(c) == "Point it there anyway").IsChecked = true;
        Assert.True(confirm.IsEnabled);
        Click(confirm);
        // The second, explicit question before an empty folder is forced.
        FakeLibrary.Pump(() => Sheet(settings) is StackPanel);
        Assert.DoesNotContain($"POST /api/v1/libraries/{FilmsId}/relocate", server.Requests);
        Click(NamedButton(Sheet(settings)!, "Move Location Anyway"));
        FakeLibrary.Pump(() => server.Bodies.ContainsKey($"POST /api/v1/libraries/{FilmsId}/relocate"));
        var sent = JsonDocument.Parse(server.Bodies[$"POST /api/v1/libraries/{FilmsId}/relocate"]).RootElement;
        Assert.Equal("/srv/empty", sent.GetProperty("path").GetString());
        Assert.True(sent.GetProperty("force").GetBoolean());
        window.Quit();
    }
}
