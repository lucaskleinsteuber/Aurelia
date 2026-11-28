using System.Security.Cryptography;
using System.Globalization;

namespace Tarven.Server.Services;

public sealed class TokenService
{
    public string CreateDeviceToken()
    {
        return Base64UrlEncode(RandomNumberGenerator.GetBytes(32));
    }

    public string CreatePlaybackToken()
    {
        return Base64UrlEncode(RandomNumberGenerator.GetBytes(32));
    }

    public string CreatePairingCode()
    {
        return RandomNumberGenerator.GetInt32(0, 100_000_000)
            .ToString("D8", CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Eight-digit codes are few enough to try them all against a plain hash, so a copy of the database
    /// would give away waiting codes. They are kept with a key that exists only in this server's memory:
    /// a code made before a restart is gone after it, which matters little for five minutes (audit S-X6).
    /// </summary>
    private readonly byte[] codeKey = RandomNumberGenerator.GetBytes(32);

    public string HashCode(string code) => Convert.ToHexString(HMACSHA256.HashData(codeKey, System.Text.Encoding.UTF8.GetBytes(code)));

    public string Hash(string value)
    {
        var bytes = SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes);
    }

    private static string Base64UrlEncode(byte[] value)
    {
        return Convert.ToBase64String(value)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }
}
