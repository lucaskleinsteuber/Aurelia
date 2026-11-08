using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Hosting;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Views;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.VisualTree;
using SkiaSharp;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>The setup assistant: introduction, questions, guided steps, people, the last page and the library tour.</summary>
public sealed class SetupAssistantTests
{
    [Fact]
    public void ExistingSetupsNeverSeeTheAssistantAndAnswersAreKept()
    {
        var existing = new MemorySettingsStore();
        existing.Write(AppFlow.OperatingModeKey, "client");
        Assert.True(new AppFlow(existing).Guide.IntroSeen);

        var settings = new MemorySettingsStore();
        var flow = new AppFlow(settings);
        Assert.False(flow.Guide.IntroSeen);
        flow.Guide.Audience = SetupAudience.SeveralPeople;
        flow.Guide.Devices = SetupDevices.AppleTv | SetupDevices.WebBrowser;
        flow.StartGuidedSetup(OperatingMode.Host);
        Assert.True(flow.Guide.IsGuiding);
        Assert.Equal(AppScreen.HostSetup, flow.Screen);
        Assert.Equal([SetupStep.Choose, SetupStep.Secure, SetupStep.Pin, SetupStep.Media, SetupStep.People, SetupStep.Done], flow.Guide.Steps(OperatingMode.Host));
        Assert.Equal([SetupStep.Choose, SetupStep.Connect, SetupStep.Profile, SetupStep.Done], flow.Guide.Steps(OperatingMode.Client));

        // After a restart the guidance and the answers continue.
        var restarted = new AppFlow(settings);
        Assert.True(restarted.Guide.IsGuiding);
        Assert.Equal(SetupAudience.SeveralPeople, restarted.Guide.Audience);
        Assert.Equal(SetupDevices.AppleTv | SetupDevices.WebBrowser, restarted.Guide.Devices);
        restarted.Guide.Finish();
        Assert.False(restarted.Guide.IsGuiding);
        Assert.True(restarted.Guide.TourPending);
        restarted.Guide.TourShown();
        Assert.False(new AppFlow(settings).Guide.TourPending);
    }

    [AvaloniaFact]
    public void TheIntroductionAsksWhereTheMediaIsWhoWatchesAndWhichDevicesFollow()
    {
        var window = TestWindows.Show();
        var introduction = Assert.IsType<IntroductionView>(window.CurrentScreen);
        Assert.Equal(IntroductionView.Page.Welcome, introduction.Current);
        Snapshot(window, "assistant-welcome");
        Click(Button(window, "Show Me Around"));
        Assert.Equal(IntroductionView.Page.HowItWorks, introduction.Current);
        Assert.True(Shows(window, "One computer serves your library."));
        Snapshot(window, "assistant-how-it-works");
        Click(Button(window, "Continue"));
        Assert.Equal(IntroductionView.Page.MediaLocation, introduction.Current);
        Click(Button(window, "Not Sure?"));
        Assert.True(Shows(window, "whose drives hold the movies"));
        Snapshot(window, "assistant-where");
        Click(Button(window, "On This Computer"));
        Assert.Equal(IntroductionView.Page.Audience, introduction.Current);
        Snapshot(window, "assistant-who");
        Click(Button(window, "Several People"));
        Assert.Equal(IntroductionView.Page.Devices, introduction.Current);
        Click(Button(window, "Apple TV"));
        Click(Button(window, "Web Browser"));
        Click(Button(window, "Web Browser"));
        Assert.Contains("selected", Button(window, "Apple TV").Classes);
        Assert.DoesNotContain("selected", Button(window, "Web Browser").Classes);
        Snapshot(window, "assistant-devices");
        Click(Button(window, "Set Up This PC"));

        Assert.Equal(OperatingMode.Host, window.Flow.Mode);
        Assert.True(window.Flow.Guide.IsGuiding);
        Assert.Equal(SetupAudience.SeveralPeople, window.Flow.Guide.Audience);
        Assert.Equal(SetupDevices.AppleTv, window.Flow.Guide.Devices);
        var bar = Assert.Single(Visible<SetupStepBar>(window));
        Assert.Equal(SetupStep.Secure, bar.Current);
        Assert.True(Shows(window, "People"));
        window.Quit();
    }

    [AvaloniaFact]
    public void AnotherComputerConnectsUnderTheStepBarAndSkippingRemovesIt()
    {
        var window = TestWindows.Show();
        Click(Button(window, "Show Me Around"));
        Click(Button(window, "Continue"));
        Click(Button(window, "On Another Computer"));
        Assert.Equal(AppScreen.Connection, window.Flow.Screen);
        Assert.Equal(SetupStep.Connect, Assert.Single(Visible<SetupStepBar>(window)).Current);
        Snapshot(window, "assistant-connect");
        Click(Button(window, "Skip Assistant"));
        Assert.False(window.Flow.Guide.IsGuiding);
        Assert.Empty(Visible<SetupStepBar>(window));
        Assert.Equal(AppScreen.Connection, window.Flow.Screen);
        window.Quit();
    }

    [AvaloniaFact]
    public void PeopleAreAddedThenTheLastPageExplainsDevicesAndTheTourRuns()
    {
        var child = new UserSummary(Guid.Parse("c0000000-0000-4000-8000-0000000000c1"), "Mia", UserRole.User, DateTimeOffset.UtcNow,
            ProfileAccessMode.EntireLibrary, false, false, 1, "Mia", "rocket:teal", 1, 6);
        var info = $$"""
            {"serverId":"{{FakeServer.ServerId}}","name":"Living Room Server","version":"1.32.2","isSetup":true,"lanAccessEnabled":true,"lanHttpsPort":43111,
             "publicKeyFingerprint":"{{FakeServer.Fingerprint}}","displayFingerprint":"A1B2-C3D4-E5F6-0718-293A-4B5C",
             "capabilities":["library-state-v1","profile-personalization-v1","age-limits-v1"],"wakeOnLanAddresses":[]}
            """;
        var server = ManagementScreenTests.Server()
            .Replace("GET", "/api/v1/server/info", info)
            .Answer("POST", "/api/v1/users", JsonSerializer.Serialize(child, AureliaJson.Options));
        var settings = new MemorySettingsStore();
        settings.Write(AppFlow.OperatingModeKey, "host");
        settings.Write(SetupGuide.IntroSeenKey, true);
        settings.Write(SetupGuide.GuidingKey, true);
        settings.Write(SetupGuide.AudienceKey, "several");
        settings.Write(SetupGuide.DevicesKey, (int)(SetupDevices.AppleTv | SetupDevices.Computer));
        var window = TestWindows.Show(AppServices.ForTests(settings, transport: server,
            credentials: new MemoryCredentialStore { Server = HostingScreenTests.Saved() }, host: new HostingScreenTests.ScriptedHost(LocalServerState.Running) { Capabilities = ["library-state-v1", "profile-personalization-v1", "age-limits-v1"] }));
        FakeLibrary.Pump(() => window.Flow.Screen == AppScreen.ProfilePicker);
        window.Session.OpenProfile(new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow),
            Guid.NewGuid(), "synthetic-profile-token-00000000000000000001", DateTimeOffset.UtcNow.AddHours(12)));
        FakeLibrary.Pump(() => false, rounds: 5);

        var finish = Assert.IsType<SetupFinishView>(window.CurrentScreen);
        Assert.True(finish.ShowsPeople);
        Snapshot(window, "assistant-people");
        Click(Button(window, "Add Person"));
        Assert.True(Shows(window, "Enter the person's name."));
        Field(window, "Person's Name").Text = "Mia";
        Click(Visible<Button>(window).First(b => AutomationProperties.GetName(b) == "Picture rocket"));
        Visible<ToggleSwitch>(window).Single(t => AutomationProperties.GetName(t) == "Children's Profile").IsChecked = true;
        FakeLibrary.Pump(() => false, rounds: 2);
        Click(Button(window, "Add Person"));
        var body = server.Bodies["POST /api/v1/users"];
        Assert.Contains("\"ageLimit\":6", body, StringComparison.Ordinal);
        Assert.Contains("\"pictureKey\":\"rocket:", body, StringComparison.Ordinal);
        Assert.Contains("\"accessMode\":\"entireLibrary\"", body, StringComparison.Ordinal);
        Assert.Single(finish.Added);
        Assert.True(Shows(window, "Children's profile · up to FSK 6"));
        Click(Button(window, "Continue"));

        Assert.False(finish.ShowsPeople);
        Assert.True(Shows(window, "You're All Set"));
        Assert.True(Shows(window, "One more person can watch."));
        Assert.True(Shows(window, "Apple TV"));
        Assert.True(Shows(window, "Another Computer"));
        Assert.False(Shows(window, "Web Browser"));
        Snapshot(window, "assistant-done");
        Click(Button(window, "Start Watching"));

        Assert.False(window.Flow.Guide.IsGuiding);
        FakeLibrary.Pump(() => window.Shell?.Tour is not null);
        var tour = Assert.IsType<SpotlightTour>(window.Shell?.Tour);
        Assert.Equal(0, tour.Index);
        Snapshot(window, "assistant-tour");
        for (var stop = 0; stop < 5; stop++) Click(Visible<Button>(tour).Single(b => AutomationProperties.GetName(b) == "Next Tour Step"));
        Assert.Null(window.Shell?.Tour);
        Assert.False(window.Flow.Guide.TourPending);
        window.Quit();
    }

    [AvaloniaFact]
    public void ThePicturePickerChoosesSymbolsColorsAndPhotos()
    {
        var picker = new ProfilePicturePicker(null, () => "Mia", null, 0);
        var window = new Window { Content = picker, Width = 600, Height = 500 };
        window.Show();
        Assert.Null(picker.Key);
        Assert.False(picker.Changed);
        Click(Visible<Button>(picker).Single(b => AutomationProperties.GetName(b) == "Picture cat"));
        Click(Visible<Button>(picker).Single(b => AutomationProperties.GetName(b) == "Color green"));
        Assert.Equal("cat:green", picker.Key);
        Assert.True(picker.Changed);
        picker.UsePhoto([1, 2, 3]);
        Assert.Equal("cat:green", picker.Key);
        Assert.True(Shows(picker, "not a picture Aurelia can read"));
        picker.UsePhoto(Png());
        Assert.Equal(ProfilePictures.PhotoKey, picker.Key);
        Assert.NotNull(picker.Photo);
        Click(Visible<Button>(picker).Single(b => b.Content as string == "Use Initial"));
        Assert.Null(picker.Key);
        Assert.Null(picker.Photo);
        window.Close();
    }

    private static byte[] Png()
    {
        using var bitmap = new SKBitmap(64, 64);
        using (var canvas = new SKCanvas(bitmap)) canvas.Clear(new SKColor(200, 60, 90));
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        return data.ToArray();
    }

    private static IEnumerable<T> Visible<T>(Control root) where T : Control =>
        root.GetVisualDescendants().OfType<T>().Where(control => control.IsEffectivelyVisible);

    private static Button Button(Control root, string text) =>
        Visible<Button>(root).First(b => b.Content as string == text || AutomationProperties.GetName(b) == text);

    private static TextBox Field(Control root, string name) => Visible<TextBox>(root).Single(t => AutomationProperties.GetName(t) == name);

    private static bool Shows(Control root, string text) =>
        Visible<TextBlock>(root).Any(t => t.Text?.Contains(text, StringComparison.Ordinal) == true);

    private static void Click(Button button)
    {
        button.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Avalonia.Controls.Button.ClickEvent));
        FakeLibrary.Pump(() => false, rounds: 10);
    }

    private static void Snapshot(Window window, string name)
    {
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, name);
    }
}
