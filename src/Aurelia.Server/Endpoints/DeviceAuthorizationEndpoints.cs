using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

public static class DeviceAuthorizationEndpoints
{
    public static void MapDeviceAuthorization(this WebApplication app)
    {
        var pairing = app.MapGroup("/api/v1/auth/device-pairings");
        pairing.MapPost("", (DeviceAuthorizationStartRequest request, DeviceAuthorizationService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            return ExecuteAsync(() => service.StartAsync(request.DeviceName, Address(context), context.RequestAborted));
        });
        pairing.MapPost("/{id:guid}/status", (Guid id, DeviceAuthorizationSecretRequest request, DeviceAuthorizationService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            context.Response.Headers.CacheControl = "no-store";
            return ExecuteAsync(() => service.StatusAsync(id, request.Secret, Address(context), context.RequestAborted));
        });
        pairing.MapPost("/{id:guid}/ack", (Guid id, DeviceAuthorizationSecretRequest request, DeviceAuthorizationService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            return ExecuteAsync(() => service.AcknowledgeAsync(id, request.Secret, Address(context), context.RequestAborted));
        });
        pairing.MapPost("/{id:guid}/cancel", (Guid id, DeviceAuthorizationSecretRequest request, DeviceAuthorizationService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            return ExecuteAsync(() => service.CancelAsync(id, request.Secret, Address(context), context.RequestAborted));
        });

        var management = app.MapGroup("/api/v1/server/device-pairings").RequireAuthorization("Owner");
        management.MapPost("/lookup", (DeviceAuthorizationLookupRequest request, DeviceAuthorizationService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            return ExecuteAsync(() => service.LookupAsync(request.Code, context.User.RequireUserId(), context.User.RequireSessionId(),
                context.User.RequireProfileSessionId(), Address(context), context.RequestAborted));
        });
        management.MapPost("/{id:guid}/approve", (Guid id, DeviceAuthorizationService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            return ExecuteAsync(() => service.DecideAsync(id, true, context.User.RequireUserId(), context.User.RequireSessionId(),
                context.User.RequireProfileSessionId(), context.RequestAborted));
        });
        management.MapPost("/{id:guid}/deny", (Guid id, DeviceAuthorizationService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            return ExecuteAsync(() => service.DecideAsync(id, false, context.User.RequireUserId(), context.User.RequireSessionId(),
                context.User.RequireProfileSessionId(), context.RequestAborted));
        });
    }

    private static string Address(HttpContext context) => context.Connection.RemoteIpAddress?.ToString() ?? "local";

    private static async Task<T> ExecuteAsync<T>(Func<Task<T>> action)
    {
        try { return await action(); }
        catch (Exception exception) when (StorageRecovery.IsRecoverable(exception))
        {
            throw new AccountException("server_storage_unavailable", "The device pairing could not be saved. Check server storage and try again.", 503);
        }
    }

    private static void RequirePrivateTransport(HttpContext context)
    {
        context.Response.Headers.CacheControl = "no-store";
        if (!context.Request.IsHttps && context.Connection.RemoteIpAddress is { } ip && !System.Net.IPAddress.IsLoopback(ip))
            throw new AccountException("https_required", "Device pairing requires the verified HTTPS connection.", 403);
    }
}
