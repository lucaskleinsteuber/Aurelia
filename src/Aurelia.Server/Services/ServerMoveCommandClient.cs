using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

/// <summary>
/// <c>aurelia move …</c> (docs/SERVER_MOVE.md). On the old server, as its owner: <c>code</c>,
/// <c>export FILE</c>, <c>status</c> and <c>undo</c>. On the new server before it has an owner:
/// <c>receive</c>, which <c>sudo aurelia setup</c> runs with the setup code from the data folder.
/// </summary>
public static class ServerMoveCommandClient
{
    private static readonly JsonSerializerOptions Json = CreateJson();

    public static async Task<int> RunAsync(ServerCommandLine commandLine, CancellationToken token)
    {
        if (commandLine.Action is null or "help" or "--help" || commandLine.HasFlag("--help"))
        {
            PrintUsage();
            return commandLine.Action is null ? 2 : 0;
        }
        try
        {
            return commandLine.Action switch
            {
                "receive" => await ReceiveAsync(commandLine, token),
                "code" or "export" or "status" or "undo" => await AsOwnerAsync(commandLine, token),
                _ => Unknown(commandLine.Action),
            };
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or InvalidOperationException
            or JsonException or IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    private static int Unknown(string action)
    {
        Console.Error.WriteLine($"Unknown move action '{action}'.");
        PrintUsage();
        return 2;
    }

    private static async Task<int> AsOwnerAsync(ServerCommandLine commandLine, CancellationToken token)
    {
        string? file = null;
        if (commandLine.Action == "export")
        {
            file = commandLine.Positionals.Count > 0 ? commandLine.Positionals[0] : commandLine.Option("--file");
            if (string.IsNullOrWhiteSpace(file))
            {
                Console.Error.WriteLine("Name the moving file: aurelia move export /media/usb/server.aureliamove");
                return 2;
            }
            file = Path.GetFullPath(file);
            if (File.Exists(file) || Directory.Exists(file))
            {
                Console.Error.WriteLine($"{file} already exists. Choose another name.");
                return 1;
            }
        }
        using var client = CommandClientSecurity.CreateClient(PairingCommandClient.LocalServerAddress(commandLine));
        var username = commandLine.Username;
        if (string.IsNullOrWhiteSpace(username))
        {
            Console.Error.Write("Owner name: ");
            username = Console.ReadLine();
        }
        var password = commandLine.ReadPassword();
        using var login = await client.PostAsJsonAsync("/api/v1/auth/login",
            new LoginRequest(username ?? string.Empty, password, $"Aurelia CLI on {Environment.MachineName}"), Json, token);
        var device = await PairingCommandClient.ReadSuccessAsync<AuthenticationResponse>(login, token);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", device.Token);
        try
        {
            await CommandClientSecurity.UnlockViewingAndManagementAsync(client, device, commandLine, password, token);
            switch (commandLine.Action)
            {
                case "status":
                    {
                        using var response = await client.GetAsync("/api/v1/server/move", token);
                        PrintStatus(await PairingCommandClient.ReadSuccessAsync<ServerMoveStatus>(response, token));
                        return 0;
                    }
                case "undo":
                    {
                        using (var current = await client.GetAsync("/api/v1/server/move", token))
                        {
                            var status = await PairingCommandClient.ReadSuccessAsync<ServerMoveStatus>(current, token);
                            if (status.State == "none")
                            {
                                Console.WriteLine("This server is not moving and has not moved.");
                                return 0;
                            }
                            if (status.State == "moved" && !Confirm(commandLine,
                                "Turn the new server off first: two copies of the same server must never run at once. Undo the move now? [y/N] "))
                            {
                                Console.WriteLine("Nothing was changed.");
                                return 1;
                            }
                        }
                        using var response = await CommandClientSecurity.SendConfirmedAsync(client, HttpMethod.Delete, "/api/v1/server/move", null, password, token);
                        PrintStatus(await PairingCommandClient.ReadSuccessAsync<ServerMoveStatus>(response, token));
                        return 0;
                    }
                case "code":
                    {
                        using var response = await CommandClientSecurity.SendConfirmedAsync(client, HttpMethod.Post, "/api/v1/server/move",
                            new StartServerMoveRequest("network"), password, token);
                        var started = await PairingCommandClient.ReadSuccessAsync<ServerMoveStarted>(response, token);
                        using var info = await client.GetAsync("/api/v1/server/info", token);
                        var server = await PairingCommandClient.ReadSuccessAsync<ServerInfoResponse>(info, token);
                        Console.WriteLine($"Move code: {started.Code}");
                        Console.WriteLine($"Valid until: {started.ExpiresAt?.ToLocalTime():t} (15 minutes, one use)");
                        Console.WriteLine("On the new server, choose Move from another Aurelia server, then enter this server's address and the code:");
                        foreach (var address in ServerMoveTransport.LocalAddresses(server.LanHttpsPort ?? ServerRuntimeOptions.DefaultLanHttpsPort))
                            Console.WriteLine($"  {address}");
                        Console.WriteLine("Follow the move with: aurelia move status");
                        return 0;
                    }
                default:
                    {
                        var passphrase = commandLine.ReadSecret("Passphrase for the moving file (at least 12 characters): ");
                        if (passphrase.Length < 12)
                        {
                            Console.Error.WriteLine("Use a passphrase with at least 12 characters.");
                            return 2;
                        }
                        if (!commandLine.PasswordFromStandardInput && !Console.IsInputRedirected && commandLine.ReadSecret("Repeat the passphrase: ") != passphrase)
                        {
                            Console.Error.WriteLine("The passphrases do not match. Nothing was changed.");
                            return 1;
                        }
                        Console.WriteLine("Writing the moving file…");
                        using var response = await CommandClientSecurity.SendConfirmedAsync(client, HttpMethod.Post, "/api/v1/server/move",
                            new StartServerMoveRequest("file", passphrase), password, token);
                        var started = await PairingCommandClient.ReadSuccessAsync<ServerMoveStarted>(response, token);
                        var transfer = $"/api/v1/server/backups/transfers/{started.TransferId:D}";
                        using (var download = await client.GetAsync(transfer, HttpCompletionOption.ResponseHeadersRead, token))
                        {
                            if (!download.IsSuccessStatusCode) throw new InvalidOperationException($"The moving file could not be downloaded (HTTP {(int)download.StatusCode}).");
                            await using var output = PrivateFilePermissions.OpenNewPrivateFile(file!);
                            await download.Content.CopyToAsync(output, token);
                            output.Flush(flushToDisk: true);
                        }
                        using (await client.DeleteAsync(transfer, token)) { }
                        Console.WriteLine($"Saved {file} ({new FileInfo(file!).Length / (1024 * 1024.0):0.0} MB). Media files are not in it; they stay where they are.");
                        Console.WriteLine("Set up the new server with: sudo aurelia setup, and choose to move with this file and its passphrase.");
                        return 0;
                    }
            }
        }
        finally
        {
            await CommandClientSecurity.EndCommandSessionAsync(client, device);
        }
    }

    /// <summary>Moves into this server, which has no owner yet, from the old server or a moving file.</summary>
    private static async Task<int> ReceiveAsync(ServerCommandLine commandLine, CancellationToken token)
    {
        var codeFile = commandLine.Option("--setup-code-file")
            ?? Path.Combine(commandLine.Option("--data-dir") ?? "/var/lib/aurelia", BrowserSetup.FileName);
        var setupCode = File.Exists(codeFile) ? (await File.ReadAllTextAsync(codeFile, token)).Trim() : string.Empty;
        if (setupCode.Length == 0)
        {
            Console.Error.WriteLine("No setup code: this server already has an owner, or it isn't running. Run: sudo aurelia status");
            return 1;
        }
        using var client = CommandClientSecurity.CreateClient(PairingCommandClient.LocalServerAddress(commandLine));
        client.Timeout = TimeSpan.FromMinutes(30);
        client.DefaultRequestHeaders.Add("X-Aurelia-Setup-Code", setupCode);
        using (var discard = await client.DeleteAsync("/api/v1/setup/move", token))
            _ = await PairingCommandClient.ReadSuccessAsync<SetupMoveStatus>(discard, token);

        Console.WriteLine("How does the old server's data come here?");
        Console.WriteLine("  1) Over the network: the old server shows a move code (Move to a New Server… or: aurelia move code)");
        Console.WriteLine("  2) With a moving file (Move to a New Server… › Moving File, or: aurelia move export FILE)");
        var way = Choice("Choose 1 or 2 [1]: ");
        SetupMoveStatus status;
        if (way is "2" or "file")
        {
            var path = Path.GetFullPath(Ask("Path of the moving file: "));
            if (!File.Exists(path))
            {
                Console.Error.WriteLine($"{path} was not found.");
                return 1;
            }
            Console.WriteLine("Reading the moving file…");
            SetupMoveUpload upload;
            await using (var input = File.OpenRead(path))
            {
                using var content = new StreamContent(input, 1024 * 1024);
                content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
                content.Headers.ContentLength = input.Length;
                using var response = await client.PutAsync("/api/v1/setup/move/file", content, token);
                upload = await PairingCommandClient.ReadSuccessAsync<SetupMoveUpload>(response, token);
            }
            while (true)
            {
                var passphrase = commandLine.ReadSecret("Passphrase of the moving file: ");
                using var response = await client.PostAsJsonAsync($"/api/v1/setup/move/file/{upload.UploadId:D}/open", new SetupMoveOpenRequest(passphrase), Json, token);
                if (response.IsSuccessStatusCode)
                {
                    status = await PairingCommandClient.ReadSuccessAsync<SetupMoveStatus>(response, token);
                    break;
                }
                var problem = await response.Content.ReadFromJsonAsync<ApiProblem>(Json, token);
                if (problem?.Code != "backup_invalid" || Console.IsInputRedirected) throw new InvalidOperationException(problem?.Message ?? "The moving file could not be opened.");
                Console.Error.WriteLine("The passphrase doesn't open this moving file. Try again (Ctrl+C ends).");
            }
        }
        else
        {
            var address = Ask("Address of the old server (for example 192.168.1.20): ");
            var code = Ask("Move code shown on the old server: ");
            using var response = await client.PostAsJsonAsync("/api/v1/setup/move/network", new SetupMoveNetworkRequest(address, code), Json, token);
            status = await PairingCommandClient.ReadSuccessAsync<SetupMoveStatus>(response, token);
        }
        var shown = -1L;
        while (status.State == "fetching")
        {
            if (status.Progress is { } progress && progress.Received / (16 * 1024 * 1024) != shown)
            {
                shown = progress.Received / (16 * 1024 * 1024);
                Console.WriteLine(progress.Expected is { } total ? $"Received {progress.Received / 1048576.0:0} of {total / 1048576.0:0} MB" : $"Received {progress.Received / 1048576.0:0} MB");
            }
            await Task.Delay(TimeSpan.FromSeconds(1), token);
            using var response = await client.GetAsync("/api/v1/setup/move", token);
            status = await PairingCommandClient.ReadSuccessAsync<SetupMoveStatus>(response, token);
        }
        if (status.State != "received")
        {
            Console.Error.WriteLine(status.Error ?? "The move did not arrive. Nothing changed on either server.");
            return 1;
        }
        Console.WriteLine($"The data of “{status.Source?.Name}” arrived. Where are its media files on this computer now?");
        var mappings = new List<MovePathMapping>();
        foreach (var location in status.Locations)
            mappings.Add(new(location.Id, await ChooseFolderAsync(client, location, token)));
        Console.WriteLine();
        foreach (var (location, mapping) in status.Locations.Zip(mappings))
            Console.WriteLine($"  {location.Name}: {mapping.Path ?? "later (offline until Storage Location Moved…)"}");
        if (!Confirm(commandLine, "Finish the move? This server restarts with the old server's identity, library and sign-ins. [y/N] "))
        {
            using (await client.DeleteAsync("/api/v1/setup/move", token)) { }
            Console.WriteLine("Nothing was changed. The received data was discarded.");
            return 1;
        }
        using (var finish = await client.PostAsJsonAsync("/api/v1/setup/move/finish", new SetupMoveFinishRequest(mappings), Json, token))
            status = await PairingCommandClient.ReadSuccessAsync<SetupMoveStatus>(finish, token);
        Console.WriteLine("Moving in: the server restarts with the moved data…");
        client.DefaultRequestHeaders.Remove("X-Aurelia-Setup-Code");
        for (var attempt = 0; attempt < 120; attempt++)
        {
            await Task.Delay(TimeSpan.FromSeconds(1), token);
            try
            {
                using var response = await client.GetAsync("/api/v1/server/info", token);
                if (!response.IsSuccessStatusCode) continue;
                var info = await response.Content.ReadFromJsonAsync<ServerInfoResponse>(Json, token);
                if (info?.ServerId != status.Source?.ServerId || info?.IsSetup != true) continue;
                Console.WriteLine($"Moved: this server is now “{info.Name}”. Devices find it on their own and stay signed in;");
                Console.WriteLine("browsers sign in once at this server's address. The old server stops offering itself.");
                if (info.DisplayFingerprint is not null) Console.WriteLine($"Verification fingerprint: {info.DisplayFingerprint}");
                return 0;
            }
            catch (HttpRequestException) { }
        }
        Console.Error.WriteLine("The server did not come back with the moved data yet. See: aurelia logs");
        return 1;
    }

    private static async Task<string?> ChooseFolderAsync(HttpClient client, SetupMoveLocation location, CancellationToken token)
    {
        Console.WriteLine();
        Console.WriteLine($"{location.Name} (was {location.OldPath})");
        var suggestions = location.Suggestions;
        for (var index = 0; index < suggestions.Count; index++)
            Console.WriteLine($"  {index + 1}) {suggestions[index].Path}: {MatchText(suggestions[index].Matched, location.Sampled)}");
        Console.WriteLine("  p) Type a folder");
        Console.WriteLine("  l) Later: the location stays offline with its titles");
        while (true)
        {
            var best = suggestions.Count > 0 ? "1" : "l";
            var answer = Choice($"Choose [{best}]: ");
            if (answer.Length == 0) answer = best;
            if (answer is "l" or "later") return null;
            if (int.TryParse(answer, System.Globalization.CultureInfo.InvariantCulture, out var number) && number >= 1 && number <= suggestions.Count)
                return suggestions[number - 1].Path;
            if (answer is not ("p" or "path")) continue;
            var path = Ask("Folder on this computer: ");
            using var response = await client.PostAsJsonAsync("/api/v1/setup/move/locations/preview", new SetupMovePreviewRequest(location.Id, path), Json, token);
            if (!response.IsSuccessStatusCode)
            {
                var problem = await response.Content.ReadFromJsonAsync<ApiProblem>(Json, token);
                Console.Error.WriteLine(problem?.Message ?? "That folder can't be used.");
                continue;
            }
            var match = await PairingCommandClient.ReadSuccessAsync<MoveLocationMatch>(response, token);
            Console.WriteLine($"  {MatchText(match.Matched, match.Sampled)}");
            if (match.Matched > 0 || match.Sampled == 0 || Choice("Use it anyway? [y/N] ") is "y" or "yes") return path;
        }
    }

    internal static string MatchText(int matched, int sampled) => sampled <= 0 ? "no files to compare"
        : matched <= 0 ? $"none of {sampled} sample files found"
        : matched >= sampled ? $"all {sampled} sample files found" : $"{matched} of {sampled} sample files found";

    private static void PrintStatus(ServerMoveStatus status)
    {
        Console.WriteLine(status.State switch
        {
            "waiting" when status.Method == "network" => $"Waiting for the new server; the move code works until {status.ExpiresAt?.ToLocalTime():t}.",
            "waiting" => "A moving file is ready; set up the new server with it.",
            "transferring" => "The new server is receiving the data.",
            "moved" => $"This server moved to “{status.MovedTo?.Name}” on {status.MovedAt?.ToLocalTime():g}. Devices switch there on their own.",
            _ => "This server is not moving.",
        });
        foreach (var address in status.MovedTo?.Addresses ?? []) Console.WriteLine($"  {address}");
        if (status.State == "moved") Console.WriteLine("Undo with: sudo aurelia move undo (turn the new server off first)");
    }

    private static bool Confirm(ServerCommandLine commandLine, string question) =>
        commandLine.HasFlag("--yes") || Choice(question) is "y" or "yes";

    /// <summary>A typed answer as it is, such as a path or an address.</summary>
    private static string Ask(string question)
    {
        Console.Error.Write(question);
        return (Console.ReadLine() ?? string.Empty).Trim();
    }

    /// <summary>A typed choice in lower case: a number, a letter, yes or no.</summary>
    private static string Choice(string question) => Ask(question).ToLowerInvariant();

    private static void PrintUsage()
    {
        Console.WriteLine("Aurelia move commands (docs/SERVER_MOVE.md):");
        Console.WriteLine("  move code [--username OWNER]          Show a move code for the new server (15 minutes, one use)");
        Console.WriteLine("  move export FILE [--username OWNER]   Write an encrypted moving file, protected by a passphrase");
        Console.WriteLine("  move status [--username OWNER]        Is this server moving, or where did it move");
        Console.WriteLine("  move undo [--username OWNER] [--yes]  This server answers devices again (turn the new one off first)");
        Console.WriteLine("  move receive --data-dir DIR           Move into this new server (run by: sudo aurelia setup)");
        Console.WriteLine("  Add --server URL to override http://127.0.0.1:43110.");
    }

    private static JsonSerializerOptions CreateJson()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }
}
