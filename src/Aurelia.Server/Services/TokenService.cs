using System.Security.Cryptography;
using System.Globalization;

namespace Aurelia.Server.Services;

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
