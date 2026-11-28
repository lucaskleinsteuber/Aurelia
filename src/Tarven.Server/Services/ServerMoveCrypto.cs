using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace Tarven.Server.Services;

/// <summary>
/// The move code and the two values derived from it (docs/SERVER_MOVE.md). The code itself never
/// travels: the new server proves it knows the code with an HMAC bound to the public key it saw in
/// TLS, and the old server encrypts the bundle under a key derived from the code and that key.
/// </summary>
public static class ServerMoveCrypto
{
    /// <summary>Crockford's base32: no I, L, O or U, so a code read aloud or typed is hard to get wrong.</summary>
    public const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    public const int CodeLength = 12;
    public const int NonceBytes = 32;
    private static readonly byte[] KeyInfo = "aurelia-move"u8.ToArray();

    public static string NewCode() => RandomNumberGenerator.GetString(Alphabet, CodeLength);

    /// <summary>"ABCD-EFGH-JKMN".</summary>
    public static string Display(string code) => $"{code[..4]}-{code[4..8]}-{code[8..]}";

    /// <summary>
    /// The code as typed, in any case, with or without dashes and spaces; O reads as 0 and I or L as
    /// 1, as Crockford's base32 decodes them. Null when it isn't a move code.
    /// </summary>
    public static string? Normalize(string? typed)
    {
        if (typed is null || typed.Length > 64) return null;
        var result = new StringBuilder(CodeLength);
        foreach (var character in typed)
        {
            if (character is '-' or ' ') continue;
            var upper = char.ToUpperInvariant(character) switch { 'O' => '0', 'I' or 'L' => '1', var other => other };
            if (!Alphabet.Contains(upper, StringComparison.Ordinal)) return null;
            result.Append(upper);
        }
        return result.Length == CodeLength ? result.ToString() : null;
    }

    /// <summary>HMAC-SHA256(key: ASCII code, message: nonce ‖ clientNonce ‖ SPKI SHA-256), all raw bytes.</summary>
    public static byte[] Proof(string normalizedCode, ReadOnlySpan<byte> nonce, ReadOnlySpan<byte> clientNonce, ReadOnlySpan<byte> spkiSha256)
    {
        var message = new byte[nonce.Length + clientNonce.Length + spkiSha256.Length];
        nonce.CopyTo(message);
        clientNonce.CopyTo(message.AsSpan(nonce.Length));
        spkiSha256.CopyTo(message.AsSpan(nonce.Length + clientNonce.Length));
        return HMACSHA256.HashData(Encoding.ASCII.GetBytes(normalizedCode), message);
    }

    /// <summary>HKDF-SHA256(ikm: ASCII code, salt: nonce ‖ clientNonce, info: "aurelia-move" ‖ SPKI SHA-256), 32 bytes.</summary>
    public static byte[] BundleKey(string normalizedCode, ReadOnlySpan<byte> nonce, ReadOnlySpan<byte> clientNonce, ReadOnlySpan<byte> spkiSha256)
    {
        var salt = new byte[nonce.Length + clientNonce.Length];
        nonce.CopyTo(salt);
        clientNonce.CopyTo(salt.AsSpan(nonce.Length));
        var info = new byte[KeyInfo.Length + spkiSha256.Length];
        KeyInfo.CopyTo(info, 0);
        spkiSha256.CopyTo(info.AsSpan(KeyInfo.Length));
        return HKDF.DeriveKey(HashAlgorithmName.SHA256, Encoding.ASCII.GetBytes(normalizedCode), 32, salt, info);
    }

    /// <summary>SHA-256 of a certificate's SubjectPublicKeyInfo: the key Tarven's apps pin.</summary>
    public static byte[] SpkiSha256(X509Certificate2 certificate) =>
        SHA256.HashData(certificate.PublicKey.ExportSubjectPublicKeyInfo());

    public static byte[] SpkiSha256(X509Certificate certificate)
    {
        if (certificate is X509Certificate2 typed) return SpkiSha256(typed);
        using var loaded = X509CertificateLoader.LoadCertificate(certificate.GetRawCertData());
        return SpkiSha256(loaded);
    }

    /// <summary>Base64 of exactly <see cref="NonceBytes"/> bytes, or null.</summary>
    public static byte[]? DecodeNonce(string? value)
    {
        if (value is null || value.Length > 64) return null;
        var buffer = new byte[48];
        return Convert.TryFromBase64String(value, buffer, out var written) && written == NonceBytes ? buffer[..written] : null;
    }
}
