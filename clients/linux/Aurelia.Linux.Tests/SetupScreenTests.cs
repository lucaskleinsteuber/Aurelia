using System.Net;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Views;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class SetupScreenTests
{
    private const string OwnerId = "11111111-0000-4000-8000-000000000001";
    private const string KidId = "22222222-0000-4000-8000-000000000002";
    private const string GuestId = "33333333-0000-4000-8000-000000000003";

    private static FakeServer ServerWithProfiles() => FakeServer.WithServerInfo()
        .Answer("POST", "/api/v1/auth/pair", $$"""
            {"user":{"id":"{{OwnerId}}","username":"owner","role":"owner","createdAt":"2026-10-31T20:00:00Z"},
             "sessionId":"44444444-0000-4000-8000-000000000004","token":"device-token-synthetic-0000000000000000000001","expiresAt":"2027-01-01T00:00:00Z"}
            """)
        .Answer("GET", "/api/v1/profiles", $$"""
            {"formatVersion":2,"minimumClientVersion":"1.0","managementSetupRequired":false,"profiles":[
              {"id":"{{OwnerId}}","name":"Lucas","role":"owner","needsPinSetup":false,"pinProtectionEnabled":true},
              {"id":"{{KidId}}","name":"Mia","role":"user","needsPinSetup":false,"pinProtectionEnabled":false},
              {"id":"{{GuestId}}","name":"Guest","role":"user","needsPinSetup":true,"pinProtectionEnabled":true}]}
            """)
        .Answer("POST", $"/api/v1/profiles/{OwnerId}/unlock", """{"code":"invalid_profile_pin","message":"The PIN is not correct."}""", HttpStatusCode.Unauthorized)
        .Answer("POST", $"/api/v1/profiles/{OwnerId}/unlock", $$"""
            {"user":{"id":"{{OwnerId}}","username":"Lucas","role":"owner","createdAt":"2026-10-31T20:00:00Z"},
             "sessionId":"55555555-0000-4000-8000-000000000005","token":"profile-token-synthetic-000000000000000000001","expiresAt":"2027-01-01T00:00:00Z"}
            """);

    [AvaloniaFact]
    public void PairsChoosesAProfileAndOpensTheLibrary()
    {
        var server = ServerWithProfiles();
        var keyring = new MemoryCredentialStore();
        var window = TestWindows.Show(AppServices.ForTests(transport: server, credentials: keyring));
        window.Flow.ChooseMode(OperatingMode.Client);
        Pump();

        var connection = Assert.IsType<ConnectionView>(window.CurrentScreen);
        connection.Model.Address = "192.168.1.20";
        OpenAdvanced(window);
        Click(Visible<Button>(window, b => b.Content as string == "Connect"));
        Assert.True(connection.Model.IsVerifying, connection.Model.Error);
        Assert.Contains(window.CurrentScreen!.GetVisualDescendants().OfType<TextBlock>(), t => t.Text == "A1B2-C3D4-E5F6-0718-293A-4B5C");
        var pair = Visible<Button>(window, b => b.Content as string == "Pair This PC");
        Assert.False(pair.IsEnabled);
        Visible<CheckBox>(window, _ => true).IsChecked = true;
        Visible<TextBox>(window, t => AutomationProperties.GetName(t) == "Pairing Code").Text = "1234 5678";
        Pump();
        Assert.Equal("12345678", connection.Model.Code);
        Assert.True(pair.IsEnabled);
        Snapshot(window, "connection-verify");

        Click(pair);
        Assert.Equal(AppScreen.ProfilePicker, window.Flow.Screen);
        Assert.Equal(FakeServer.ServerId, keyring.Server?.ServerId);
        Assert.Equal(["aa:bb:cc:dd:ee:01"], keyring.Server?.WakeOnLanAddresses);
        var picker = Assert.IsType<ProfilePickerView>(window.CurrentScreen);
        Assert.Equal(3, picker.Model.Profiles.Count);
        Assert.False(Visible<Button>(window, b => AutomationProperties.GetName(b) == "Guest").IsEnabled);
        Snapshot(window, "profile-picker");

        Click(Visible<Button>(window, b => AutomationProperties.GetName(b) == "Lucas"));
        Assert.True(picker.Model.IsEnteringPin);
        Visible<TextBox>(window, t => AutomationProperties.GetName(t) == "PIN").Text = "1111";
        Click(Visible<Button>(window, b => AutomationProperties.GetName(b) == "Open Profile"));
        Assert.Equal("PIN is incorrect.", picker.Model.Error);
        Snapshot(window, "profile-pin-wrong");

        Visible<TextBox>(window, t => AutomationProperties.GetName(t) == "PIN").Text = "4321";
        Click(Visible<Button>(window, b => AutomationProperties.GetName(b) == "Open Profile"));
        Assert.Equal(AppScreen.Library, window.Flow.Screen);
        Assert.Equal("Lucas", window.Session.Profile?.User.Username);
        Assert.Contains(window.Shell!.GetVisualDescendants().OfType<TextBlock>(), t => t.Text == "Lucas");
        Snapshot(window, "library-with-profile");
    }

    [AvaloniaFact]
    public void ARejectedAddressShowsWhy()
    {
        var window = TestWindows.Show(AppServices.ForTests(transport: new FakeServer()));
        window.Flow.ChooseMode(OperatingMode.Client);
        Pump();
        var connection = Assert.IsType<ConnectionView>(window.CurrentScreen);
        connection.Model.Address = "http://insecure.example";
        OpenAdvanced(window);
        Click(Visible<Button>(window, b => b.Content as string == "Connect"));
        Assert.Equal("Enter a server address such as 192.168.1.20.", connection.Model.Error);
        Assert.False(connection.Model.IsVerifying);
    }

    [AvaloniaFact]
    public void AServerThatNeedsProfilesAsksForThePasswordAndPin()
    {
        var server = FakeServer.WithServerInfo().Answer("GET", "/api/v1/profiles",
            """{"formatVersion":2,"minimumClientVersion":"1.0","managementSetupRequired":true,"profiles":[]}""");
        var keyring = new MemoryCredentialStore
        {
            Server = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
                "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30)),
        };
        var window = TestWindows.Show(AppServices.ForTests(transport: server, credentials: keyring));
        Pump();
        Assert.Equal(AppScreen.ProfilePicker, window.Flow.Screen);
        var picker = Assert.IsType<ProfilePickerView>(window.CurrentScreen);
        Assert.True(picker.Model.NeedsSetup);
        Assert.Contains(window.CurrentScreen!.GetVisualDescendants().OfType<TextBlock>(), t => t.Text == "Set Up Viewing Profiles");
        Snapshot(window, "profile-setup");
    }

    [AvaloniaFact]
    public void ASilentServerOffersToTryAgain()
    {
        var keyring = new MemoryCredentialStore
        {
            Server = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
                "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30)),
        };
        var window = TestWindows.Show(AppServices.ForTests(transport: new UnreachableTransport(), credentials: keyring));
        Assert.IsType<StartingView>(window.CurrentScreen);
        window.Session.StopWaiting();
        for (var attempt = 0; attempt < 200 && window.Flow.Screen != AppScreen.ServerUnreachable; attempt++)
        {
            Pump();
            Thread.Sleep(10);
        }
        Assert.Equal(AppScreen.ServerUnreachable, window.Flow.Screen);
        Assert.NotNull(Visible<Button>(window, b => b.Content as string == "Try Again"));
        // No profile was opened, so no profile's downloads may be offered here.
        Assert.DoesNotContain(window.CurrentScreen!.GetVisualDescendants().OfType<TextBlock>(),
            t => t.IsEffectivelyVisible && t.Text == "Watch a Download");
        Snapshot(window, "server-unreachable");
    }

    private static T Visible<T>(MainWindow window, Func<T, bool> match) where T : Control =>
        window.CurrentScreen!.GetVisualDescendants().OfType<T>().Single(control => control.IsEffectivelyVisible && match(control));

    private static void OpenAdvanced(MainWindow window)
    {
        Visible<Expander>(window, e => e.Header as string == "Advanced").IsExpanded = true;
        Pump();
    }

    private static void Click(Button button)
    {
        button.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        Pump();
    }

    private static void Pump()
    {
        for (var index = 0; index < 5; index++)
        {
            Dispatcher.UIThread.RunJobs();
            Thread.Sleep(5);
        }
        Dispatcher.UIThread.RunJobs();
    }

    private static void Snapshot(MainWindow window, string name)
    {
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, name);
    }

    /// <summary>A network where the server never answers.</summary>
    private sealed class UnreachableTransport : Aurelia.Linux.Core.Api.IServerTransport
    {
        public HttpClient CreateClient(Uri address, string? expectedFingerprint, Aurelia.Linux.Core.Api.CapturedFingerprint? captured, TimeSpan timeout) =>
            new(new Failing()) { BaseAddress = address, Timeout = timeout };

        private sealed class Failing : HttpMessageHandler
        {
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
                throw new HttpRequestException("no route");
        }
    }
}
