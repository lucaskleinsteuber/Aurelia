using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Aurelia.Linux.Core.Api;

/// <summary>
/// A server proves who it is with its TLS key: the SHA-256 of the certificate's P-256 public key
/// (its SubjectPublicKeyInfo), exactly as the Mac and Apple TV apps pin it.
/// </summary>
public static class ServerIdentity
{
    public static string? Fingerprint(X509Certificate2 certificate)
    {
        using var key = certificate.GetECDsaPublicKey();
        if (key is null || key.KeySize != 256) return null;
        return Convert.ToHexString(SHA256.HashData(key.ExportSubjectPublicKeyInfo()));
    }

    public static bool IsValidFingerprint(string? value) => value is { Length: 64 } && value.All(Uri.IsHexDigit);

    public static bool Matches(string? left, string? right) =>
        IsValidFingerprint(left) && IsValidFingerprint(right) && string.Equals(left, right, StringComparison.OrdinalIgnoreCase);

    /// <summary>"A1B2-C3D4-…": the first 24 characters in groups of four, as the Mac shows them.</summary>
    public static string Display(string fingerprint)
    {
        var value = fingerprint.ToUpperInvariant();
        var groups = new List<string>();
        for (var offset = 0; offset < Math.Min(value.Length, 24); offset += 4)
        {
            groups.Add(value.Substring(offset, Math.Min(4, value.Length - offset)));
        }
        return string.Join('-', groups);
    }
}
