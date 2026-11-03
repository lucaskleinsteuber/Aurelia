using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Updates;

public interface IUpdateTokenStore
{
    Task<string?> LoadAsync(CancellationToken cancellation);
    Task SaveAsync(string token, CancellationToken cancellation);
    Task DeleteAsync(CancellationToken cancellation);
}

public sealed class UpdateTokenStore(string purpose = "github-updates") : IUpdateTokenStore
{
    private readonly SecretServiceCredentialStore store = new(purpose, "Aurelia GitHub updates");
    public Task<string?> LoadAsync(CancellationToken cancellation) => store.LoadValueAsync(cancellation);
    public Task SaveAsync(string token, CancellationToken cancellation) => store.SaveValueAsync(token, cancellation);
    public Task DeleteAsync(CancellationToken cancellation) => store.DeleteAsync(cancellation);
}

public interface IReleaseSource
{
    Task<JsonArray> ReleasesAsync(CancellationToken cancellation);
    Task<string> ChecksumsAsync(AppRelease release, CancellationToken cancellation);
    Task DownloadAsync(AppRelease release, Stream destination, CancellationToken cancellation);
}

/// <summary>Only the GitHub API receives the optional token. Redirects receive no credentials.</summary>
public sealed class GitHubReleaseSource(IUpdateTokenStore tokens, HttpMessageHandler? handler = null,
    ISettingsStore? settings = null, string? auditPath = null) : IReleaseSource, IDisposable
{
    private readonly HttpClient client = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromMinutes(30) };

    public async Task<JsonArray> ReleasesAsync(CancellationToken cancellation)
    {
        var repository = UpdateFeed.Repository(settings);
        var first = $"https://api.github.com/repos/{repository}/releases?per_page=100";
        Uri? next = new(first);
        var results = new JsonArray();
        for (var page = 1; page <= 10 && next is not null; page++)
        {
            using var response = await GetAsync(next, false, cancellation);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.NotFound)
                throw new IOException(repository == UpdateFeed.PublicTestRepository
                    ? "The public update test feed is unavailable. Turn off Public Update Test to use the normal release feed."
                    : "GitHub could not read the releases. For a private repository, save a GitHub token with read access to its contents.");
            response.EnsureSuccessStatusCode();
            await using var input = await response.Content.ReadAsStreamAsync(cancellation);
            using var output = new MemoryStream();
            await CopyBoundedAsync(input, output, 2 * 1024 * 1024, cancellation);
            var batch = JsonNode.Parse(output.ToArray()) as JsonArray ?? throw new IOException("GitHub returned an invalid release list.");
            foreach (var node in batch) results.Add(node?.DeepClone());
            next = null;
            if (response.Headers.TryGetValues("Link", out var links))
            {
                foreach (var link in string.Join(',', links).Split(','))
                {
                    if (!link.Contains("rel=\"next\"", StringComparison.Ordinal)) continue;
                    var trimmed = link.Trim();
                    var end = trimmed.IndexOf('>');
                    if (next is not null || !link.TrimStart().StartsWith('<') || end < 0
                        || !Uri.TryCreate(trimmed[1..end], UriKind.Absolute, out var address)
                        || address.Scheme != "https" || address.Host != "api.github.com" || !address.IsDefaultPort
                        || address.UserInfo.Length != 0 || address.Fragment.Length != 0
                        || (address.AbsolutePath != $"/repos/{repository}/releases" && !System.Text.RegularExpressions.Regex.IsMatch(address.AbsolutePath, @"\A/repositories/[0-9]+/releases\z")))
                        throw new IOException("GitHub returned an unexpected release page address.");
                    // GitHub may use its numeric repository route in Link. Never follow that
                    // supplied route: construct the next page within our already selected feed.
                    next = new Uri(first + "&page=" + (page + 1).ToString(System.Globalization.CultureInfo.InvariantCulture));
                }
            }
        }
        if (next is not null) throw new IOException("The release search could not be completed. Try again later.");
        return results;
    }

    public async Task<string> ChecksumsAsync(AppRelease release, CancellationToken cancellation)
    {
        if (release.SourceRepository != UpdateFeed.Repository(settings) || !AppRelease.IsAssetUrl(release.Checksums.AbsoluteUri, release.SourceRepository)) throw new IOException("The checksum address is invalid.");
        using var response = await GetAsync(release.Checksums, true, cancellation);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellation);
        using var output = new MemoryStream();
        await CopyBoundedAsync(stream, output, 1024 * 1024, cancellation);
        return System.Text.Encoding.UTF8.GetString(output.ToArray());
    }

    public async Task DownloadAsync(AppRelease release, Stream destination, CancellationToken cancellation)
    {
        if (release.SourceRepository != UpdateFeed.Repository(settings) || !AppRelease.IsAssetUrl(release.Download.AbsoluteUri, release.SourceRepository)) throw new IOException("The package address is invalid.");
        using var response = await GetAsync(release.Download, true, cancellation);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is { } length && length != release.Bytes)
            throw new IOException("The package size changed. Check for updates again.");
        await using var source = await response.Content.ReadAsStreamAsync(cancellation);
        var copied = await CopyBoundedAsync(source, destination, release.Bytes, cancellation);
        if (copied != release.Bytes) throw new IOException("The package download ended early. Try again.");
    }

    private async Task<HttpResponseMessage> GetAsync(Uri uri, bool asset, CancellationToken cancellation)
    {
        var publicTest = UpdateFeed.IsPublicTest(settings)
            || uri.AbsolutePath.StartsWith($"/repos/{UpdateFeed.PublicTestRepository}/", StringComparison.Ordinal);
        var token = publicTest ? null : await tokens.LoadAsync(cancellation);
        if (token is not null && token.Any(c => c <= 32 || c >= 127)) throw new IOException("The saved GitHub token is invalid. Save a new token in Updates.");
        for (var redirects = 0; redirects <= 5; redirects++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.UserAgent.ParseAdd("Aurelia-Linux-Updater/1.0");
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue(asset ? "application/octet-stream" : "application/vnd.github+json"));
            if (redirects == 0)
            {
                request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
                if (!string.IsNullOrWhiteSpace(token)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            }
            if (publicTest && auditPath is not null)
            {
                // The audit contains neither paths, signed query strings nor credential values.
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(auditPath)!);
                    if (File.Exists(auditPath) && new FileInfo(auditPath).Length > 64 * 1024) File.Delete(auditPath);
                    await File.AppendAllTextAsync(auditPath, System.Text.Json.JsonSerializer.Serialize(new
                    { host = uri.Host, authorizationPresent = request.Headers.Authorization is not null }) + "\n", cancellation);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
            var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if ((int)response.StatusCode is < 300 or >= 400) return response;
            var location = response.Headers.Location;
            response.Dispose();
            if (location is null) break;
            uri = new Uri(uri, location);
            if (uri.Scheme != "https" || !uri.IsDefaultPort || uri.UserInfo.Length > 0 || uri.Fragment.Length > 0
                || uri.Host is not ("release-assets.githubusercontent.com" or "objects.githubusercontent.com"))
                throw new IOException("GitHub redirected the download to an unexpected address.");
        }
        throw new IOException("GitHub redirected the download too many times.");
    }

    private static async Task<long> CopyBoundedAsync(Stream source, Stream destination, long limit, CancellationToken cancellation)
    {
        var buffer = new byte[128 * 1024];
        long count = 0;
        int read;
        while ((read = await source.ReadAsync(buffer, cancellation)) != 0)
        {
            count += read;
            if (count > limit) throw new IOException("The download is larger than expected.");
            await destination.WriteAsync(buffer.AsMemory(0, read), cancellation);
        }
        return count;
    }

    public void Dispose() => client.Dispose();
}

public interface IPackageInstaller
{
    LinuxPackageKind Kind { get; }
    Task InstallAsync(string path, CancellationToken cancellation);
}

/// <summary>The desktop asks for administrator authorization only after the person chose Install.</summary>
public sealed class LinuxPackageInstaller : IPackageInstaller
{
    public LinuxPackageKind Kind { get; } = Detect();

    public static LinuxPackageKind Detect(Func<string, bool>? exists = null)
    {
        exists ??= File.Exists;
        if (exists("/.flatpak-info")) return LinuxPackageKind.Flatpak;
        if (exists("/usr/bin/pacman")) return LinuxPackageKind.Arch;
        if (exists("/usr/bin/apt-get")) return LinuxPackageKind.Debian;
        if (exists("/usr/bin/dnf") || exists("/usr/bin/zypper")) return LinuxPackageKind.Rpm;
        throw new PlatformNotSupportedException("Use the Flatpak on this distribution; no supported package manager was found.");
    }

    public static (string Executable, string[] Arguments) Command(LinuxPackageKind kind, string path, bool zypper = false) => kind switch
    {
        LinuxPackageKind.Arch => ("/usr/bin/pkexec", ["/usr/bin/pacman", "-U", "--noconfirm", path]),
        LinuxPackageKind.Debian => ("/usr/bin/pkexec", ["/usr/bin/apt-get", "install", "-y", path]),
        LinuxPackageKind.Rpm when zypper => ("/usr/bin/pkexec", ["/usr/bin/zypper", "--non-interactive", "install", "--allow-unsigned-rpm", path]),
        LinuxPackageKind.Rpm => ("/usr/bin/pkexec", ["/usr/bin/dnf", "install", "-y", path]),
        _ => ("/usr/bin/flatpak-spawn", ["--host", "flatpak", "install", "--user", "--noninteractive", path]),
    };

    public async Task InstallAsync(string path, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        var command = Command(Kind, path, File.Exists("/usr/bin/zypper") && !File.Exists("/usr/bin/dnf"));
        var start = new ProcessStartInfo(command.Executable) { UseShellExecute = false };
        foreach (var arg in command.Arguments) start.ArgumentList.Add(arg);
        using var process = Process.Start(start) ?? throw new IOException("The package manager could not start.");
        // Once authorized, let the package manager finish its transaction even if the window closes.
        await process.WaitForExitAsync(CancellationToken.None);
        if (process.ExitCode != 0) throw new IOException("The update was not installed. Authorization may have been cancelled, or the package manager reported a problem.");
    }
}

/// <summary>Checks daily, validates the exact download, and never installs without the caller's confirmation.</summary>
public sealed class AppUpdater(IReleaseSource source, IPackageInstaller installer, ISettingsStore settings, string cacheDirectory,
    Version currentVersion, int currentBuild, TimeProvider? time = null) : INotifyPropertyChanged, IDisposable
{
    private readonly TimeProvider clock = time ?? TimeProvider.System;
    public event PropertyChangedEventHandler? PropertyChanged;
    public AppRelease? Available { get; private set; }
    public string Status { get; private set; } = "Check for a newer version of Aurelia for Linux.";
    public bool IsBusy { get; private set; }
    public bool RestartRequired { get; private set; }
    public bool PublicUpdateTestEnabled => UpdateFeed.IsPublicTest(settings);
    public const string BetaUpdatesKey = "betaUpdates";
    /// <summary>Off by default: only test computers see pre-releases.</summary>
    public bool BetaUpdatesEnabled => settings.Read<bool?>(BetaUpdatesKey) == true;

    public void SetBetaUpdates(bool enabled)
    {
        if (IsBusy || RestartRequired) return;
        settings.Write(BetaUpdatesKey, enabled);
        Available = null;
        Status = "Check for a newer version of Aurelia for Linux.";
        Notify();
    }
    private string CheckKey => "lastUpdateCheck." + UpdateFeed.Repository(settings);

    public void SetPublicUpdateTest(bool enabled)
    {
        if (IsBusy || RestartRequired) return;
        settings.Write(UpdateFeed.PublicTestKey, enabled);
        Available = null;
        Status = "Check for a newer version of Aurelia for Linux.";
        Notify();
    }

    public async Task CheckAsync(bool userInitiated, CancellationToken cancellation = default)
    {
        if (IsBusy || RestartRequired || (!userInitiated && ((settings.Read<bool?>("automaticUpdateChecks") ?? true) == false
            || settings.Read<DateTimeOffset?>(CheckKey) is { } last && clock.GetUtcNow() - last < TimeSpan.FromDays(1)))) return;
        IsBusy = true;
        Status = "Checking for updates…";
        Notify();
        try
        {
            settings.Write(CheckKey, clock.GetUtcNow());
            Available = null;
            Available = AppRelease.Newest(await source.ReleasesAsync(cancellation), installer.Kind, currentVersion, currentBuild, UpdateFeed.Repository(settings), BetaUpdatesEnabled);
            Status = Available is { } release
                ? $"Aurelia {release.Version} ({release.Build}){(release.IsBeta ? " Beta" : "")} is available."
                : "Aurelia is up to date.";
        }
        catch (Exception error) when (error is HttpRequestException or IOException or UnauthorizedAccessException or System.Text.Json.JsonException or InvalidOperationException or CredentialStoreUnavailableException)
        {
            Status = error is CredentialStoreUnavailableException ? "The desktop keyring could not be opened. Unlock it and try again." : error is IOException ? error.Message : "Updates could not be checked. Check the connection and try again.";
        }
        catch (OperationCanceledException)
        {
            Status = "The update check was cancelled.";
        }
        finally { IsBusy = false; Notify(); }
    }

    public async Task<bool> InstallAsync(Func<Task>? beforeInstall = null, CancellationToken cancellation = default)
    {
        if (IsBusy || RestartRequired || Available is not { } release) return false;
        IsBusy = true;
        Status = "Downloading and verifying the update…";
        Notify();
        // In Flatpak the host must be able to read the package. The app's XDG cache is visible to
        // the host at its real path; the package manager receives that path, never the sandbox /tmp.
        var directory = Path.Combine(cacheDirectory, "updates", Guid.NewGuid().ToString("N"));
        try
        {
            PrivateFiles.CreateDirectory(directory);
            var path = Path.Combine(directory, release.FileName);
            var expected = AppRelease.Checksum(release.FileName, await source.ChecksumsAsync(release, cancellation))
                ?? throw new IOException("The release has no unambiguous checksum for this package.");
            await using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
            {
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                await source.DownloadAsync(release, file, cancellation);
                if (file.Length != release.Bytes) throw new IOException("The package download is incomplete.");
                file.Position = 0;
                var actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(file, cancellation));
                if (actual != expected) throw new IOException("The downloaded package did not match its checksum. It was not installed.");
            }
            cancellation.ThrowIfCancellationRequested();
            if (beforeInstall is not null) await beforeInstall();
            cancellation.ThrowIfCancellationRequested();
            Status = "Waiting for the package manager…";
            Notify();
            await installer.InstallAsync(path, cancellation);
            Status = "The update is installed. Quit and reopen Aurelia to use it.";
            Available = null;
            RestartRequired = true;
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or HttpRequestException or CredentialStoreUnavailableException or Win32Exception or AureliaApiException or InvalidOperationException or TimeoutException)
        {
            Status = error is IOException ? error.Message : "The update could not be installed. Try again.";
            return false;
        }
        catch (OperationCanceledException)
        {
            Status = "The update was cancelled.";
            return false;
        }
        finally
        {
            try
            {
                if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
            }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
            {
                // The download remains private in the app cache. Cleanup must not hide the install
                // result or leave the updater permanently busy after a package-manager transaction.
            }
            IsBusy = false;
            Notify();
        }
    }

    private void Notify() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    public void Dispose() { if (source is IDisposable disposable) disposable.Dispose(); }
}
