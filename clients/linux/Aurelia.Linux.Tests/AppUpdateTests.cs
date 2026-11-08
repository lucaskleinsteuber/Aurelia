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
    [Fact]
    public async Task PublicTestPagesAndDownloadsSendNoCredentials()
    {
        var settings = new MemorySettingsStore();
        settings.Write(UpdateFeed.PublicTestKey, true);
        var audit = Path.Combine(Path.GetTempPath(), "aurelia-update-audit-" + Guid.NewGuid().ToString("N"), "audit.jsonl");
        var page = ReleaseNode("linux-app-1.0.0-5");
        foreach (var asset in page["assets"]!.AsArray().OfType<JsonObject>())
            asset["url"] = asset["url"]!.GetValue<string>().Replace(AppRelease.Repository, UpdateFeed.PublicTestRepository, StringComparison.Ordinal);
        var handler = new FeedHandler((request, index) =>
        {
            if (index == 1)
            {
                var first = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("[]") };
                first.Headers.Add("Link", "<https://api.github.com/repositories/123/releases?per_page=100&page=2>; rel=\"next\"");
                return first;
            }
            if (index == 2) return new(HttpStatusCode.OK) { Content = new StringContent(new JsonArray(page).ToJsonString()) };
            return new(HttpStatusCode.OK)
            {
                Content = request.RequestUri!.AbsolutePath.EndsWith("/10", StringComparison.Ordinal)
                ? new ByteArrayContent(Package) : new StringContent("synthetic-checksums")
            };
        });
        try
        {
            using var source = new GitHubReleaseSource(handler, settings, audit);
            var releases = await source.ReleasesAsync(TestContext.Current.CancellationToken);
            Assert.EndsWith("/repos/" + UpdateFeed.PublicTestRepository + "/releases?per_page=100&page=2", handler.Requests[1], StringComparison.Ordinal);
            var release = AppRelease.Newest(releases, LinuxPackageKind.Arch, new Version(0, 3, 0), 4, UpdateFeed.PublicTestRepository);
            Assert.NotNull(release);
            Assert.Null(AppRelease.Newest(releases, LinuxPackageKind.Arch, new Version(0, 3, 0), 4));
            Assert.Equal("synthetic-checksums", await source.ChecksumsAsync(release, TestContext.Current.CancellationToken));
            using var bytes = new MemoryStream();
            await source.DownloadAsync(release, bytes, TestContext.Current.CancellationToken);
            Assert.Equal(Package, bytes.ToArray());
            Assert.All(handler.Authorization, Assert.Null);
            var lines = await File.ReadAllLinesAsync(audit, TestContext.Current.CancellationToken);
            Assert.Equal(4, lines.Length);
            Assert.All(lines, line => Assert.Contains("\"authorizationPresent\":false", line, StringComparison.Ordinal));
        }
        finally { if (Directory.Exists(Path.GetDirectoryName(audit))) Directory.Delete(Path.GetDirectoryName(audit)!, true); }
    }

    [Fact]
    public async Task ReleaseSearchLimitFailsInsteadOfReportingUpToDate()
    {
        var handler = new FeedHandler((_, index) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("[]") };
            response.Headers.Add("Link", $"<https://api.github.com/repos/{AppRelease.Repository}/releases?per_page=100&page={index + 1}>; rel=\"next\"");
            return response;
        });
        using var source = new GitHubReleaseSource(handler);
        var failure = await Assert.ThrowsAsync<IOException>(() => source.ReleasesAsync(TestContext.Current.CancellationToken));
        Assert.Contains("could not be completed", failure.Message, StringComparison.Ordinal);
        Assert.Equal(10, handler.Requests.Count);
    }

    [Fact]
    public async Task UnexpectedPaginationHostIsNeverContacted()
    {
        var handler = new FeedHandler((_, _) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("[]") };
            response.Headers.Add("Link", "<https://elsewhere.invalid/releases?page=2>; rel=\"next\"");
            return response;
        });
        using var source = new GitHubReleaseSource(handler);
        await Assert.ThrowsAsync<IOException>(() => source.ReleasesAsync(TestContext.Current.CancellationToken));
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task ReturningToTheStandardFeedDropsTheTestOfferAndPreservesSettings()
    {
        var settings = new MemorySettingsStore();
        settings.Write("unrelated", "preserved");
        using var updater = new AppUpdater(new FakeSource(), new FakeInstaller(), settings, "unused", new Version(0, 3, 0), 4, architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
        await updater.CheckAsync(true, TestContext.Current.CancellationToken);
        Assert.NotNull(updater.Available);
        updater.SetPublicUpdateTest(true);
        Assert.True(updater.PublicUpdateTestEnabled);
        Assert.Null(updater.Available);
        updater.SetPublicUpdateTest(false);
        Assert.Equal(AppRelease.Repository, UpdateFeed.Repository(settings));
        Assert.Equal("preserved", settings.Read<string>("unrelated"));
    }

    private sealed class FeedHandler(Func<HttpRequestMessage, int, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<string> Requests { get; } = [];
        public List<string?> Authorization { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            Requests.Add(request.RequestUri!.AbsoluteUri);
            Authorization.Add(request.Headers.Authorization?.ToString());
            return Task.FromResult(respond(request, Requests.Count));
        }
    }

    [AvaloniaFact]
    public void TheUpdatePageChecksAndRequiresConfirmationBeforeInstallation()
    {
        var cache = Path.Combine(Path.GetTempPath(), "aurelia-update-ui-" + Guid.NewGuid().ToString("N"));
        var installer = new FakeInstaller();
        using var updater = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4, architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
        var services = AppServices.ForTests() with { Updater = updater };
        var window = TestWindows.Show(services);
        var settings = window.OpenSettings(SettingsCategory.Updates);
        FakeLibrary.Pump(() => settings.GetVisualDescendants().OfType<Button>().Any(), rounds: 20);
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
    public void BetaReleasesAreOfferedOnlyWhenBetaUpdatesAreOn()
    {
        var stable = ReleaseNode("linux-app-1.0.0-5");
        var beta = ReleaseNode("linux-app-1.1.0-6");
        beta["prerelease"] = true;
        beta["assets"]![0]!["name"] = "Aurelia-Desktop-1.1.0-6-x86_64.pkg.tar.zst";
        var releases = new JsonArray(beta, stable);

        var normal = AppRelease.Newest(releases, LinuxPackageKind.Arch, new Version(0, 3, 0), 4);
        Assert.Equal("linux-app-1.0.0-5", normal?.Tag);
        Assert.False(normal?.IsBeta);
        var tester = AppRelease.Newest(releases, LinuxPackageKind.Arch, new Version(0, 3, 0), 4, includeBeta: true);
        Assert.Equal("linux-app-1.1.0-6", tester?.Tag);
        Assert.True(tester?.IsBeta);
    }

    [Fact]
    public async Task ReadsTheCanonicalRepositoryAndItsUploadedAssetsWithoutARedirect()
    {
        var handler = new CanonicalRepositoryHandler();
        using var source = new GitHubReleaseSource(handler);

        var releases = await source.ReleasesAsync(TestContext.Current.CancellationToken);
        Assert.Equal("https://api.github.com/repos/lucaskleinsteuber/Aurelia/releases?per_page=100", Assert.Single(handler.Requests));
        var release = AppRelease.Newest(releases, LinuxPackageKind.Arch, new Version(0, 3, 0), 4);
        Assert.NotNull(release);
        Assert.Equal("https://api.github.com/repos/lucaskleinsteuber/Aurelia/releases/assets/10", release.Download.AbsoluteUri);
        Assert.Equal("synthetic-checksums", await source.ChecksumsAsync(release, TestContext.Current.CancellationToken));
        Assert.Equal("https://api.github.com/repos/lucaskleinsteuber/Aurelia/releases/assets/11", handler.Requests[1]);
    }

    [Theory]
    [InlineData("someone-else/Aurelia")]
    [InlineData("lucaskleinsteuber/AnotherRepository")]
    public void RejectsPackagesAndChecksumsFromAnotherRepository(string repository)
    {
        foreach (var index in new[] { 0, 1 })
        {
            var release = ReleaseNode("linux-app-1.0.0-5");
            release["assets"]![index]!["url"] = $"https://api.github.com/repos/{repository}/releases/assets/10";
            Assert.Null(AppRelease.Newest(new JsonArray(release), LinuxPackageKind.Arch, new Version(0, 3, 0), 4));
        }
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
        using var updater = new AppUpdater(source, installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4, architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
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
        using var updater = new AppUpdater(source, installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4, architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
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
        using var updater = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4, architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
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
        using var updater = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4, architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
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
        using var updater = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4, architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
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
        using var updater = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4, architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
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
        using var updater = new AppUpdater(source, new FakeInstaller(), settings, "/unused", new Version(0, 3, 0), 4, architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
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
    public async Task UpdateRequestsCarryNoCredentials()
    {
        var handler = new RedirectHandler();
        using var source = new GitHubReleaseSource(handler);
        var release = AppRelease.Newest(new JsonArray(ReleaseNode("linux-app-1.0.0-5")), LinuxPackageKind.Arch, new Version(0, 3, 0), 4)!;
        await source.ChecksumsAsync(release, TestContext.Current.CancellationToken);
        Assert.Equal([null, null], handler.Authorization);
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
            new JsonObject { ["name"] = FileName, ["state"] = "uploaded", ["size"] = (long)Package.Length, ["url"] = "https://api.github.com/repos/lucaskleinsteuber/Aurelia/releases/assets/10" },
            new JsonObject { ["name"] = "SHA256SUMS", ["state"] = "uploaded", ["size"] = 100, ["url"] = "https://api.github.com/repos/lucaskleinsteuber/Aurelia/releases/assets/11" },
            new JsonObject { ["name"] = AppRelease.SignatureFile, ["state"] = "uploaded", ["size"] = 300, ["url"] = "https://api.github.com/repos/lucaskleinsteuber/Aurelia/releases/assets/12" }),
    };

    // Written by an independent minisign-format signer (Python "cryptography" and hashlib), so the
    // check is compatible with real "minisign -S" output and not only with this app's own signer.
    private const string ReferenceKey = "RWQ3Z8/6xRPKcvIejyLy7FUdMIMCUMx0JGKGTQSgupGaXVpmaRj+YaBD";
    private const string ReferenceSignature = "untrusted comment: signature from minisign secret key\nRUQ3Z8/6xRPKcuCiR8cKssywN1/LOZmWmV25gMoG6rm9Y1CowX7YVky2H9hOtscwJxPB75jmWuuY5+SGTUkwfiqIpSqG61UrJg8=\ntrusted comment: timestamp:1762550000\tfile:SHA256SUMS\thashed\nRPPoaDa2hlW8/UiEZ84NoCRXpA6+b0zvMMES3M8AzifQ/gw4gxqVekOg1g+xuC+TjwX/s+T0BEGfPKoc37KvBg==\n";
    private const string ReferenceLegacy = "untrusted comment: signature from minisign secret key\nRWQ3Z8/6xRPKcuRM2kYmMyRFVvTSFOL6Hak5S5BgkVP3h+VhvIqkN+Au8SjOZeeBObvG3CNIjfcfsAJwtgq89a0r1Cm8cFBhdAI=\ntrusted comment: legacy\nzJpgVNmDO2s5QeZNwVvTRC0ee9KsPktpkL8MYjf1dX01XqldnaJbCuEiD7EN9LHxMhHMEOs1iz+W6xNWW5VmAA==\n";

    [Fact]
    public void ReadsMinisignSignaturesAndRejectsAnyChange()
    {
        var sums = Encoding.UTF8.GetBytes(new FakeSource().Sums);
        Assert.True(MinisignSignature.Verify(sums, ReferenceSignature, ReferenceKey));
        Assert.True(MinisignSignature.Verify("hello"u8, ReferenceLegacy, ReferenceKey));
        // Another file, another key, or a changed trusted comment are all refused.
        Assert.False(MinisignSignature.Verify(Encoding.UTF8.GetBytes(new string('0', 64) + "  " + FileName), ReferenceSignature, ReferenceKey));
        Assert.False(MinisignSignature.Verify(sums, ReferenceSignature, TestSigning.PublicKey));
        Assert.False(MinisignSignature.Verify(sums, ReferenceSignature.Replace("hashed", "hashes", StringComparison.Ordinal), ReferenceKey));
        Assert.False(MinisignSignature.Verify(sums, "not a signature", ReferenceKey));
        Assert.False(MinisignSignature.Verify(sums, ReferenceSignature, ""));
        Assert.True(MinisignSignature.Verify(sums, TestSigning.Sign(new FakeSource().Sums), TestSigning.PublicKey));
    }

    [Fact]
    public async Task APackageWhoseChecksumListIsNotSignedByTheOwnerIsNeverInstalled()
    {
        // Someone with access to the GitHub release replaced the package and its checksum list.
        var forged = new string('a', 64) + "  " + FileName;
        foreach (var source in new[]
        {
            new FakeSource { Sums = forged, Signature = TestSigning.Sign(new FakeSource().Sums) },
            new FakeSource { Signature = ReferenceSignature },
        })
        {
            var installer = new FakeInstaller();
            var cache = Path.Combine(Path.GetTempPath(), "aurelia-update-" + Guid.NewGuid().ToString("N"));
            using var updater = new AppUpdater(source, installer, new MemorySettingsStore(), cache, new Version(0, 3, 0), 4,
                architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
            try
            {
                await updater.CheckAsync(true, TestContext.Current.CancellationToken);
                Assert.False(await updater.InstallAsync(() => { installer.Prepared = true; return Task.CompletedTask; }, TestContext.Current.CancellationToken));
                Assert.False(installer.Installed);
                Assert.Contains("signature", updater.Status, StringComparison.Ordinal);
            }
            finally { if (Directory.Exists(cache)) Directory.Delete(cache, true); }
        }
    }

    [Fact]
    public async Task WithoutASignatureOrAKeyNothingIsInstalled()
    {
        var unsigned = new UnsignedSource();
        var installer = new FakeInstaller();
        using (var updater = new AppUpdater(unsigned, installer, new MemorySettingsStore(), Path.GetTempPath(), new Version(0, 3, 0), 4,
            architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey))
        {
            await updater.CheckAsync(true, TestContext.Current.CancellationToken);
            Assert.NotNull(updater.Available);
            Assert.False(await updater.InstallAsync(cancellation: TestContext.Current.CancellationToken));
            Assert.Contains("not signed", updater.Status, StringComparison.Ordinal);
        }
        using var keyless = new AppUpdater(new FakeSource(), installer, new MemorySettingsStore(), Path.GetTempPath(), new Version(0, 3, 0), 4,
            architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: "");
        await keyless.CheckAsync(true, TestContext.Current.CancellationToken);
        Assert.False(await keyless.InstallAsync(cancellation: TestContext.Current.CancellationToken));
        Assert.Contains("cannot check update signatures", keyless.Status, StringComparison.Ordinal);
        Assert.False(installer.Installed);
    }

    private sealed class UnsignedSource : IReleaseSource
    {
        public Task<JsonArray> ReleasesAsync(CancellationToken cancellation)
        {
            var release = ReleaseNode("linux-app-1.0.0-5");
            release["assets"]!.AsArray().RemoveAt(2);
            return Task.FromResult(new JsonArray(release));
        }
        public Task<string> ChecksumsAsync(AppRelease release, CancellationToken cancellation) => Task.FromResult(new FakeSource().Sums);
        public Task<string> SignatureAsync(AppRelease release, CancellationToken cancellation) => throw new IOException("Never asked without a signature asset.");
        public Task DownloadAsync(AppRelease release, Stream destination, CancellationToken cancellation) => throw new IOException("Never downloaded.");
    }

    private sealed class FakeSource : IReleaseSource
    {
        public string Sums { get; init; } = Convert.ToHexStringLower(SHA256.HashData(Package)) + "  " + FileName;
        public int Checks { get; private set; }
        public Task<JsonArray> ReleasesAsync(CancellationToken cancellation) { Checks++; return Task.FromResult(new JsonArray(ReleaseNode("linux-app-1.0.0-5"))); }
        public Task<string> ChecksumsAsync(AppRelease release, CancellationToken cancellation) => Task.FromResult(Sums);
        /// <summary>Signed with the test key by default; a test may supply another signature.</summary>
        public string? Signature { get; init; }
        public Task<string> SignatureAsync(AppRelease release, CancellationToken cancellation) => Task.FromResult(Signature ?? TestSigning.Sign(Sums));
        public async Task DownloadAsync(AppRelease release, Stream destination, CancellationToken cancellation) => await destination.WriteAsync(Package, cancellation);
    }

    [Fact]
    public async Task WithoutASupportedPackageManagerOnlyUpdatingIsUnavailable()
    {
        // Creating the installer must not fail, or the app would not open on such a distribution.
        var installer = new LinuxPackageInstaller();
        using var updater = new AppUpdater(new FakeSource(), new UnsupportedInstaller(), new MemorySettingsStore(), "unused", new Version(0, 3, 0), 4, architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
        await updater.CheckAsync(true, TestContext.Current.CancellationToken);
        Assert.Null(updater.Available);
        Assert.Contains("no supported package manager", updater.Status, StringComparison.Ordinal);
        Assert.False(updater.IsBusy);
        Assert.NotNull(installer);
    }

    [Fact]
    public async Task OtherArchitecturesAreNotOfferedAPackage()
    {
        var source = new FakeSource();
        using var updater = new AppUpdater(source, new FakeInstaller(), new MemorySettingsStore(), "unused", new Version(0, 3, 0), 4,
            architecture: System.Runtime.InteropServices.Architecture.Arm, signingKey: TestSigning.PublicKey);
        await updater.CheckAsync(true, TestContext.Current.CancellationToken);
        Assert.Null(updater.Available);
        Assert.Equal(0, source.Checks);
        Assert.Contains("64-bit Intel, AMD and ARM", updater.Status, StringComparison.Ordinal);
    }

    [Fact]
    public void Arm64ComputersTakeTheArm64PackageOfTheirDistribution()
    {
        var version = new Version(2, 0, 0);
        Assert.Equal("Aurelia-Desktop-2.0.0-25-arm64.deb", AppRelease.PackageName(version, 25, LinuxPackageKind.Debian, arm64: true));
        Assert.Equal("Aurelia-Desktop-2.0.0-25-aarch64.rpm", AppRelease.PackageName(version, 25, LinuxPackageKind.Rpm, arm64: true));
        Assert.Equal("Aurelia-Desktop-2.0.0-25-aarch64.pkg.tar.zst", AppRelease.PackageName(version, 25, LinuxPackageKind.Arch, arm64: true));
        Assert.Equal("Aurelia-Desktop-2.0.0-25-amd64.deb", AppRelease.PackageName(version, 25, LinuxPackageKind.Debian));
        Assert.Equal("Aurelia-Desktop-2.0.0-25-x86_64.pkg.tar.zst", AppRelease.PackageName(version, 25, LinuxPackageKind.Arch));
    }

    [Fact]
    public async Task AFailedAutomaticCheckIsTriedAgainAtTheNextStart()
    {
        var settings = new MemorySettingsStore();
        var failing = new FailingSource();
        using (var updater = new AppUpdater(failing, new FakeInstaller(), settings, "unused", new Version(0, 3, 0), 4,
            architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey))
        {
            await updater.CheckAsync(false, TestContext.Current.CancellationToken);
            Assert.Contains("limiting", updater.Status, StringComparison.Ordinal);
        }
        var source = new FakeSource();
        using var next = new AppUpdater(source, new FakeInstaller(), settings, "unused", new Version(0, 3, 0), 4,
            architecture: System.Runtime.InteropServices.Architecture.X64, signingKey: TestSigning.PublicKey);
        await next.CheckAsync(false, TestContext.Current.CancellationToken);
        Assert.Equal(1, source.Checks);
        Assert.NotNull(next.Available);
    }

    private sealed class FailingSource : IReleaseSource
    {
        public Task<JsonArray> ReleasesAsync(CancellationToken cancellation) =>
            throw new IOException("GitHub is limiting update checks right now. Try again in about an hour.");
        public Task<string> ChecksumsAsync(AppRelease release, CancellationToken cancellation) => throw new IOException("unused");
        public Task<string> SignatureAsync(AppRelease release, CancellationToken cancellation) => throw new IOException("unused");
        public Task DownloadAsync(AppRelease release, Stream destination, CancellationToken cancellation) => throw new IOException("unused");
    }

    private sealed class UnsupportedInstaller : IPackageInstaller
    {
        public LinuxPackageKind Kind => LinuxPackageInstaller.Detect(_ => false);
        public Task InstallAsync(string path, CancellationToken cancellation) => throw new InvalidOperationException("Never installs.");
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

    private sealed class CanonicalRepositoryHandler : HttpMessageHandler
    {
        public List<string> Requests { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            Requests.Add(request.RequestUri!.AbsoluteUri);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(Requests.Count == 1
                    ? new JsonArray(ReleaseNode("linux-app-1.0.0-5")).ToJsonString()
                    : "synthetic-checksums"),
            });
        }
    }
}
