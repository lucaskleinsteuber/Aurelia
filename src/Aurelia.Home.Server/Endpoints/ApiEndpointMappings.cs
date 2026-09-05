using System.Net;
using System.Reflection;
using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Authentication;
using Aurelia.Home.Server.Data;
using Aurelia.Home.Server.Services;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Home.Server.Endpoints;

public static class ApiEndpointMappings
{
    public static void MapAureliaHomeApi(this WebApplication app)
    {
        var api = app.MapGroup("/api/v1");

        api.MapGet("/health", HealthAsync);
        api.MapGet("/server/info", ServerInfoAsync);
        api.MapPost("/setup/owner", SetupOwnerAsync)
            .RequireRateLimiting("authentication");

        var authentication = api.MapGroup("/auth");
        authentication.MapPost("/login", LoginAsync)
            .RequireRateLimiting("authentication");
        authentication.MapPost("/pair", RedeemPairingCodeAsync)
            .RequireRateLimiting("authentication");
        authentication.MapPost("/logout", LogoutAsync)
            .RequireAuthorization();
        authentication.MapGet("/sessions", ListSessionsAsync)
            .RequireAuthorization();
        authentication.MapDelete("/sessions/{sessionId:guid}", RevokeSessionAsync)
            .RequireAuthorization();
        authentication.MapPost("/pairings", CreatePairingCodeAsync)
            .RequireAuthorization()
            .RequireRateLimiting("pairing");

        var users = api.MapGroup("/users").RequireAuthorization("Administrator");
        users.MapGet(string.Empty, ListUsersAsync);
        users.MapPost(string.Empty, CreateUserAsync);
        users.MapPut("/{userId:guid}/role", ChangeUserRoleAsync);
        users.MapDelete("/{userId:guid}", DeleteUserAsync);
    }

    private static async Task<IResult> HealthAsync(
        AureliaHomeDbContext database,
        CancellationToken cancellationToken)
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0";
        try
        {
            var canConnect = await database.Database.CanConnectAsync(cancellationToken);
            var response = new HealthResponse(
                canConnect ? "ok" : "degraded",
                version,
                DateTimeOffset.UtcNow);
            return Results.Json(
                response,
                statusCode: canConnect
                    ? StatusCodes.Status200OK
                    : StatusCodes.Status503ServiceUnavailable);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            return Results.Json(
                new HealthResponse("degraded", version, DateTimeOffset.UtcNow),
                statusCode: StatusCodes.Status503ServiceUnavailable);
        }
    }

    private static async Task<IResult> ServerInfoAsync(
        AureliaHomeDbContext database,
        ServerRuntimeOptions runtime,
        CancellationToken cancellationToken)
    {
        var identity = await database.ServerIdentities
            .AsNoTracking()
            .SingleAsync(candidate => candidate.Id == 1, cancellationToken);
        var isSetup = await database.Users.AnyAsync(cancellationToken);
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0";
        return Results.Ok(new ServerInfoResponse(
            identity.ServerId,
            runtime.ServerName,
            version,
            isSetup));
    }

    private static async Task<IResult> SetupOwnerAsync(
        HttpContext context,
        IWebHostEnvironment environment,
        SetupOwnerRequest request,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        if (!IsLoopback(context, environment))
        {
            return Problem(
                "local_setup_required",
                "The first owner can only be created from the server computer.",
                StatusCodes.Status403Forbidden);
        }

        return await ExecuteAsync(
            () => accounts.SetupOwnerAsync(request, cancellationToken));
    }

    private static Task<IResult> LoginAsync(
        LoginRequest request,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => accounts.LoginAsync(request, cancellationToken));
    }

    private static Task<IResult> RedeemPairingCodeAsync(
        RedeemPairingCodeRequest request,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => accounts.RedeemPairingCodeAsync(request, cancellationToken));
    }

    private static Task<IResult> CreatePairingCodeAsync(
        HttpContext context,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => accounts.CreatePairingCodeAsync(
            context.User.RequireUserId(),
            cancellationToken));
    }

    private static async Task<IResult> LogoutAsync(
        HttpContext context,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return await ExecuteNoContentAsync(() => accounts.RevokeSessionAsync(
            context.User.RequireUserId(),
            context.User.RequireSessionId(),
            context.User.RequireSessionId(),
            cancellationToken));
    }

    private static Task<IResult> ListSessionsAsync(
        HttpContext context,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => accounts.ListSessionsAsync(
            context.User.RequireUserId(),
            context.User.RequireSessionId(),
            cancellationToken));
    }

    private static async Task<IResult> RevokeSessionAsync(
        HttpContext context,
        Guid sessionId,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return await ExecuteNoContentAsync(() => accounts.RevokeSessionAsync(
            context.User.RequireUserId(),
            context.User.RequireSessionId(),
            sessionId,
            cancellationToken));
    }

    private static Task<IResult> ListUsersAsync(
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => accounts.ListUsersAsync(cancellationToken));
    }

    private static Task<IResult> CreateUserAsync(
        HttpContext context,
        CreateUserRequest request,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => accounts.CreateUserAsync(
            context.User.RequireUserId(),
            request,
            cancellationToken));
    }

    private static Task<IResult> ChangeUserRoleAsync(
        HttpContext context,
        Guid userId,
        ChangeUserRoleRequest request,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => accounts.ChangeRoleAsync(
            context.User.RequireUserId(),
            userId,
            request.Role,
            cancellationToken));
    }

    private static async Task<IResult> DeleteUserAsync(
        HttpContext context,
        Guid userId,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return await ExecuteNoContentAsync(() => accounts.DeleteUserAsync(
            context.User.RequireUserId(),
            userId,
            cancellationToken));
    }

    private static bool IsLoopback(HttpContext context, IWebHostEnvironment environment)
    {
        if (environment.IsEnvironment("Testing"))
        {
            return true;
        }

        var address = context.Connection.RemoteIpAddress;
        return address is not null && IPAddress.IsLoopback(address);
    }

    private static async Task<IResult> ExecuteAsync<T>(Func<Task<T>> action)
    {
        try
        {
            return Results.Ok(await action());
        }
        catch (AccountException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }

    private static async Task<IResult> ExecuteNoContentAsync(Func<Task> action)
    {
        try
        {
            await action();
            return Results.NoContent();
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
