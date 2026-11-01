using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Platform;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>
/// The real desktop keyring. It runs only when AURELIA_TEST_KEYRING=1 on a Linux desktop session,
/// with its own entry that the test removes again; it never touches Aurelia's own entry.
/// </summary>
public sealed class KeyringTests
{
    [Fact]
    public async Task SavesReplacesReadsAndDeletesAnEntry()
    {
        Assert.SkipUnless(OperatingSystem.IsLinux() && Environment.GetEnvironmentVariable("AURELIA_TEST_KEYRING") == "1",
            "Uses the real desktop keyring; set AURELIA_TEST_KEYRING=1 in a Linux desktop session.");
        var store = new SecretServiceCredentialStore("test-" + Guid.NewGuid().ToString("N"), "Aurelia test entry (safe to delete)");
        var cancellation = TestContext.Current.CancellationToken;
        var first = new StoredServer(Guid.NewGuid(), "Test Server", new Uri("https://192.0.2.10:43111"), new string('B', 64),
            "synthetic-device-token-not-a-real-credential-01", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(1));
        try
        {
            Assert.Null(await store.LoadAsync(cancellation));
            await store.SaveAsync(first, cancellation);
            Assert.Equal(first.ServerId, (await store.LoadAsync(cancellation))?.ServerId);

            var second = first with { Name = "Renamed Server" };
            await store.SaveAsync(second, cancellation);
            Assert.Equal("Renamed Server", (await store.LoadAsync(cancellation))?.Name);
        }
        finally
        {
            await store.DeleteAsync(cancellation);
        }
        Assert.Null(await store.LoadAsync(cancellation));
    }
}
