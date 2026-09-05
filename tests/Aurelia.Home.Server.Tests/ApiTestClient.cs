using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Home.Contracts;

namespace Aurelia.Home.Server.Tests;

internal static class ApiTestClient
{
    public static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();

    public static async Task<AuthenticationResponse> SetupOwnerAsync(
        HttpClient client,
        string username = "lucas",
        string password = "correct horse battery staple",
        string deviceName = "Test Mac")
    {
        using var response = await client.PostAsJsonAsync(
            "/api/v1/setup/owner",
            new SetupOwnerRequest(username, password, deviceName),
            JsonOptions);
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

    private static JsonSerializerOptions CreateJsonOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(
            new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }
}
