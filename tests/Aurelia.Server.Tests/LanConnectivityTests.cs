using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Aurelia.Server.Services;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class LanConnectivityTests
{
    [Fact]
    public void LanModeAddsHttpsWithoutChangingLocalEndpoint()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        var runtime = ServerRuntimeOptions.Resolve(
            new ConfigurationBuilder().Build(),
            [
                "run",
                "--lan",
                "--lan-port",
                "44443",
                "--data-dir",
                dataDirectory,
                "--urls",
                "http://127.0.0.1:43210",
            ]);

        Assert.True(runtime.LanAccessEnabled);
        Assert.Equal(44443, runtime.LanHttpsPort);
        Assert.Equal(
            "http://127.0.0.1:43210;https://*:44443",
            runtime.ListenUrl);
    }

    [Fact]
    public void LanPortMustBeValid()
    {
        Assert.Throws<ArgumentException>(() => ServerRuntimeOptions.Resolve(
            new ConfigurationBuilder().Build(),
            ["run", "--lan", "--lan-port", "70000"]));
    }

    [Fact]
    public void TlsIdentityIsStableAndPrivate()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var runtime = ServerRuntimeOptions.Resolve(
            new ConfigurationBuilder().Build(),
            ["run", "--lan", "--data-dir", dataDirectory]);

        try
        {
            string fingerprint;
            using (var first = ServerTlsIdentity.LoadOrCreate(runtime))
            {
                Assert.NotNull(first.Certificate);
                Assert.Matches("^[0-9A-F]{64}$", first.PublicKeyFingerprint);
                Assert.Matches(
                    "^[0-9A-F]{4}(-[0-9A-F]{4}){5}$",
                    first.DisplayFingerprint);
                fingerprint = first.PublicKeyFingerprint!;
            }

            using (var second = ServerTlsIdentity.LoadOrCreate(runtime))
            {
                Assert.Equal(fingerprint, second.PublicKeyFingerprint);
                Assert.True(second.Certificate!.HasPrivateKey);
                Assert.True(second.Certificate.NotAfter > DateTime.UtcNow.AddYears(9));
            }

            using var certificate = X509Certificate2.CreateFromPemFile(
                runtime.CertificatePath,
                runtime.PrivateKeyPath);
            using var publicKey = certificate.GetECDsaPublicKey();
            Assert.NotNull(publicKey);
            Assert.Equal(
                fingerprint,
                Convert.ToHexString(SHA256.HashData(publicKey.ExportSubjectPublicKeyInfo())));

            if (!OperatingSystem.IsWindows())
            {
                var privateMode = File.GetUnixFileMode(runtime.PrivateKeyPath);
                Assert.Equal(
                    UnixFileMode.UserRead | UnixFileMode.UserWrite,
                    privateMode);
            }
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public void IncompleteTlsIdentityIsRejected()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var runtime = ServerRuntimeOptions.Resolve(
            new ConfigurationBuilder().Build(),
            ["run", "--lan", "--data-dir", dataDirectory]);

        try
        {
            File.WriteAllText(runtime.CertificatePath, "not a certificate");
            Assert.Throws<InvalidOperationException>(() =>
                ServerTlsIdentity.LoadOrCreate(runtime));
        }
        finally
        {
            Directory.Delete(dataDirectory, recursive: true);
        }
    }

    [Fact]
    public void BonjourProfileContainsOnlyDiscoveryMetadata()
    {
        var runtime = ServerRuntimeOptions.Resolve(
            new ConfigurationBuilder().Build(),
            ["run", "--lan", "--data-dir", TestPaths.CreateDataDirectory()]);
        var serverId = Guid.NewGuid();
        var profile = BonjourAdvertisementService.CreateProfile(runtime, serverId);

        Assert.Equal("_aurelia._tcp", profile.ServiceType);
        Assert.Equal((ushort)ServerRuntimeOptions.DefaultLanHttpsPort, profile.Port);
        Assert.Equal(serverId.ToString("D"), profile.Properties["id"]);
        Assert.Equal("1", profile.Properties["api"]);
        Assert.Equal("1", profile.Properties["tls"]);
        Assert.Equal("43111", profile.Properties["port"]);
        Assert.Equal("Aurelia", profile.Properties["name"]);
        Assert.EndsWith(serverId.ToString("N")[..8], profile.InstanceName);
        Assert.Equal(5, profile.Properties.Count);
    }

    [Theory]
    [InlineData("127.0.0.1", true)]
    [InlineData("::1", true)]
    [InlineData("192.168.1.20", false)]
    [InlineData(null, false)]
    public void PasswordLoginPolicyAcceptsOnlyLoopback(string? address, bool expected)
    {
        Assert.Equal(
            expected,
            LocalRequestPolicy.IsAllowed(
                address is null ? null : IPAddress.Parse(address),
                isTesting: false));
    }

    [Fact]
    public void PairingAndServerSubcommandsAreParsed()
    {
        var pairing = ServerCommandLine.Parse(
            ["pairing", "create", "--username", "lucas"]);
        var identity = ServerCommandLine.Parse(["server", "identity"]);

        Assert.Equal("pairing", pairing.Command);
        Assert.Equal("create", pairing.Action);
        Assert.Equal("lucas", pairing.Username);
        Assert.Equal("server", identity.Command);
        Assert.Equal("identity", identity.Action);
    }
}
