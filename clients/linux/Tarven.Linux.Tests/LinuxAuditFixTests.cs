using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Tarven.Contracts;
using Tarven.Linux.Controls;
using Tarven.Linux.Core.Api;
using Tarven.Linux.Core.Management;
using Tarven.Linux.Core.Settings;
using Tarven.Linux.Core.Updates;
using Tarven.Linux.Library;
using Tarven.Linux.Settings;
using Avalonia.Headless.XUnit;
using Avalonia.Media;
using Xunit;

namespace Tarven.Linux.Tests;

/// <summary>The fixes of the Linux audit of 16.11.2026 that need no window. Invented data only.</summary>
public sealed class LinuxAuditFixTests
{
    [Fact]
    public void ReleaseNotesReadAsTextWithoutMarkdownMarks()
    {
        var blocks = ReleaseNotesText.Blocks("""
            > **Beta:** only apps with beta updates see this.

            ## What changed
            - People in the **sidebar**
            * A [release page](https://example.org/notes) link
            Plain `text` that
            continues here.
            """);
        Assert.Equal(
            [
                new(ReleaseNotesBlockKind.Paragraph, "Beta: only apps with beta updates see this."),
                new(ReleaseNotesBlockKind.Heading, "What changed"),
                new(ReleaseNotesBlockKind.Bullet, "People in the sidebar"),
                new(ReleaseNotesBlockKind.Bullet, "A release page link"),
                new(ReleaseNotesBlockKind.Paragraph, "Plain text that continues here."),
            ],
            blocks);
        Assert.Empty(ReleaseNotesText.Blocks(null));
        Assert.Empty(ReleaseNotesText.Blocks("  \n\n"));
    }

    [Fact]
    public async Task ADownloadReportsWholePercentsOnly()
    {
        var reported = new List<double>();
        using var target = new MemoryStream();
        await using var counting = new ProgressStream(target, 200, reported.Add);
        await counting.WriteAsync(new byte[1], TestContext.Current.CancellationToken);
        await counting.WriteAsync(new byte[1], TestContext.Current.CancellationToken);
        await counting.WriteAsync(new byte[98], TestContext.Current.CancellationToken);
        counting.Write(new byte[100], 0, 100);
        Assert.Equal([0.0, 0.01, 0.5, 1.0], reported);
        Assert.Equal(200, target.Length);
    }

    [Fact]
    public void UnchangedMetadataIsNotAnUnsavedChange()
    {
        static MediaEditorValues Values(string? overview, params string[] genres) => new("Invented Shore", 2018, overview, 101, 12,
            genres, ["Invented Studio"], null, [new EditorCredit(Guid.Empty, "Morgan Vale", "Acting", null, "Captain", null)], null, null);
        // Lists that are equal by content but not the same objects, and an empty text that is null on the server.
        Assert.True(MetadataEditing.Same(Values(null, "Drama"), Values("", "Drama")));
        Assert.False(MetadataEditing.Same(Values(null, "Drama"), Values(null, "Drama", "Mystery")));
        Assert.False(MetadataEditing.Same(Values("A"), Values("B")));
    }

    [Fact]
    public void TheWindowOpensAsItWasClosed()
    {
        var store = new MemorySettingsStore();
        Assert.Null(WindowPlacement.Read(store));
        new WindowPlacement(1400, 900, Maximized: true).Save(store);
        Assert.Equal(new WindowPlacement(1400, 900, true), WindowPlacement.Read(store));
        // A size below the window's minimum is never restored; a maximized window still opens maximized.
        new WindowPlacement(200, 100, Maximized: false).Save(store);
        Assert.Null(WindowPlacement.Read(store));
        new WindowPlacement(0, 0, Maximized: true).Save(store);
        Assert.Equal(new WindowPlacement(1280, 800, true), WindowPlacement.Read(store));
    }

    // Both helpers sit in classes whose static fields are Avalonia objects: they run on the UI thread.
    [AvaloniaTheory]
    [InlineData("Notifications")]
    [InlineData("Cinema Mode")]
    [InlineData("When Nobody Uses Tarven")]
    [InlineData("Server Health")]
    [InlineData("Performance")]
    [InlineData("Test Tools")]
    [InlineData("Legal")]
    [InlineData("Your Server")]
    public void EverySettingsSectionHasASymbol(string title) => Assert.NotNull(SettingsRows.SectionIcon(title));

    [AvaloniaTheory]
    [InlineData("Your Watchlist Is Empty", "IconWatchlist")]
    [InlineData("No Open Wishes", "IconWishes")]
    [InlineData("No Results", "IconSearch")]
    public void EmptyPagesShowTheirOwnSymbol(string title, string icon) => Assert.Equal(icon, LibraryPageBase.EmptyIcon(title));

    [Fact]
    public async Task ReadsTheAppMakesByItselfAreMarkedSoTheServerCanRest()
    {
        var handler = new Recording();
        using var client = new HttpClient(handler) { BaseAddress = new Uri("https://127.0.0.1:43120/") };
        await Send(client, HttpMethod.Get);
        Assert.False(handler.Last!.Headers.Contains(TarvenApi.BackgroundHeader));
        await TarvenApi.InBackgroundAsync(() => Send(client, HttpMethod.Get));
        Assert.Equal("1", Assert.Single(handler.Last!.Headers.GetValues(TarvenApi.BackgroundHeader)));
        // A change is always the owner's own action, even inside a background read.
        using (TarvenApi.Background()) await Send(client, HttpMethod.Post);
        Assert.False(handler.Last!.Headers.Contains(TarvenApi.BackgroundHeader));
        // The scope ends with its block.
        await Send(client, HttpMethod.Get);
        Assert.False(handler.Last!.Headers.Contains(TarvenApi.BackgroundHeader));
    }

    [AvaloniaFact]
    public void AProfileThatIsNotSavedYetHasNoColorThatChangesLater()
    {
        static string Top(ProfileAvatar avatar) => ((LinearGradientBrush)avatar.Background!).GradientStops[0].Color.ToString();
        Assert.Equal(Color.Parse(ProfileAvatar.UnsavedPalette.Top).ToString(), Top(new ProfileAvatar(null, "Mia", 72)));
        var saved = Guid.Parse("a0000000-0000-4000-8000-000000000007");
        Assert.NotEqual(Color.Parse(ProfileAvatar.UnsavedPalette.Top).ToString(), Top(new ProfileAvatar(saved, "Mia", 72)));
    }

    private static Task<JsonObject> Send(HttpClient client, HttpMethod method) =>
        TarvenApi.SendRequestAsync<JsonObject>(client, new HttpRequestMessage(method, "api/v1/invented"), inspecting: false, CancellationToken.None);

    private sealed class Recording : HttpMessageHandler
    {
        public HttpRequestMessage? Last { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Last = request;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{}", Encoding.UTF8, "application/json") });
        }
    }
}
