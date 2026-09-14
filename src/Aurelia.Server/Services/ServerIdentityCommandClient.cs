using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public static class ServerIdentityCommandClient
{
    public static async Task<int> RunAsync(
        ServerCommandLine commandLine,
        CancellationToken cancellationToken)
    {
        if (commandLine.Action is "help" or "--help" || commandLine.HasFlag("--help"))
        {
            PrintUsage();
            return 0;
        }

        if (commandLine.Action != "identity")
        {
            PrintUsage();
            return 2;
        }

        try
        {
            var address = PairingCommandClient.LocalServerAddress(commandLine);
            using var client = new HttpClient { BaseAddress = address };
            using var response = await client.GetAsync("/api/v1/server/info", cancellationToken);
            var info = await PairingCommandClient.ReadSuccessAsync<ServerInfoResponse>(
                response,
                cancellationToken);
            Console.WriteLine($"Server: {info.Name}");
            Console.WriteLine($"Server ID: {info.ServerId:D}");
            Console.WriteLine($"Version: {info.Version}");
            Console.WriteLine($"LAN access: {(info.LanAccessEnabled ? "enabled" : "disabled")}");
            if (info.DisplayFingerprint is not null)
            {
                Console.WriteLine($"Verification fingerprint: {info.DisplayFingerprint}");
                Console.WriteLine($"LAN HTTPS port: {info.LanHttpsPort}");
            }

            return 0;
        }
        catch (Exception exception) when (exception is HttpRequestException
            or TaskCanceledException
            or InvalidOperationException
            or System.Text.Json.JsonException)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    private static void PrintUsage()
    {
        Console.WriteLine("Aurelia server commands:");
        Console.WriteLine("  server identity");
        Console.WriteLine("  Add --server URL to override http://127.0.0.1:43110.");
    }
}
