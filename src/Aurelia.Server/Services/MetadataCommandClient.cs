using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public static class MetadataCommandClient
{
    private static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();

    public static async Task<int> RunAsync(ServerCommandLine commandLine, CancellationToken cancellationToken)
    {
        if (commandLine.Action is null or "help" or "--help" || commandLine.HasFlag("--help"))
        {
            PrintUsage();
            return commandLine.Action is "help" or "--help" || commandLine.HasFlag("--help") ? 0 : 2;
        }

        try
        {
            var serverUrl = commandLine.Option("--server") ?? "http://127.0.0.1:43110";
            var baseAddress = CommandClientSecurity.ValidateAddress(serverUrl);
            using var client = CommandClientSecurity.CreateClient(baseAddress);
            var username = commandLine.Username;
            if (string.IsNullOrWhiteSpace(username))
            {
                Console.Error.Write("Username: ");
                username = Console.ReadLine();
            }
            var password = commandLine.ReadPassword();
            using var login = await client.PostAsJsonAsync("/api/v1/auth/login",
                new LoginRequest(username ?? string.Empty, password, $"Aurelia CLI on {Environment.MachineName}"),
                JsonOptions, cancellationToken);
            var authentication = await ReadAsync<AuthenticationResponse>(login, cancellationToken);
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", authentication.Token);
            try
            {
                return commandLine.Action switch
                {
                    "status" => await StatusAsync(client, cancellationToken),
                    "configure" => await ConfigureAsync(client, commandLine, password, cancellationToken),
                    "refresh" => await RefreshAsync(client, commandLine, cancellationToken),
                    "reviews" => await ReviewsAsync(client, cancellationToken),
                    "disable" => await DisableAsync(client, password, cancellationToken),
                    _ => throw new InvalidOperationException($"Unknown metadata action '{commandLine.Action}'."),
                };
            }
            finally
            {
                using var logout = await client.PostAsync("/api/v1/auth/logout", null, CancellationToken.None);
            }
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or InvalidOperationException or JsonException or IOException)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    private static async Task<int> StatusAsync(HttpClient client, CancellationToken cancellationToken)
    {
        using var response = await client.GetAsync("/api/v1/metadata/provider", cancellationToken);
        PrintStatus(await ReadAsync<MetadataProviderStatus>(response, cancellationToken));
        return 0;
    }

    private static async Task<int> ConfigureAsync(HttpClient client, ServerCommandLine commandLine, string password, CancellationToken cancellationToken)
    {
        var token = commandLine.ReadSecret("TMDB API Read Access Token: ");
        using var response = await CommandClientSecurity.SendConfirmedAsync(client, HttpMethod.Put, "/api/v1/metadata/provider",
            new UpdateMetadataProviderRequest(true, commandLine.Option("--language") ?? "en-US", token), password, cancellationToken);
        PrintStatus(await ReadAsync<MetadataProviderStatus>(response, cancellationToken));
        return 0;
    }

    private static async Task<int> RefreshAsync(HttpClient client, ServerCommandLine commandLine, CancellationToken cancellationToken)
    {
        var query = new List<string>();
        if (commandLine.Option("--library") is { } library) query.Add($"libraryId={RequireGuid(library)}");
        if (commandLine.Option("--media") is { } media) query.Add($"mediaId={RequireGuid(media)}");
        using var response = await client.PostAsync("/api/v1/metadata/jobs" + (query.Count == 0 ? string.Empty : "?" + string.Join('&', query)), null, cancellationToken);
        var job = await ReadAsync<MetadataJobSummary>(response, cancellationToken);
        while (job.State is MetadataJobState.Queued or MetadataJobState.Running)
        {
            Console.Write($"\r{job.State}: {job.ItemsProcessed}/{job.ItemsTotal}");
            await Task.Delay(500, cancellationToken);
            using var poll = await client.GetAsync($"/api/v1/metadata/jobs/{job.Id}", cancellationToken);
            job = await ReadAsync<MetadataJobSummary>(poll, cancellationToken);
        }
        Console.WriteLine($"\r{job.State}: matched {job.ItemsMatched}, review {job.ItemsNeedingReview}, failed {job.ItemsFailed}");
        return job.State == MetadataJobState.Completed ? 0 : 1;
    }

    private static async Task<int> ReviewsAsync(HttpClient client, CancellationToken cancellationToken)
    {
        using var response = await client.GetAsync("/api/v1/metadata/reviews", cancellationToken);
        var reviews = await ReadAsync<List<MetadataReviewSummary>>(response, cancellationToken);
        foreach (var review in reviews) Console.WriteLine($"{review.MediaId}  {review.Title}  {review.Reason}");
        if (reviews.Count == 0) Console.WriteLine("No metadata matches need review.");
        return 0;
    }

    private static async Task<int> DisableAsync(HttpClient client, string password, CancellationToken cancellationToken)
    {
        using var response = await CommandClientSecurity.SendConfirmedAsync(client, HttpMethod.Delete, "/api/v1/metadata/provider/token", null, password, cancellationToken);
        PrintStatus(await ReadAsync<MetadataProviderStatus>(response, cancellationToken));
        return 0;
    }

    private static Guid RequireGuid(string value) => Guid.TryParse(value, out var parsed)
        ? parsed : throw new InvalidOperationException("Metadata scope IDs must be valid UUIDs.");

    private static void PrintStatus(MetadataProviderStatus status) => Console.WriteLine(
        $"TMDB: {(status.Enabled ? "enabled" : "disabled")}; token: {(status.HasToken ? "configured" : "missing")}; language: {status.Language}; artwork: {status.ArtworkBytes}/{status.ArtworkLimitBytes} bytes");

    private static async Task<T> ReadAsync<T>(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (!response.IsSuccessStatusCode)
        {
            var problem = await response.Content.ReadFromJsonAsync<ApiProblem>(JsonOptions, cancellationToken);
            throw new InvalidOperationException(problem is null ? $"The server returned HTTP {(int)response.StatusCode}." : $"{problem.Code}: {problem.Message}");
        }
        return await response.Content.ReadFromJsonAsync<T>(JsonOptions, cancellationToken)
            ?? throw new InvalidOperationException("The server returned an empty response.");
    }

    private static JsonSerializerOptions CreateJsonOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, false));
        return options;
    }

    private static void PrintUsage()
    {
        Console.WriteLine("Aurelia metadata commands:");
        Console.WriteLine("  metadata status [--username USER]");
        Console.WriteLine("  metadata configure [--language en-US] [--username USER]");
        Console.WriteLine("  metadata refresh [--library ID|--media ID] [--username USER]");
        Console.WriteLine("  metadata reviews [--username USER]");
        Console.WriteLine("  metadata disable [--username USER]");
        Console.WriteLine("  Tokens and passwords are prompted without echo and are never command-line arguments.");
    }
}
