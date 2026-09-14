using System.Security.Cryptography;
using System.Text;

namespace Aurelia.Server.Services;

public sealed class BootstrapSetupAuthorizer
{
    public const string HeaderName = "X-Aurelia-Bootstrap-Token";

    private readonly byte[]? expectedToken;
    private int consumed;

    public BootstrapSetupAuthorizer(IConfiguration configuration)
    {
        var rawToken = Environment.GetEnvironmentVariable("AURELIA_BOOTSTRAP_TOKEN")
            ?? configuration["Aurelia:BootstrapToken"];
        Environment.SetEnvironmentVariable("AURELIA_BOOTSTRAP_TOKEN", null);
        expectedToken = string.IsNullOrWhiteSpace(rawToken)
            ? null
            : Encoding.UTF8.GetBytes(rawToken);
    }

    public bool IsEnabled => expectedToken is not null && Volatile.Read(ref consumed) == 0;

    public bool IsAuthorized(string? suppliedToken)
    {
        if (!IsEnabled || string.IsNullOrEmpty(suppliedToken))
        {
            return false;
        }

        var suppliedBytes = Encoding.UTF8.GetBytes(suppliedToken);
        return suppliedBytes.Length == expectedToken!.Length
            && CryptographicOperations.FixedTimeEquals(suppliedBytes, expectedToken);
    }

    public void Consume()
    {
        Interlocked.Exchange(ref consumed, 1);
        if (expectedToken is not null)
        {
            CryptographicOperations.ZeroMemory(expectedToken);
        }
    }
}
