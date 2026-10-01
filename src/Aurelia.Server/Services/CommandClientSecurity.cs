using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public static class CommandClientSecurity
{
    private static readonly JsonSerializerOptions Json = CreateJson();

    public static Uri ValidateAddress(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var address)
            || address.Scheme is not ("http" or "https") || !string.IsNullOrEmpty(address.UserInfo)
            || (address.Scheme == "http" && !address.IsLoopback))
            throw new InvalidOperationException("Remote CLI access requires certificate-verified HTTPS. HTTP is only allowed on localhost.");
        return address;
    }

    public static HttpClient CreateClient(Uri address) => new(new HttpClientHandler { AllowAutoRedirect = false })
    { BaseAddress = ValidateAddress(address.AbsoluteUri) };

    public static async Task<HttpResponseMessage> SendConfirmedAsync(HttpClient client, HttpMethod method,
        string path, object? body, string password, CancellationToken token)
    {
        _ = ValidateAddress(client.BaseAddress?.AbsoluteUri ?? string.Empty);
        var payload = body is null ? [] : JsonSerializer.SerializeToUtf8Bytes(body, Json);
        using var approval = await client.PostAsJsonAsync("/api/v1/server/approval",
            new AdministrationApprovalRequest(method.Method + " " + path, AdministrationApprovalStore.Hash(payload), password), Json, token);
        var grant = await PairingCommandClient.ReadSuccessAsync<AdministrationApprovalResponse>(approval, token);
        using var request = new HttpRequestMessage(method, path);
        if (body is not null)
        {
            request.Content = new ByteArrayContent(payload);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        }
        request.Headers.Add("X-Aurelia-Approval", grant.Token);
        return await client.SendAsync(request, token);
    }

    private static JsonSerializerOptions CreateJson()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }
}
