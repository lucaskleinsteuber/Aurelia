using Microsoft.Extensions.Hosting;

namespace Aurelia.Server.Services;

public static class HostReadinessSignal
{
    public const string EnvironmentVariableName = "AURELIA_HOST_READY_NONCE";
    public const string MarkerPrefix = "AURELIA_SERVER_READY:";
    public const string StoppingMarkerPrefix = "AURELIA_SERVER_STOPPING:";

    public static bool Register(
        IHostApplicationLifetime lifetime,
        TextWriter writer,
        string? nonce)
    {
        ArgumentNullException.ThrowIfNull(lifetime);
        ArgumentNullException.ThrowIfNull(writer);

        if (!IsValidNonce(nonce))
        {
            return false;
        }

        var acceptedNonce = nonce!;
        lifetime.ApplicationStarted.Register(() =>
        {
            WriteMarker(writer, MarkerPrefix, acceptedNonce);
        });
        lifetime.ApplicationStopping.Register(() =>
            WriteMarker(writer, StoppingMarkerPrefix, acceptedNonce));
        return true;
    }

    private static void WriteMarker(TextWriter writer, string prefix, string nonce)
    {
        try
        {
            writer.WriteLine($"{prefix}{nonce}");
            writer.Flush();
        }
        catch (IOException)
        {
            // A detached host can close its pipe during shutdown. Readiness is advisory.
        }
        catch (ObjectDisposedException)
        {
            // A detached host can close its pipe during shutdown. Readiness is advisory.
        }
    }

    private static bool IsValidNonce(string? nonce)
    {
        return nonce is { Length: >= 32 and <= 128 }
               && nonce.All(character => char.IsAsciiLetterOrDigit(character)
                                         || character is '-' or '_');
    }
}
