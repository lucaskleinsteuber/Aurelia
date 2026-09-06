using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Home.Contracts;

namespace Aurelia.Home.Server.Services;

public static class LibraryCommandClient
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
                || commandLine.Action is "help" or "--help"
                    ? 0
                    : 2;
        }

        try
        {
            var serverUrl = commandLine.Option("--server") ?? "http://127.0.0.1:43110";
            if (!Uri.TryCreate(serverUrl, UriKind.Absolute, out var baseAddress)
                || baseAddress.Scheme is not ("http" or "https"))
            {
                throw new InvalidOperationException("--server must be an absolute HTTP or HTTPS URL.");
            }

            using var client = new HttpClient { BaseAddress = baseAddress };
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
                    $"Aurelia Home CLI on {Environment.MachineName}"),
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
                return commandLine.Action switch
                {
                    "add" => await AddAsync(client, commandLine, cancellationToken),
                    "list" => await ListAsync(client, cancellationToken),
                    "scan" => await ScanAsync(client, commandLine, cancellationToken),
                    "remove" => await RemoveAsync(client, commandLine, cancellationToken),
                    _ => throw new InvalidOperationException(
                        $"Unknown library action '{commandLine.Action}'."),
                };
            }
            finally
            {
                using var logout = await client.PostAsync(
                    "/api/v1/auth/logout",
                    content: null,
                    CancellationToken.None);
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

    private static async Task<int> AddAsync(
        HttpClient client,
        ServerCommandLine commandLine,
        CancellationToken cancellationToken)
    {
        var path = RequiredOption(commandLine, "--path");
        var kindText = RequiredOption(commandLine, "--kind");
        var kind = kindText.ToLowerInvariant() switch
        {
            "movies" => LibraryKind.Movies,
            "tv" => LibraryKind.TvShows,
            _ => throw new InvalidOperationException("--kind must be either movies or tv."),
        };
        var name = commandLine.Option("--name")
            ?? Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        using var response = await client.PostAsJsonAsync(
            "/api/v1/libraries",
            new CreateLibraryRequest(name, path, kind),
            JsonOptions,
            cancellationToken);
        var library = await ReadSuccessAsync<LibrarySummary>(response, cancellationToken);
        Console.WriteLine($"Added {library.Kind}: {library.Name} ({library.Id})");
        return 0;
    }

    private static async Task<int> ListAsync(HttpClient client, CancellationToken cancellationToken)
    {
        using var response = await client.GetAsync("/api/v1/libraries", cancellationToken);
        var libraries = await ReadSuccessAsync<List<LibrarySummary>>(response, cancellationToken);
        foreach (var library in libraries)
        {
            Console.WriteLine(
                $"{library.Id}  {library.Kind,-7}  {library.Availability,-11}  {library.Name}  {library.Path}");
        }

        if (libraries.Count == 0)
        {
            Console.WriteLine("No libraries configured.");
        }

        return 0;
    }

    private static async Task<int> ScanAsync(
        HttpClient client,
        ServerCommandLine commandLine,
        CancellationToken cancellationToken)
    {
        IReadOnlyList<LibraryScanSummary> scans;
        if (commandLine.HasFlag("--all"))
        {
            using var response = await client.PostAsync(
                "/api/v1/libraries/scans",
                content: null,
                cancellationToken);
            scans = await ReadSuccessAsync<List<LibraryScanSummary>>(response, cancellationToken);
        }
        else
        {
            var id = RequiredGuid(commandLine, "--id");
            using var response = await client.PostAsync(
                $"/api/v1/libraries/{id}/scans",
                content: null,
                cancellationToken);
            scans = [await ReadSuccessAsync<LibraryScanSummary>(response, cancellationToken)];
        }

        foreach (var queued in scans)
        {
            Console.WriteLine($"Queued scan {queued.Id} for library {queued.LibraryId}.");
        }

        foreach (var queued in scans)
        {
            LibraryScanSummary current;
            do
            {
                await Task.Delay(500, cancellationToken);
                using var response = await client.GetAsync(
                    $"/api/v1/scans/{queued.Id}",
                    cancellationToken);
                current = await ReadSuccessAsync<LibraryScanSummary>(response, cancellationToken);
                Console.Write(
                    $"\r{current.State}: {current.FilesProcessed}/{current.FilesDiscovered} files");
            }
            while (current.State is LibraryScanState.Queued or LibraryScanState.Running);

            Console.WriteLine();
            Console.WriteLine(
                $"Added {current.AddedFiles}, updated {current.UpdatedFiles}, "
                + $"missing {current.MissingFiles}, skipped {current.SkippedFiles}.");
            foreach (var issue in current.Issues)
            {
                Console.WriteLine($"[{issue.Code}] {issue.Message} {issue.Path}".TrimEnd());
            }

            if (current.State != LibraryScanState.Completed)
            {
                throw new InvalidOperationException(current.Error ?? "The library scan did not complete.");
            }
        }

        return 0;
    }

    private static async Task<int> RemoveAsync(
        HttpClient client,
        ServerCommandLine commandLine,
        CancellationToken cancellationToken)
    {
        if (!commandLine.HasFlag("--yes"))
        {
            throw new InvalidOperationException(
                "Removing a library requires --yes. Media files are never deleted.");
        }

        var id = RequiredGuid(commandLine, "--id");
        using var response = await client.DeleteAsync($"/api/v1/libraries/{id}", cancellationToken);
        await EnsureSuccessAsync(response, cancellationToken);
        Console.WriteLine($"Removed library {id}. Media files were not changed.");
        return 0;
    }

    private static string RequiredOption(ServerCommandLine commandLine, string name)
    {
        return commandLine.Option(name)
            ?? throw new InvalidOperationException($"{name} is required.");
    }

    private static Guid RequiredGuid(ServerCommandLine commandLine, string name)
    {
        return Guid.TryParse(RequiredOption(commandLine, name), out var value)
            ? value
            : throw new InvalidOperationException($"{name} must be a valid ID.");
    }

    private static async Task<T> ReadSuccessAsync<T>(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        await EnsureSuccessAsync(response, cancellationToken);
        return await response.Content.ReadFromJsonAsync<T>(JsonOptions, cancellationToken)
            ?? throw new InvalidOperationException("The server returned an empty response.");
    }

    private static async Task EnsureSuccessAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        var problem = await response.Content.ReadFromJsonAsync<ApiProblem>(
            JsonOptions,
            cancellationToken);
        throw new InvalidOperationException(
            problem is null
                ? $"The server returned HTTP {(int)response.StatusCode}."
                : $"{problem.Code}: {problem.Message}");
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
        Console.WriteLine("Aurelia Home library commands:");
        Console.WriteLine("  library add --kind movies|tv --path PATH [--name NAME] [--username USER]");
        Console.WriteLine("  library list [--username USER]");
        Console.WriteLine("  library scan --id ID|--all [--username USER]");
        Console.WriteLine("  library remove --id ID --yes [--username USER]");
        Console.WriteLine("  Add --server URL to override http://127.0.0.1:43110.");
    }
}
