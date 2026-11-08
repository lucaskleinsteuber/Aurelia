using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>Aurelia Test's Reset App Data erases only the test edition's own folders and sign-in.</summary>
public sealed class TestEditionTests
{
    [Fact]
    public async Task ResetErasesOnlyTheTestEditionsFolders()
    {
        var root = Path.Combine(Path.GetTempPath(), "aurelia-test-edition-" + Guid.NewGuid().ToString("N"));
        try
        {
            AppPaths Paths(string folder) => new(Path.Combine(root, "config", folder), Path.Combine(root, "cache", folder),
                Path.Combine(root, "state", folder), Path.Combine(root, "data", folder));
            var real = Paths("aurelia-desktop");
            var test = Paths(TestEdition.FolderName);
            foreach (var paths in new[] { real, test })
            {
                Directory.CreateDirectory(paths.ConfigDirectory);
                File.WriteAllText(paths.SettingsFile, "{}");
                Directory.CreateDirectory(Path.Combine(paths.DataDirectory!, "server"));
            }
            Assert.False(TestEdition.MayErase(real, testEdition: true));
            Assert.False(TestEdition.MayErase(test, testEdition: false));
            Assert.True(TestEdition.MayErase(test, testEdition: true));
            await Assert.ThrowsAsync<InvalidOperationException>(() =>
                TestEdition.EraseAsync(real, new MemoryCredentialStore(), testEdition: true, CancellationToken.None));

            var credentials = new MemoryCredentialStore { Server = HostingScreenTests.Saved() };
            await TestEdition.EraseAsync(test, credentials, testEdition: true, CancellationToken.None);
            Assert.Null(credentials.Server);
            Assert.False(Directory.Exists(test.ConfigDirectory));
            Assert.False(Directory.Exists(test.DataDirectory));
            Assert.True(File.Exists(real.SettingsFile));
            Assert.True(Directory.Exists(Path.Combine(real.DataDirectory!, "server")));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }
}
