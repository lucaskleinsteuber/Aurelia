using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Extensions.Primitives;
using Microsoft.Net.Http.Headers;

namespace Aurelia.Server.Endpoints;

/// <summary>Moving a whole server to another computer (docs/SERVER_MOVE.md).</summary>
public static class ServerMoveEndpoints
{
    public const string SetupCodeHeader = "X-Aurelia-Setup-Code";

    public static void MapServerMove(this WebApplication app)
    {
        // On the old server, as its owner; starting, marking and undoing need the Server Password
        // (ServerRequestGuard.RequiresApproval).
        var server = app.MapGroup("/api/v1/server/move").RequireAuthorization("Owner");
        server.MapGet("", (ServerMoveService moves) => moves.Status());
        server.MapPost("", (StartServerMoveRequest request, ServerMoveService moves, CancellationToken token) => moves.StartAsync(request, token));
        server.MapPost("/mark-moved", (ServerMoveService moves, CancellationToken token) => moves.MarkMovedAsync(token));
        server.MapDelete("", (ServerMoveService moves) => moves.Cancel());

        // Between the two servers: no session, over HTTPS, rate limited. The move code and the
        // bundle's move token are the only credentials.
        var between = app.MapGroup("/api/v1/move").RequireRateLimiting("move");
        between.MapGet("/hello", (ServerMoveService moves, HttpContext context) =>
        {
            RequireHttps(context);
            return moves.HelloAsync(context.RequestAborted);
        });
        between.MapPost("/claim", async (MoveClaimRequest request, ServerMoveService moves, HttpContext context) =>
        {
            RequireHttps(context);
            var (bundle, _) = await moves.ClaimAsync(request, context.RequestAborted);
            context.Response.Headers[HeaderNames.CacheControl] = "no-store";
            return Results.Stream(bundle, "application/octet-stream");
        });
        between.MapPost("/arrived", async (MoveArrivedRequest request, ServerMoveService moves, HttpContext context) =>
        {
            RequireHttps(context);
            await moves.ArrivedAsync(request, context.RequestAborted);
            return Results.NoContent();
        });

        // On the new server before it has an owner: the browser setup's code, or the authority an
        // app host already uses to set up its own server (loopback and its bootstrap token).
        var setup = app.MapGroup("/api/v1/setup/move").AddEndpointFilter(async (context, next) =>
        {
            await RequireSetupAsync(context.HttpContext);
            return await next(context);
        });
        setup.MapGet("", (ServerMoveImportService import) => import.Status());
        setup.MapPost("/network", (SetupMoveNetworkRequest request, ServerMoveImportService import, CancellationToken token) =>
            import.StartNetworkAsync(request, token)).RequireRateLimiting("authentication");
        setup.MapPut("/file", (HttpContext context, ServerMoveImportService import) =>
            import.UploadAsync(context.Request.Body, context.Request.ContentLength ?? 0, context.RequestAborted));
        setup.MapPost("/file/{uploadId:guid}/open", (Guid uploadId, SetupMoveOpenRequest request, ServerMoveImportService import, CancellationToken token) =>
            import.OpenFileAsync(uploadId, request.Passphrase, token)).RequireRateLimiting("authentication");
        setup.MapPost("/locations/preview", (SetupMovePreviewRequest request, ServerMoveImportService import) => import.Preview(request));
        setup.MapPost("/finish", (SetupMoveFinishRequest request, ServerMoveImportService import, CancellationToken token) =>
            import.FinishAsync(request, token));
        setup.MapDelete("", (ServerMoveImportService import) => import.Discard());

        // Storage Location Moved, any time, as the owner.
        var relocate = app.MapGroup("/api/v1/libraries/{libraryId:guid}/relocate").RequireAuthorization("Owner");
        relocate.MapGet("/suggestions", (Guid libraryId, LibraryRelocationService service, CancellationToken token) =>
            service.SuggestionsAsync(libraryId, token));
        relocate.MapPost("/preview", (Guid libraryId, LibraryRelocatePreviewRequest request, LibraryRelocationService service, CancellationToken token) =>
            service.PreviewAsync(libraryId, request, token));
        relocate.MapPost("", (Guid libraryId, LibraryRelocateRequest request, LibraryRelocationService service, CancellationToken token) =>
            service.RelocateAsync(libraryId, request, token));
    }

    /// <summary>
    /// Setup-time moves only reach a server without an owner, over HTTPS or on this computer, with
    /// the setup code (every wrong one counts, see <see cref="BrowserSetup"/>) or an app host's
    /// bootstrap token on loopback, the same proof <c>POST /api/v1/setup/owner</c> needs.
    /// </summary>
    private static async Task RequireSetupAsync(HttpContext context)
    {
        context.Response.Headers[HeaderNames.CacheControl] = "no-store";
        if (!context.Request.IsHttps && context.Connection.RemoteIpAddress is { } ip && !System.Net.IPAddress.IsLoopback(ip))
            throw new AccountException("https_required", "Setting up a server requires its HTTPS address.", 403);
        var services = context.RequestServices;
        if (!await BrowserSetup.OpenAsync(services.GetRequiredService<AureliaDbContext>(), context.RequestAborted))
            throw new AccountException("server_already_setup", "This server already has an owner, so it can't receive a move.", 409);
        var bootstrap = context.Request.Headers[BootstrapSetupAuthorizer.HeaderName];
        if (!StringValues.IsNullOrEmpty(bootstrap))
        {
            var testing = services.GetRequiredService<IWebHostEnvironment>().IsEnvironment("Testing");
            if (LocalRequestPolicy.IsAllowed(context.Connection.RemoteIpAddress, testing)
                && services.GetRequiredService<BootstrapSetupAuthorizer>().IsAuthorized(bootstrap))
                return;
            throw new AccountException("bootstrap_required", "Native setup authorization is required.", 403);
        }
        if (!services.GetRequiredService<BrowserSetup>().Matches(context.Request.Headers[SetupCodeHeader]))
            throw new AccountException("setup_code_invalid", "That setup code is not right. Check it on the server computer: sudo aurelia setup-code", 403);
    }

    private static void RequireHttps(HttpContext context)
    {
        if (!context.Request.IsHttps)
            throw new AccountException("https_required", "Servers move over HTTPS only.", 403);
    }
}

/// <summary>
/// A server that moved answers only what a device needs to find the new one, and what its owner
/// needs to undo the move: every other API call is a <c>409 server_moved</c> naming where it went.
/// </summary>
public static class ServerMoveGuard
{
    public sealed record ServerMovedProblem(string Code, string Message, ServerMoveTarget MovedTo);

    public static async Task InvokeAsync(HttpContext context, RequestDelegate next)
    {
        var path = context.Request.Path.Value ?? string.Empty;
        if (path.StartsWith("/api/", StringComparison.OrdinalIgnoreCase)
            && context.RequestServices.GetRequiredService<ServerMoveService>().MovedTo is { } target
            && !Allowed(context.Request.Method, path))
        {
            // Every device asks this until it switches; the diagnostics need not list each call.
            context.Items["Aurelia.FailureRecorded"] = true;
            context.Response.StatusCode = StatusCodes.Status409Conflict;
            context.Response.Headers[HeaderNames.CacheControl] = "no-store";
            await context.Response.WriteAsJsonAsync(new ServerMovedProblem("server_moved",
                $"This server moved to another computer (“{target.Name}”). Connect to its new address.", target));
            return;
        }
        await next(context);
    }

    /// <summary>The calls a moved server still answers.</summary>
    public static bool Allowed(string method, string path)
    {
        var value = path.TrimEnd('/').ToLowerInvariant();
        var segments = value.Split('/');
        bool Get() => HttpMethods.IsGet(method) || HttpMethods.IsHead(method);
        bool Post() => HttpMethods.IsPost(method);
        bool ProfileUnlock(int index) => segments.Length == index + 3 && segments[index] == "profiles"
            && Guid.TryParse(segments[index + 1], out _) && segments[index + 2] == "unlock";
        return value switch
        {
            "/api/v1/server/info" => Get(),
            "/api/v1/server/move" => Get() || HttpMethods.IsDelete(method),
            // A repeated or late arrival report only adds where the server went.
            "/api/v1/move/arrived" => Post(),
            // The owner's way to Undo Move: sign in, open the profile, unlock management, approve.
            "/api/v1/auth/login" or "/api/v1/management/unlock" or "/api/v1/management/approval" or "/api/v1/server/approval"
                or "/api/v1/profile/end" or "/api/v1/web/profile/end" => Post(),
            "/api/v1/profiles" => Get(),
            "/api/v1/device" => HttpMethods.IsDelete(method),
            _ => Post() && (value.StartsWith("/api/v1/profiles/", StringComparison.Ordinal) && ProfileUnlock(3)
                || value.StartsWith("/api/v1/web/profiles/", StringComparison.Ordinal) && ProfileUnlock(4)),
        };
    }
}
