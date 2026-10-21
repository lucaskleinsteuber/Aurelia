using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public static class PairingCommandClient
{
    private static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();

    public static async Task<int> RunAsync(
        ServerCommandLine commandLine,
        CancellationToken cancellationToken)
    {
        if (commandLine.Action is null
            || commandLine.Action is "help" or "--help"
            || commandLine.HasFlag("--help"))
        {
            PrintUsage();
            return commandLine.HasFlag("--help")
                || commandLine.Action is "help" or "--help" ? 0 : 2;
        }

        if (commandLine.Action is not ("create" or "approve"))
        {
            Console.Error.WriteLine($"Unknown pairing action '{commandLine.Action}'.");
            return 2;
        }

        try
        {
            var baseAddress = LocalServerAddress(commandLine);
            using var client = CommandClientSecurity.CreateClient(baseAddress);
            var username = commandLine.Username;
            if (string.IsNullOrWhiteSpace(username))
            {
                Console.Error.Write("Username: ");
                username = Console.ReadLine();
            }

            var password = commandLine.ReadPassword();
            using var loginResponse = await client.PostAsJsonAsync(
                "/api/v1/auth/login",
                new LoginRequest(
                    username ?? string.Empty,
                    password,
                    $"Aurelia CLI on {Environment.MachineName}"),
                JsonOptions,
                cancellationToken);
            var authentication = await ReadSuccessAsync<AuthenticationResponse>(
                loginResponse,
                cancellationToken);
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
                "Bearer",
                authentication.Token);

            try
            {
                await CommandClientSecurity.UnlockViewingAndManagementAsync(client, authentication, commandLine, password, cancellationToken);
                if (commandLine.Action == "approve")
                {
                    return await ApproveDeviceAsync(client, commandLine, password, cancellationToken);
                }

                using var codeResponse = await CommandClientSecurity.SendConfirmedAsync(client, HttpMethod.Post, "/api/v1/auth/pairings", new CreatePairingCodeRequest(), password, cancellationToken);
                var pairing = await ReadSuccessAsync<PairingCodeResponse>(
                    codeResponse,
                    cancellationToken);
                using var infoResponse = await client.GetAsync(
                    "/api/v1/server/info",
                    cancellationToken);
                var info = await ReadSuccessAsync<ServerInfoResponse>(
                    infoResponse,
                    cancellationToken);

                Console.WriteLine($"Pairing code: {pairing.Code}");
                Console.WriteLine($"Expires: {pairing.ExpiresAt:O}");
                if (info.LanAccessEnabled && info.DisplayFingerprint is not null)
                {
                    Console.WriteLine($"Server: {info.Name}");
                    Console.WriteLine($"Verification fingerprint: {info.DisplayFingerprint}");
                    Console.WriteLine($"LAN HTTPS port: {info.LanHttpsPort}");
                }
                else
                {
                    Console.WriteLine(
                        "LAN access is not active. Restart the server with run --lan before pairing a Mac.");
                }

                return 0;
            }
            finally
            {
                await CommandClientSecurity.EndCommandSessionAsync(client, authentication);
            }
        }
        catch (Exception exception) when (exception is HttpRequestException
            or TaskCanceledException
            or InvalidOperationException
            or JsonException
            or IOException)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    /// <summary>
    /// Approves a device that shows an 8-digit code, as Server Settings does on a computer with a
    /// screen. A server without one is set up this way over SSH.
    /// </summary>
    private static async Task<int> ApproveDeviceAsync(
        HttpClient client,
        ServerCommandLine commandLine,
        string password,
        CancellationToken cancellationToken)
    {
        var code = commandLine.Option("--code");
        if (string.IsNullOrWhiteSpace(code))
        {
            Console.Error.Write("Code shown on the device: ");
            code = Console.ReadLine();
        }

        using var lookupResponse = await client.PostAsJsonAsync(
            "/api/v1/server/device-pairings/lookup",
            new DeviceAuthorizationLookupRequest(code?.Replace(" ", "", StringComparison.Ordinal).Replace("-", "", StringComparison.Ordinal) ?? string.Empty),
            JsonOptions,
            cancellationToken);
        var device = await ReadSuccessAsync<DeviceAuthorizationPreview>(lookupResponse, cancellationToken);
        Console.WriteLine($"Device: {device.DeviceName}");
        Console.WriteLine($"Server: {device.ServerName}");
        if (!commandLine.HasFlag("--yes"))
        {
            Console.Error.Write("Allow this device to connect? [y/N] ");
            if (Console.ReadLine()?.Trim().ToLowerInvariant() is not ("y" or "yes"))
            {
                Console.WriteLine("The device was not approved.");
                return 1;
            }
        }

        using var approval = await CommandClientSecurity.SendConfirmedAsync(
            client,
            HttpMethod.Post,
            $"/api/v1/server/device-pairings/{device.Id}/approve",
            null,
            password,
            cancellationToken);
        _ = await ReadSuccessAsync<DeviceAuthorizationPreview>(approval, cancellationToken);
        Console.WriteLine($"{device.DeviceName} is approved. It finishes connecting on its own.");
        return 0;
    }

    internal static Uri LocalServerAddress(ServerCommandLine commandLine)
    {
        var serverUrl = commandLine.Option("--server") ?? "http://127.0.0.1:43110";
        if (!Uri.TryCreate(serverUrl, UriKind.Absolute, out var address)
            || address.Scheme is not ("http" or "https")
            || !address.IsLoopback
            || !string.IsNullOrEmpty(address.UserInfo))
        {
            throw new InvalidOperationException(
                "Pairing codes can only be created through an absolute localhost HTTP or HTTPS URL.");
        }

        return address;
    }

    internal static async Task<T> ReadSuccessAsync<T>(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (!response.IsSuccessStatusCode)
        {
            var problem = await response.Content.ReadFromJsonAsync<ApiProblem>(
                JsonOptions,
                cancellationToken);
            throw new InvalidOperationException(
                problem is null
                    ? $"The server returned HTTP {(int)response.StatusCode}."
                    : $"{problem.Code}: {problem.Message}");
        }

        return await response.Content.ReadFromJsonAsync<T>(JsonOptions, cancellationToken)
            ?? throw new InvalidOperationException("The server returned an empty response.");
    }

    private static JsonSerializerOptions CreateJsonOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(
            new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }

    private static void PrintUsage()
    {
        Console.WriteLine("Aurelia pairing commands:");
        Console.WriteLine("  pairing create [--username USER]");
        Console.WriteLine("  pairing approve [--code CODE] [--username USER] [--yes]");
        Console.WriteLine("    Approves an Apple TV that shows an 8-digit code.");
        Console.WriteLine("  Add --server URL to override http://127.0.0.1:43110.");
    }
}
