using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;
using Aurelia.Desktop.Views;
using Xunit;

namespace Aurelia.Desktop.Tests;

/// <summary>Management from the library and Server Settings: removing and editing titles, and profiles, with scripted management.</summary>
public sealed class ManagementScreenTests
{
    private const string Password = "synthetic server password";

    private static void Click(Control root, string name) =>
        root.FindControl<Button>(name)!.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    private static async Task<(MainWindow Window, FakeManagement Management, List<string?> Prompts)> OpenOwnerLibraryAsync()
    {
        var local = FakeServerApi.Saved() with { Address = new Uri("https://127.0.0.1:43111"), LocalHost = true };
        var api = new FakeServerApi();
        var store = new ConnectionStore(new MemorySecretStore());
        store.Save(local);
        var modes = new AppModeStore(Path.Combine(Path.GetTempPath(), "aurelia-desktop-mode-" + Guid.NewGuid().ToString("N"), "app-mode.json"));
        modes.Save(AppMode.Host);
        var server = new FakeLocalServerHost { SetUp = true };
        // Management starts locked, as it is ten minutes after the last unlock.
        var management = new FakeManagement { Locked = true };
        var host = new HostSetupFlow(server, api, store, modes, (_, _) => management, "Synthetic PC", action => Dispatcher.UIThread.Post(action));
        var flow = new ConnectionFlow(api, store, new NoServerDiscovery(), "Synthetic PC", action => action(), delay: (_, _) => Task.CompletedTask);
        var window = new MainWindow(flow, _ => new FakeLibraryApi(), _ => new FakeEngineFactory(), MainWindowTests.TemporarySettings(),
            startOnOpen: false, artworkCache: _ => null, host: host, modes: modes, store: store,
            administration: (_, _) => management)
        { Width = 1280, Height = 800 };
        var prompts = new List<string?>();
        // The first answer is wrong, the second right.
        window.PasswordPrompt = problem =>
        {
            prompts.Add(problem);
            return Task.FromResult<string?>(prompts.Count == 1 ? "a wrong password" : Password);
        };
        window.Show();
        await window.StartAsync();
        await MainWindowTests.WaitFor(() => window.Flow.ShowsProfiles);
        await window.Flow.ChooseProfileAsync(FakeServerApi.Owner);
        await window.Flow.SubmitPinAsync("5682");
        await MainWindowTests.WaitFor(() => window.LibraryModel is not null);
        return (window, management, prompts);
    }

    [AvaloniaFact]
    public async Task TheOwnerRemovesATitleAfterTheServerPassword()
    {
        var (window, management, prompts) = await OpenOwnerLibraryAsync();
        var library = window.LibraryModel!;
        Assert.True(library.CanManage);
        await library.OpenDetailAsync(FakeLibraryApi.SecondMovieId);
        MainWindowTests.Settle(window, "detail-owner");
        var view = window.FindControl<LibraryView>("Library")!;
        Assert.True(view.FindControl<Button>("MoreButton")!.IsVisible);
        Assert.Equal("Remove Second Feature?", library.RemoveQuestion);

        await library.RemoveDetailAsync();
        Assert.Equal([null, ManagementAccess.WrongPassword], prompts);
        Assert.Contains($"DELETE /api/v1/media/{FakeLibraryApi.SecondMovieId}", management.Calls);
        Assert.Null(library.Detail);
        Assert.Null(library.Error);
    }

    [AvaloniaFact]
    public async Task EditDetailsKeepsManualValuesAndANewPoster()
    {
        var (window, management, _) = await OpenOwnerLibraryAsync();
        var library = window.LibraryModel!;
        await library.OpenDetailAsync(FakeLibraryApi.MovieId);
        library.EditDetail();
        await MainWindowTests.WaitFor(() => window.EditorWindow?.DataContext is MetadataEditorModel { IsLoaded: true });
        var editor = window.EditorWindow!;
        var model = (MetadataEditorModel)editor.DataContext!;
        Assert.Equal("Synthetic Movie", model.Title);
        Assert.Equal("FSK 12", MetadataEditorModel.AgeRatings[model.AgeIndex]);
        Assert.False(model.TitleIsManual);

        editor.FindControl<TextBox>("TitleBox")!.Text = "My Synthetic Movie";
        editor.FindControl<TextBox>("GenresBox")!.Text = "Drama, Mystery";
        editor.ImageSource = () => Task.FromResult<byte[]?>(SyntheticMedia.Png(200, 300));
        Click(editor, "ChoosePosterButton");
        await MainWindowTests.WaitFor(() => model.PosterIsManual && !model.IsBusy);
        MainWindowTests.Settle(editor, "editor");
        Assert.True(model.TitleIsManual);
        Assert.True(model.IsDirty);
        Assert.Equal("New poster, saved with the other changes", model.PosterText);

        Click(editor, "SaveButton");
        await MainWindowTests.WaitFor(() => window.EditorWindow is null);
        Assert.Equal(["genres", "poster", "title"], management.EditorOverrides);
        Assert.Equal("My Synthetic Movie", management.EditorValues.Title);
        Assert.Equal(["Drama", "Mystery"], management.EditorValues.Genres);
        Assert.Empty(management.DiscardedUploads);
    }

    [AvaloniaFact]
    public async Task CancellingTheEditorDiscardsItsImages()
    {
        var (window, management, _) = await OpenOwnerLibraryAsync();
        await window.LibraryModel!.OpenDetailAsync(FakeLibraryApi.MovieId);
        window.LibraryModel.EditDetail();
        await MainWindowTests.WaitFor(() => window.EditorWindow?.DataContext is MetadataEditorModel { IsLoaded: true });
        var editor = window.EditorWindow!;
        var model = (MetadataEditorModel)editor.DataContext!;
        await model.ChooseImageAsync(poster: false, SyntheticMedia.Png(320, 180));
        editor.Close();
        await MainWindowTests.WaitFor(() => window.EditorWindow is null);
        Assert.Single(management.DiscardedUploads);
        Assert.Equal(2, management.EditorRevision);
    }

    [AvaloniaFact]
    public async Task ServerSettingsAddChangeAndRemoveProfiles()
    {
        var connection = FakeServerApi.Saved() with { Address = new Uri("https://127.0.0.1:43111"), LocalHost = true };
        var server = new FakeLocalServerHost { SetUp = true };
        server.Move(LocalServerState.Running);
        var management = new FakeManagement();
        var session = new ProfileSessionResponse(new UserSummary(FakeServerApi.Owner.Id, "Alex", UserRole.Owner, DateTimeOffset.UtcNow),
            Guid.NewGuid(), "synthetic-profile-token-0123456789-abcdef", DateTimeOffset.UtcNow.AddHours(12));
        var model = new ServerSettingsModel(server, new FakeServerApi(), connection, session, _ => management,
            action => Dispatcher.UIThread.Post(action));
        var window = new ServerSettingsWindow(model) { Width = 900, Height = 900 };
        window.Show();
        await MainWindowTests.WaitFor(() => model.IsUnlocked && !model.IsBusy);
        window.FindControl<ListBox>("Sections")!.SelectedIndex = 3;
        var profiles = model.Profiles;
        await MainWindowTests.WaitFor(() => profiles.Profiles.Count == 2 && !profiles.IsBusy);
        MainWindowTests.Settle(window, "settings-profiles");
        Assert.Equal("Owner · PIN · Entire library", profiles.Profiles[0].Details);
        Assert.Equal("User · No PIN · Selected titles", profiles.Profiles[1].Details);

        // A new administrator always gets a PIN.
        Click(window, "NewProfileButton");
        await MainWindowTests.WaitFor(() => profiles.IsEditing && !profiles.IsBusy);
        profiles.Name = "Sam";
        profiles.RoleIndex = 1;
        profiles.PinProtection = false;
        Assert.True(profiles.AsksForPin);
        profiles.Pin = "1357";
        profiles.PinConfirmation = "1375";
        await profiles.SaveAsync();
        Assert.Equal("The PINs do not match.", profiles.Error);
        profiles.PinConfirmation = "1357";
        await profiles.SaveAsync();
        Assert.Null(profiles.Error);
        Assert.Contains("create Sam Admin 1357 EntireLibrary ", management.Calls);
        Assert.Equal(3, profiles.Profiles.Count);

        // Kim sees selected titles; the list shows which.
        await profiles.BeginEditAsync(profiles.Profiles.Single(row => row.Name == "Kim"));
        MainWindowTests.Settle(window, "settings-profile-edit");
        Assert.False(profiles.IsNew);
        Assert.True(profiles.ChoosesTitles);
        Assert.Equal("1 of 3 titles", profiles.SelectionText);
        profiles.TitleFilter = "series";
        Assert.Single(profiles.Titles);
        profiles.Titles[0].IsSelected = true;
        Assert.Equal("2 of 3 titles", profiles.SelectionText);
        await profiles.SaveAsync();
        Assert.Null(profiles.Error);
        Assert.Contains("update Kim User  SelectedTitles 2", management.Calls);

        await profiles.RemoveAsync(profiles.Profiles.Single(row => row.Name == "Kim"));
        Assert.Equal(["Alex", "Sam"], profiles.Profiles.Select(row => row.Name).OrderBy(name => name));
        window.Close();
    }
}
