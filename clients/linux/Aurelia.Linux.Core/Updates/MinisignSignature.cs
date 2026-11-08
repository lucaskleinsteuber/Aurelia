using System.Text;
using Org.BouncyCastle.Crypto.Digests;
using Org.BouncyCastle.Math.EC.Rfc8032;

namespace Aurelia.Linux.Core.Updates;

/// <summary>
/// Checks a minisign signature (https://jedisct1.github.io/minisign/) with the owner's public key
/// built into the app. Releases sign their SHA256SUMS; GitHub alone, or a stolen GitHub token,
/// cannot produce that signature, so a replaced package is never installed.
/// </summary>
public static class MinisignSignature
{
    private const int KeyIdLength = 8;
    private const int PublicKeyLength = 32;
    private const int SignatureLength = 64;

    /// <summary>True when <paramref name="signatureFile"/> is a valid signature of <paramref name="message"/> by <paramref name="publicKey"/>.</summary>
    /// <param name="publicKey">The second line of a minisign public key file (base64), or the whole file.</param>
    public static bool Verify(ReadOnlySpan<byte> message, string signatureFile, string publicKey)
    {
        if (!TryReadPublicKey(publicKey, out var keyId, out var key)) return false;
        var lines = signatureFile.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        if (lines.Length < 4 || !lines[0].StartsWith("untrusted comment:", StringComparison.Ordinal)
            || !lines[2].StartsWith("trusted comment: ", StringComparison.Ordinal)) return false;
        if (!TryBase64(lines[1], out var signatureBlock) || signatureBlock.Length != 2 + KeyIdLength + SignatureLength) return false;
        if (!TryBase64(lines[3], out var globalSignature) || globalSignature.Length != SignatureLength) return false;

        var algorithm = Encoding.ASCII.GetString(signatureBlock, 0, 2);
        if (!signatureBlock.AsSpan(2, KeyIdLength).SequenceEqual(keyId)) return false;
        var signature = signatureBlock.AsSpan(2 + KeyIdLength, SignatureLength).ToArray();

        byte[] signed;
        if (algorithm == "ED")
        {
            // The default since minisign 0.10: the file's BLAKE2b-512 hash is signed.
            var digest = new Blake2bDigest(512);
            digest.BlockUpdate(message);
            signed = new byte[64];
            digest.DoFinal(signed, 0);
        }
        else if (algorithm == "Ed")
        {
            signed = message.ToArray();
        }
        else
        {
            return false;
        }
        if (!Ed25519.Verify(signature, 0, key, 0, signed, 0, signed.Length)) return false;

        // The trusted comment is signed too, so its text cannot be swapped.
        var comment = Encoding.UTF8.GetBytes(lines[2]["trusted comment: ".Length..]);
        var global = new byte[SignatureLength + comment.Length];
        signature.CopyTo(global, 0);
        comment.CopyTo(global, SignatureLength);
        return Ed25519.Verify(globalSignature, 0, key, 0, global, 0, global.Length);
    }

    /// <summary>A minisign public key: "Ed", an eight-byte key id and the 32-byte Ed25519 key.</summary>
    public static bool TryReadPublicKey(string text, out byte[] keyId, out byte[] key)
    {
        keyId = [];
        key = [];
        var line = text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n')
            .Select(each => each.Trim()).LastOrDefault(each => each.Length > 0 && !each.StartsWith("untrusted comment:", StringComparison.Ordinal));
        if (line is null || !TryBase64(line, out var bytes) || bytes.Length != 2 + KeyIdLength + PublicKeyLength
            || bytes[0] != (byte)'E' || bytes[1] != (byte)'d') return false;
        keyId = bytes[2..(2 + KeyIdLength)];
        key = bytes[(2 + KeyIdLength)..];
        return true;
    }

    private static bool TryBase64(string text, out byte[] bytes)
    {
        try
        {
            bytes = Convert.FromBase64String(text.Trim());
            return true;
        }
        catch (FormatException)
        {
            bytes = [];
            return false;
        }
    }
}
