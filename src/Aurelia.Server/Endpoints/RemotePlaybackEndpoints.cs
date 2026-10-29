using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

public static class RemotePlaybackEndpoints
{
    public static void MapRemotePlayback(this WebApplication app)
    {
        var group = app.MapGroup("/api/v1/devices").RequireAuthorization();

        group.MapPost("/player/heartbeat", (HttpContext context, PlayerHeartbeatRequest request, RemotePlaybackService service) =>
        {
            return Execute(() => service.RecordHeartbeat(context.User.RequireUserId(), request));
        });

        group.MapGet("/players", (HttpContext context, string? currentDeviceId, RemotePlaybackService service) =>
        {
            return Execute(() => service.GetActiveDevices(context.User.RequireUserId(), currentDeviceId));
        });

        group.MapGet("/players/{deviceId}/status", (HttpContext context, string deviceId, RemotePlaybackService service) =>
        {
            return Execute(() => service.GetDeviceStatus(context.User.RequireUserId(), deviceId));
        });

        group.MapPost("/players/{deviceId}/commands", (HttpContext context, string deviceId, RemotePlaybackCommandRequest request, RemotePlaybackService service) =>
        {
            return Execute(() => service.SendCommand(context.User.RequireUserId(), deviceId, request));
        });

        group.MapGet("/player/commands", async (HttpContext context, string deviceId, int? waitMs, RemotePlaybackService service) =>
        {
            try
            {
                var commands = await service.GetCommandsAsync(
                    context.User.RequireUserId(),
                    deviceId,
                    waitMs ?? 0,
                    context.RequestAborted);
                return Results.Ok(commands);
            }
            catch (AccountException exception)
            {
                return Problem(exception.Code, exception.Message, exception.StatusCode);
            }
        });
    }

    private static IResult Execute<T>(Func<T> action)
    {
        try
        {
            return Results.Ok(action());
        }
        catch (AccountException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }

    private static IResult Problem(string code, string message, int statusCode)
    {
        return Results.Json(new ApiProblem(code, message), statusCode: statusCode);
    }
}
