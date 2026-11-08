using System.Text;
using Org.BouncyCastle.Crypto.Digests;
using Org.BouncyCastle.Math.EC.Rfc8032;

namespace Aurelia.Linux.Tests;

/// <summary>A minisign key made up for tests only; it signs nothing outside them.</summary>
internal static class TestSigning
{
    private static readonly byte[] Secret = Enumerable.Range(1, 32).Select(value => (byte)value).ToArray();
    private static readonly byte[] KeyId = [0x41, 0x75, 0x72, 0x65, 0x6c, 0x69, 0x61, 0x21];

    public static string PublicKey { get; } = MakePublicKey();

    private static string MakePublicKey()
    {
        var key = new byte[32];
        Ed25519.GeneratePublicKey(Secret, 0, key, 0);
        return Convert.ToBase64String([(byte)'E', (byte)'d', .. KeyId, .. key]);
    }

    /// <summary>A signature file as "minisign -S" writes it (BLAKE2b-512 prehash, algorithm "ED").</summary>
    public static string Sign(string text, string comment = "timestamp:1762550000\tfile:SHA256SUMS\thashed")
    {
        var digest = new Blake2bDigest(512);
        var message = Encoding.UTF8.GetBytes(text);
        digest.BlockUpdate(message, 0, message.Length);
        var hash = new byte[64];
        digest.DoFinal(hash, 0);
        var signature = new byte[64];
        Ed25519.Sign(Secret, 0, hash, 0, hash.Length, signature, 0);
        var trusted = Encoding.UTF8.GetBytes(comment);
        byte[] global = [.. signature, .. trusted];
        var globalSignature = new byte[64];
        Ed25519.Sign(Secret, 0, global, 0, global.Length, globalSignature, 0);
        return "untrusted comment: signature from a test key\n"
            + Convert.ToBase64String([(byte)'E', (byte)'D', .. KeyId, .. signature]) + "\n"
            + "trusted comment: " + comment + "\n"
            + Convert.ToBase64String(globalSignature) + "\n";
    }
}
