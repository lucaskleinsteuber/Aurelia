using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Updates;
using Aurelia.Linux.Settings;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class AppUpdateTests
{
    [AvaloniaFact]
    public void TheUpdatePageChecksAndRequiresConfirmationBeforeInstallation()
    {
        var cache = Path.Combine(Path.GetTempPath(), "aurelia-update-ui-" + Guid.NewGuid().ToString("N"));
        var installer = new FakeInstaller();
        using var updater = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4);
        var services = AppServices.ForTests() with { Updater = updater };
        var window = TestWindows.Show(services);
        var settings = window.OpenSettings(SettingsCategory.Updates);
        var quit = false;
        settings.QuitAfterUpdate = () => quit = true;
        settings.InstallUpdate = () => updater.InstallAsync(() => { installer.Prepared = true; return Task.CompletedTask; });
        void Click(Control root, string label) => root.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == label)
            .RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        try
        {
            Click(settings, "Check for Updates");
            FakeLibrary.Pump(() => updater.Available is not null);
            Click(settings, "Download & Install…");
            Assert.True(settings.Sheets.IsShowing);
            Assert.False(installer.Installed);
            Click(settings.Sheets, "Install Update");
            FakeLibrary.Pump(() => installer.Installed);
            Assert.True(installer.Installed);
            FakeLibrary.Pump(() => settings.GetVisualDescendants().OfType<Button>().Any(b => b.Content as string == "Quit Aurelia"));
            Click(settings, "Quit Aurelia");
            Assert.True(quit);
        }
        finally { settings.Close(); if (Directory.Exists(cache)) Directory.Delete(cache, true); }
    }

    [Theory]
    [InlineData("1.0.0-5")]
    [InlineData("linux-app-01.0.0-5")]
    [InlineData("linux-app-1.0-5")]
    [InlineData("linux-app-1.0.0-0")]
    [InlineData("linux-app-1.0.0-05")]
    [InlineData("linux-app-1.0.0-5-beta")]
    public void RejectsMacServerAndMalformedTags(string tag) => Assert.Null(AppRelease.ParseTag(tag));

    [Fact]
    public void SelectsOnlyACompleteNewerLinuxReleaseForTheInstalledPackage()
    {
        var good = ReleaseNode("linux-app-1.0.0-5");
        var draft = ReleaseNode("linux-app-1.1.0-6");
        draft["draft"] = true;
        var wrongHost = ReleaseNode("linux-app-1.2.0-7");
        wrongHost["assets"]![0]!["url"] = "https://example.org/update.deb";
        var releases = new JsonArray(ReleaseNode("1.26.3-120"), draft, wrongHost, good);
        var release = AppRelease.Newest(releases, LinuxPackageKind.Arch, new Version(0, 3, 0), 4);
        Assert.Equal("linux-app-1.0.0-5", release?.Tag);
        Assert.Null(AppRelease.Newest(releases, LinuxPackageKind.Arch, new Version(1, 0, 0), 5));
        Assert.Null(AppRelease.Newest(releases, LinuxPackageKind.Debian, new Version(0, 3, 0), 4));
        Assert.Null(AppRelease.Newest(releases, LinuxPackageKind.Arch, new Version(2, 0, 0), 4));
    }

    [Fact]
    public void ChecksumMustIdentifyTheExactPackageOnce()
    {
        var hash = new string('a', 64);
        Assert.Equal(hash, AppRelease.Checksum("a.deb", hash + "  ./a.deb\n"));
        Assert.Equal(hash, AppRelease.Checksum("a.deb", hash + " *a.deb\n"));
        Assert.Null(AppRelease.Checksum("a.deb", hash + "  ../a.deb\n"));
        Assert.Null(AppRelease.Checksum("a.deb", hash + " a.deb\n" + hash + " a.deb\n"));
    }

    [Fact]
    public async Task NeverStopsTheHostOrInstallsADamagedDownload()
    {
        var source = new FakeSource { Sums = new string('0', 64) + "  " + FileName };
        var installer = new FakeInstaller();
        var cache = Path.Combine(Path.GetTempPath(), "aurelia-update-" + Guid.NewGuid().ToString("N"));
        using var updater = new AppUpdater(source, installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4);
        try
        {
            await updater.CheckAsync(true, TestContext.Current.CancellationToken);
            var prepared = false;
            Assert.False(await updater.InstallAsync(() => { prepared = true; return Task.CompletedTask; }, TestContext.Current.CancellationToken));
            Assert.False(prepared);
            Assert.False(installer.Installed);
            Assert.Contains("checksum", updater.Status, StringComparison.Ordinal);
            Assert.Empty(Directory.GetFiles(cache, "*", SearchOption.AllDirectories));
        }
        finally { if (Directory.Exists(cache)) Directory.Delete(cache, true); }
    }

    [Fact]
    public async Task VerifiesThenPreparesThenInstallsAndRemovesTheDownload()
    {
        var source = new FakeSource();
        var installer = new FakeInstaller();
        var cache = Path.Combine(Path.GetTempPath(), "aurelia-update-" + Guid.NewGuid().ToString("N"));
        using var updater = new AppUpdater(source, installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4);
        try
        {
            await updater.CheckAsync(true, TestContext.Current.CancellationToken);
            Assert.True(await updater.InstallAsync(() => { installer.Prepared = true; return Task.CompletedTask; }, TestContext.Current.CancellationToken));
            Assert.True(installer.Installed);
            Assert.Null(updater.Available);
            Assert.Empty(Directory.GetFiles(cache, "*", SearchOption.AllDirectories));
        }
        finally { if (Directory.Exists(cache)) Directory.Delete(cache, true); }
    }

    [Fact]
    public async Task PreparationFailureIsReportedWithoutInvokingThePackageManager()
    {
        var cache = Path.Combine(Path.GetTempPath(), "aurelia-update-preparation-" + Guid.NewGuid().ToString("N"));
        var installer = new FakeInstaller();
        using var updater = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4);
        try
        {
            await updater.CheckAsync(true, TestContext.Current.CancellationToken);
            Assert.False(await updater.InstallAsync(() => throw new AureliaApiException(503, "unreachable", "Synthetic stop failure"), TestContext.Current.CancellationToken));
            Assert.False(installer.Installed);
            Assert.False(updater.IsBusy);
            Assert.NotNull(updater.Available);
            Assert.Empty(Directory.GetFiles(cache, "*", SearchOption.AllDirectories));
        }
        finally { if (Directory.Exists(cache)) Directory.Delete(cache, true); }
    }

    [Fact]
    public async Task CancellationBeforeThePackageManagerDoesNotStartATransaction()
    {
        var cache = Path.Combine(Path.GetTempPath(), "aurelia-update-cancel-" + Guid.NewGuid().ToString("N"));
        var installer = new FakeInstaller();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        using var updater = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4);
        try
        {
            await updater.CheckAsync(true, cancellation.Token);
            Assert.False(await updater.InstallAsync(() => { cancellation.Cancel(); return Task.CompletedTask; }, cancellation.Token));
            Assert.False(installer.Installed);
            Assert.False(updater.IsBusy);
            Assert.Contains("cancelled", updater.Status, StringComparison.Ordinal);
            Assert.Empty(Directory.GetFiles(cache, "*", SearchOption.AllDirectories));
        }
        finally { if (Directory.Exists(cache)) Directory.Delete(cache, true); }
    }

    [Fact]
    public async Task DeniedCacheAccessIsReportedAndDoesNotLeaveTheUpdaterBusy()
    {
        if (OperatingSystem.IsWindows())
        {
            Assert.Skip("Unix directory permissions.");
            return;
        }
        var cache = Path.Combine(Path.GetTempPath(), "aurelia-update-denied-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(cache);
        File.SetUnixFileMode(cache, UnixFileMode.UserRead | UnixFileMode.UserExecute);
        var installer = new FakeInstaller();
        using var updater = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4);
        try
        {
            await updater.CheckAsync(true, TestContext.Current.CancellationToken);
            Assert.False(await updater.InstallAsync(cancellation: TestContext.Current.CancellationToken));
            Assert.False(installer.Installed);
            Assert.False(updater.IsBusy);
        }
        finally
        {
            File.SetUnixFileMode(cache, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            Directory.Delete(cache, true);
        }
    }

    [Fact]
    public async Task CleanupFailureKeepsTheSuccessfulInstallResultAndClearsBusy()
    {
        if (OperatingSystem.IsWindows())
        {
            Assert.Skip("Unix directory permissions.");
            return;
        }
        var cache = Path.Combine(Path.GetTempPath(), "aurelia-update-cleanup-" + Guid.NewGuid().ToString("N"));
        var installer = new FakeInstaller { Prepared = true, DenyCleanup = true };
        using var updater = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4);
        try
        {
            await updater.CheckAsync(true, TestContext.Current.CancellationToken);
            Assert.True(await updater.InstallAsync(cancellation: TestContext.Current.CancellationToken));
            Assert.True(installer.Installed);
            Assert.False(updater.IsBusy);
            Assert.Null(updater.Available);
            Assert.Contains("installed", updater.Status, StringComparison.Ordinal);
        }
        finally
        {
            if (installer.DownloadDirectory is { } directory && Directory.Exists(directory))
                File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            if (Directory.Exists(cache)) Directory.Delete(cache, true);
        }
    }

    [Fact]
    public async Task AutomaticChecksRespectThePreferenceAndDailyInterval()
    {
        var source = new FakeSource();
        var settings = new MemorySettingsStore();
        using var updater = new AppUpdater(source, new FakeInstaller(), settings, "/unused", new Version(0, 3, 0), 4);
        settings.Write("automaticUpdateChecks", false);
        await updater.CheckAsync(false, TestContext.Current.CancellationToken);
        Assert.Equal(0, source.Checks);
        await updater.CheckAsync(true, TestContext.Current.CancellationToken);
        settings.Write("automaticUpdateChecks", true);
        await updater.CheckAsync(false, TestContext.Current.CancellationToken);
        Assert.Equal(1, source.Checks);
        await updater.CheckAsync(true, TestContext.Current.CancellationToken);
        Assert.Equal(2, source.Checks);
    }

    [Fact]
    public async Task TheGitHubTokenIsRemovedFromAssetRedirects()
    {
        var handler = new RedirectHandler();
        using var source = new GitHubReleaseSource(new FakeTokens(), handler);
        var release = AppRelease.Newest(new JsonArray(ReleaseNode("linux-app-1.0.0-5")), LinuxPackageKind.Arch, new Version(0, 3, 0), 4)!;
        await source.ChecksumsAsync(release, TestContext.Current.CancellationToken);
        Assert.Equal(["Bearer synthetic-token", null], handler.Authorization);
    }

    [Theory]
    [InlineData(LinuxPackageKind.Arch, "/usr/bin/pacman")]
    [InlineData(LinuxPackageKind.Debian, "/usr/bin/apt-get")]
    [InlineData(LinuxPackageKind.Rpm, "/usr/bin/dnf")]
    public void NativeInstallsUsePkexecAndLiteralArguments(LinuxPackageKind kind, string manager)
    {
        var path = "/home/test/a package;$(touch bad).deb";
        var command = LinuxPackageInstaller.Command(kind, path);
        Assert.Equal("/usr/bin/pkexec", command.Executable);
        Assert.Equal(manager, command.Arguments[0]);
        Assert.Equal(path, command.Arguments[^1]);
    }

    private const string FileName = "Aurelia-Desktop-1.0.0-5-x86_64.pkg.tar.zst";
    private static readonly byte[] Package = Encoding.UTF8.GetBytes("synthetic-package-never-executed");

    private static JsonObject ReleaseNode(string tag) => new()
    {
        ["tag_name"] = tag,
        ["draft"] = false,
        ["prerelease"] = false,
        ["assets"] = new JsonArray(
            new JsonObject { ["name"] = FileName, ["state"] = "uploaded", ["size"] = (long)Package.Length, ["url"] = "https://api.github.com/repos/lucasfd3/Aurelia/releases/assets/10" },
            new JsonObject { ["name"] = "SHA256SUMS", ["state"] = "uploaded", ["size"] = 100, ["url"] = "https://api.github.com/repos/lucasfd3/Aurelia/releases/assets/11" }),
    };

    private sealed class FakeSource : IReleaseSource
    {
        public string Sums { get; init; } = Convert.ToHexStringLower(SHA256.HashData(Package)) + "  " + FileName;
        public int Checks { get; private set; }
        public Task<JsonArray> ReleasesAsync(CancellationToken cancellation) { Checks++; return Task.FromResult(new JsonArray(ReleaseNode("linux-app-1.0.0-5"))); }
        public Task<string> ChecksumsAsync(AppRelease release, CancellationToken cancellation) => Task.FromResult(Sums);
        public async Task DownloadAsync(AppRelease release, Stream destination, CancellationToken cancellation) => await destination.WriteAsync(Package, cancellation);
    }

    private sealed class FakeInstaller : IPackageInstaller
    {
        public LinuxPackageKind Kind => LinuxPackageKind.Arch;
        public bool Prepared { get; set; }
        public bool Installed { get; private set; }
        public bool DenyCleanup { get; init; }
        public string? DownloadDirectory { get; private set; }
        public Task InstallAsync(string path, CancellationToken cancellation)
        {
            Assert.True(Prepared);
            Assert.Equal(Package, File.ReadAllBytes(path));
            Installed = true;
            if (DenyCleanup && !OperatingSystem.IsWindows())
            {
                DownloadDirectory = Path.GetDirectoryName(path)!;
                File.SetUnixFileMode(DownloadDirectory, UnixFileMode.UserRead | UnixFileMode.UserExecute);
            }
            return Task.CompletedTask;
        }
    }

    private sealed class FakeTokens : IUpdateTokenStore
    {
        public Task<string?> LoadAsync(CancellationToken cancellation) => Task.FromResult<string?>("synthetic-token");
        public Task SaveAsync(string token, CancellationToken cancellation) => Task.CompletedTask;
        public Task DeleteAsync(CancellationToken cancellation) => Task.CompletedTask;
    }

    private sealed class RedirectHandler : HttpMessageHandler
    {
        public List<string?> Authorization { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            Authorization.Add(request.Headers.Authorization?.ToString());
            return Task.FromResult(Authorization.Count == 1
                ? new HttpResponseMessage(HttpStatusCode.Found) { Headers = { Location = new Uri("https://release-assets.githubusercontent.com/test?temporary=1") } }
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("synthetic-checksums") });
        }
    }
}
