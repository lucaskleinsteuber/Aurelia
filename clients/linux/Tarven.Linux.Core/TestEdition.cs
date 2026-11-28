using Tarven.Linux.Core.Connection;
using Tarven.Linux.Core.Settings;

namespace Tarven.Linux.Core;

/// <summary>
/// Reset App Data in Tarven Test: erases only the test edition's own folders and keyring entry, so its
/// next start begins at "Welcome to Tarven". The real app's files, its server and media are never touched.
/// </summary>
public static class TestEdition
{
    public const string FolderName = "tarven-desktop-test";

    /// <summary>True only for the test edition, and only when every folder is a test edition folder.</summary>
    public static bool MayErase(AppPaths paths, bool testEdition)
    {
        if (!testEdition) return false;
        string?[] folders = [paths.ConfigDirectory, paths.CacheDirectory, paths.StateDirectory, paths.DataDirectory];
        return folders.All(folder => folder is null || Path.GetFileName(Path.TrimEndingDirectorySeparator(folder)) == FolderName);
    }

    /// <summary>Erases the test edition's saved server, settings, caches and hosted server data.</summary>
    public static async Task EraseAsync(AppPaths paths, ICredentialStore credentials, bool testEdition, CancellationToken cancellation)
    {
        if (!MayErase(paths, testEdition))
            throw new InvalidOperationException("Only Tarven Test can erase its data, and only its own folders.");
        try
        {
            await credentials.DeleteAsync(cancellation).ConfigureAwait(false);
        }
        catch (CredentialStoreUnavailableException)
        {
            // Without a keyring there is no saved sign-in to erase.
        }
        foreach (var folder in new[] { paths.ConfigDirectory, paths.CacheDirectory, paths.StateDirectory, paths.DataDirectory })
        {
            if (folder is not null && Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
    }
}
