using System.Net.Sockets;
using Microsoft.AspNetCore.Connections;
using Microsoft.Extensions.Hosting;

namespace Aurelia.Server.Services;

public static class HostReadinessSignal
{
    public const string EnvironmentVariableName = "AURELIA_HOST_READY_NONCE";
    public const string MarkerPrefix = "AURELIA_SERVER_READY:";
    public const string StoppingMarkerPrefix = "AURELIA_SERVER_STOPPING:";
    public const string MigratingMarkerPrefix = "AURELIA_SERVER_MIGRATING:";
    public const string PortInUseMarkerPrefix = "AURELIA_SERVER_PORT_IN_USE:";
    public const int PortInUseExitCode = 77;

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

    public static void SignalMigrating(TextWriter writer, string? nonce)
    {
        ArgumentNullException.ThrowIfNull(writer);
        if (!IsValidNonce(nonce)) return;
        WriteMarker(writer, MigratingMarkerPrefix, nonce!);
    }

    public static void SignalPortInUse(TextWriter writer, string? nonce, int? port = null)
    {
        ArgumentNullException.ThrowIfNull(writer);
        if (!IsValidNonce(nonce)) return;
        var suffix = port is > 0 and <= 65535 ? $"{nonce}:{port}" : nonce!;
        WriteMarker(writer, PortInUseMarkerPrefix, suffix);
    }

    public static bool IsAddressInUse(Exception exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            if (current is AddressInUseException) return true;
            if (current is SocketException { SocketErrorCode: SocketError.AddressAlreadyInUse }) return true;
            if (current is AggregateException aggregate
                && aggregate.InnerExceptions.Any(IsAddressInUse))
            {
                return true;
            }
        }
        return false;
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
