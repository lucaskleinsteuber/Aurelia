using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Aurelia.Desktop.Core;
using Xunit;

namespace Aurelia.Desktop.Tests;

public sealed class CoreTests
{
    [Theory]
    [InlineData("192.168.1.20", "https://192.168.1.20:43111/")]
    [InlineData("  192.168.1.20:8443 ", "https://192.168.1.20:8443/")]
    [InlineData("https://living-room.local", "https://living-room.local:43111/")]
    [InlineData("HTTPS://Server.Local:443/", "https://server.local/")]
    [InlineData("[fe80::1]", "https://[fe80::1]:43111/")]
    public void TypedAddressesBecomeAureliaHttpsAddresses(string typed, string expected)
    {
        Assert.True(ServerAddress.TryNormalize(typed, out var address));
        Assert.Equal(expected, address.ToString());
    }

    [Theory]
    [InlineData("")]
    [InlineData("http://192.168.1.20")]
    [InlineData("https://user:secret@192.168.1.20")]
    [InlineData("192.168.1.20/library")]
    [InlineData("192.168.1.20?debug=1")]
    public void UnsafeOrIncompleteAddressesAreRejected(string typed) =>
        Assert.False(ServerAddress.TryNormalize(typed, out _));

    [Fact]
    public void TheFingerprintIsTheHashOfTheP256PublicKey()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=Synthetic Aurelia", key, HashAlgorithmName.SHA256);
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        var expected = Convert.ToHexString(SHA256.HashData(key.ExportSubjectPublicKeyInfo()));

        Assert.Equal(expected, ServerIdentity.Fingerprint(certificate));
        Assert.True(ServerIdentity.Matches(expected.ToLowerInvariant(), expected));
        Assert.False(ServerIdentity.Matches(expected, new string('0', 64)));
        Assert.Equal(expected[..4] + "-" + expected[4..8] + "-" + expected[8..12] + "-" + expected[12..16] + "-" + expected[16..20]
            + "-" + expected[20..24], ServerIdentity.Display(expected));

        // Only the P-256 keys Aurelia servers use are accepted.
        using var rsa = RSA.Create(2048);
        using var other = new CertificateRequest("CN=Other", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
            .CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        Assert.Null(ServerIdentity.Fingerprint(other));
    }

    [Fact]
    public void TheSavedConnectionStaysPrivateAndSurvivesARestart()
    {
        var directory = Path.Combine(Path.GetTempPath(), "aurelia-desktop-store-" + Guid.NewGuid().ToString("N"));
        try
        {
            var path = Path.Combine(directory, "connection.json");
            var store = new ConnectionStore(new PrivateFileSecretStore(path));
            Assert.Null(store.Load());
            var saved = FakeServerApi.Saved(new PendingPairing(Guid.NewGuid(), new string('s', 43)));
            store.Save(saved);
            Assert.Equal(saved, new ConnectionStore(new PrivateFileSecretStore(path)).Load());
            if (!OperatingSystem.IsWindows())
            {
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(path));
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, File.GetUnixFileMode(directory));
            }
            Assert.Single(Directory.GetFiles(directory));

            File.WriteAllText(path, "{ damaged");
            Assert.Null(store.Load());
            store.Clear();
            Assert.False(File.Exists(path));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void TheDataFolderIsNeverTheMacAppsOrAureliaClassics()
    {
        var folder = DesktopPaths.DataDirectory;
        if (OperatingSystem.IsMacOS())
            Assert.EndsWith(Path.Combine("Application Support", "Aurelia Desktop"), folder, StringComparison.Ordinal);
        Assert.False(folder.EndsWith(Path.Combine("Application Support", "Aurelia"), StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("Alex", "A")]
    [InlineData(" émile", "É")]
    [InlineData("", "?")]
    public void ProfilesShowTheirFirstLetter(string name, string expected) => Assert.Equal(expected, Initials.Of(name));

    [Theory]
    [InlineData("1234", true)]
    [InlineData("12345678", true)]
    [InlineData("123", false)]
    [InlineData("123456789", false)]
    [InlineData("12a4", false)]
    public void PinsAreFourToEightDigits(string pin, bool valid) => Assert.Equal(valid, ProfilePin.IsValid(pin));
}
