using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Http;

namespace Aurelia.Server.Tests;

internal static class ApiTestClient
{
    public const string BootstrapToken = "test-only-bootstrap-token-with-256-bits-0001";
    public static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();

    public static async Task<AuthenticationResponse> SetupOwnerAsync(
        HttpClient client,
        string username = "lucas",
        string password = "correct horse battery staple",
        string deviceName = "Test Mac")
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/setup/owner");
        request.Headers.Add("X-Aurelia-Bootstrap-Token", BootstrapToken);
        request.Content = JsonContent.Create(
            new SetupOwnerRequest(username, password, deviceName),
            options: JsonOptions);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ReadAsync<AuthenticationResponse>(response);
    }

    public static HttpRequestMessage Authorized(
        HttpMethod method,
        string path,
        string token,
        object? body = null)
    {
        var request = new HttpRequestMessage(method, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body is not null)
        {
            request.Content = JsonContent.Create(body, options: JsonOptions);
        }

        return request;
    }

    public static async Task<T> ReadAsync<T>(HttpResponseMessage response)
    {
        return await response.Content.ReadFromJsonAsync<T>(JsonOptions)
            ?? throw new InvalidOperationException("The API returned an empty JSON response.");
    }

    // Existing positive workflow tests must perform the same reauthentication as a client.
    // Negative approval tests deliberately use HttpClient.SendAsync directly.
    public static async Task<HttpResponseMessage> SendAsync(HttpClient client, HttpRequestMessage request,
        HttpCompletionOption completionOption = HttpCompletionOption.ResponseContentRead, CancellationToken cancellationToken = default)
    {
        var policyRequest = new DefaultHttpContext().Request;
        policyRequest.Method = request.Method.Method;
        policyRequest.Path = request.RequestUri?.OriginalString.Split('?')[0];
        if (request.Headers.Authorization is { } authorization && ServerRequestGuard.RequiresApproval(policyRequest))
        {
            var payload = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(cancellationToken);
            using var approvalRequest = Authorized(HttpMethod.Post, "/api/v1/server/approval", authorization.Parameter!,
                new AdministrationApprovalRequest(request.Method.Method + " " + policyRequest.Path,
                    AdministrationApprovalStore.Hash(payload), "correct horse battery staple"));
            using var approvalResponse = await client.SendAsync(approvalRequest, cancellationToken);
            if (approvalResponse.IsSuccessStatusCode)
                request.Headers.Add("X-Aurelia-Approval", (await ReadAsync<AdministrationApprovalResponse>(approvalResponse)).Token);
        }
        return await client.SendAsync(request, completionOption, cancellationToken);
    }

    public static async Task GrantExistingLibrariesAsync(HttpClient client, string ownerToken, Guid userId)
    {
        using var libraries = Authorized(HttpMethod.Get, "/api/v1/libraries", ownerToken);
        using var response = await client.SendAsync(libraries);
        response.EnsureSuccessStatusCode();
        var roots = await ReadAsync<List<LibrarySummary>>(response);
        using var grant = Authorized(HttpMethod.Put, $"/api/v1/users/{userId}/access", ownerToken,
            new UpdateUserAccessRequest(true, roots.Select(root => root.Id).ToArray()));
        using var granted = await SendAsync(client, grant);
        granted.EnsureSuccessStatusCode();
    }

    private static JsonSerializerOptions CreateJsonOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(
            new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }
}
