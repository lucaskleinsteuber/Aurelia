using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Aurelia.Home.Server.Services;

public sealed class ServerTlsIdentity : IDisposable
{
    private ServerTlsIdentity(
        bool isEnabled,
        X509Certificate2? certificate,
        string? publicKeyFingerprint,
        string? displayFingerprint)
    {
        IsEnabled = isEnabled;
        Certificate = certificate;
        PublicKeyFingerprint = publicKeyFingerprint;
        DisplayFingerprint = displayFingerprint;
    }

    public bool IsEnabled { get; }

    public X509Certificate2? Certificate { get; }

    public string? PublicKeyFingerprint { get; }

    public string? DisplayFingerprint { get; }

    public static ServerTlsIdentity Disabled { get; } = new(false, null, null, null);

    public static ServerTlsIdentity LoadOrCreate(ServerRuntimeOptions runtime)
    {
        if (!runtime.LanAccessEnabled)
        {
            return Disabled;
        }

        if (File.Exists(runtime.CertificatePath) != File.Exists(runtime.PrivateKeyPath))
        {
            throw new InvalidOperationException(
                "The server TLS identity is incomplete. Restore both identity files or remove both and pair clients again.");
        }

        if (!File.Exists(runtime.CertificatePath))
        {
            Create(runtime);
        }

        PrivateFilePermissions.ProtectFile(runtime.CertificatePath);
        PrivateFilePermissions.ProtectFile(runtime.PrivateKeyPath);

        var certificate = X509Certificate2.CreateFromPemFile(
            runtime.CertificatePath,
            runtime.PrivateKeyPath);
        using var publicKey = certificate.GetECDsaPublicKey()
            ?? throw new InvalidOperationException("The server certificate does not contain an ECDSA public key.");
        var fingerprint = Convert.ToHexString(
            SHA256.HashData(publicKey.ExportSubjectPublicKeyInfo()));
        return new ServerTlsIdentity(
            true,
            certificate,
            fingerprint,
            FormatDisplayFingerprint(fingerprint));
    }

    public void Dispose()
    {
        if (!ReferenceEquals(this, Disabled))
        {
            Certificate?.Dispose();
        }
    }

    private static void Create(ServerRuntimeOptions runtime)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest(
            "CN=Aurelia Home Server",
            key,
            HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(
            certificateAuthority: false,
            hasPathLengthConstraint: false,
            pathLengthConstraint: 0,
            critical: true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature,
            critical: true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
            new OidCollection
            {
                new("1.3.6.1.5.5.7.3.1"),
            },
            critical: false));

        var names = new SubjectAlternativeNameBuilder();
        names.AddDnsName("localhost");
        names.AddIpAddress(IPAddress.Loopback);
        names.AddIpAddress(IPAddress.IPv6Loopback);
        if (!string.IsNullOrWhiteSpace(Environment.MachineName))
        {
            names.AddDnsName(Environment.MachineName);
        }

        foreach (var address in LocalAddresses())
        {
            names.AddIpAddress(address);
        }

        request.CertificateExtensions.Add(names.Build());
        using var certificate = request.CreateSelfSigned(
            DateTimeOffset.UtcNow.AddDays(-1),
            DateTimeOffset.UtcNow.AddYears(10));

        WritePrivateFile(runtime.CertificatePath, certificate.ExportCertificatePem());
        WritePrivateFile(runtime.PrivateKeyPath, key.ExportPkcs8PrivateKeyPem());
    }

    private static IEnumerable<IPAddress> LocalAddresses()
    {
        return NetworkInterface.GetAllNetworkInterfaces()
            .Where(network => network.OperationalStatus == OperationalStatus.Up)
            .SelectMany(network => network.GetIPProperties().UnicastAddresses)
            .Select(address => address.Address)
            .Where(address => address.AddressFamily is AddressFamily.InterNetwork
                or AddressFamily.InterNetworkV6)
            .Where(address => !IPAddress.IsLoopback(address))
            .Distinct();
    }

    private static void WritePrivateFile(string path, string contents)
    {
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temporaryPath, contents);
            PrivateFilePermissions.ProtectFile(temporaryPath);
            File.Move(temporaryPath, path);
            PrivateFilePermissions.ProtectFile(path);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static string FormatDisplayFingerprint(string fingerprint)
    {
        return string.Join(
            '-',
            Enumerable.Range(0, 6).Select(index => fingerprint.Substring(index * 4, 4)));
    }
}
