using System.Net.Http.Headers;
using System.Reflection;
using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Authentication;
using Aurelia.Home.Server.Data;
using Aurelia.Home.Server.Services;
using Microsoft.EntityFrameworkCore;
using EntityTagHeaderValue = Microsoft.Net.Http.Headers.EntityTagHeaderValue;

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
        authentication.MapGet("/me", CurrentUserAsync)
            .RequireAuthorization();
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

        var libraries = api.MapGroup("/libraries").RequireAuthorization("Administrator");
        libraries.MapGet(string.Empty, ListLibrariesAsync);
        libraries.MapPost(string.Empty, CreateLibraryAsync);
        libraries.MapDelete("/{libraryId:guid}", RemoveLibraryAsync);
        libraries.MapPost("/{libraryId:guid}/scans", StartLibraryScanAsync);
        libraries.MapGet("/{libraryId:guid}/discoveries", ListLibraryDiscoveriesAsync);
        libraries.MapPut(
            "/{libraryId:guid}/classification-decisions",
            UpdateClassificationDecisionsAsync);
        libraries.MapDelete(
            "/{libraryId:guid}/classification-decisions/{discoveryId:guid}",
            ResetClassificationDecisionAsync);
        libraries.MapPost("/scans", StartAllLibraryScansAsync);

        var scans = api.MapGroup("/scans").RequireAuthorization("Administrator");
        scans.MapGet("/{scanId:guid}", GetLibraryScanAsync);

        var catalog = api.MapGroup("/catalog").RequireAuthorization();
        catalog.MapGet("/movies", ListMoviesAsync);
        catalog.MapGet("/movies/{movieId:guid}", GetMovieAsync);
        catalog.MapGet("/series", ListSeriesAsync);
        catalog.MapGet("/series/{seriesId:guid}", GetSeriesAsync);

        var media = api.MapGroup("/media").RequireAuthorization();
        media.MapPost("/{mediaId:guid}/playback", CreatePlaybackAsync);
        media.MapGet("/{mediaId:guid}/progress", GetPlaybackProgressAsync);
        media.MapPut("/{mediaId:guid}/progress", UpdatePlaybackProgressAsync);

        var playback = api.MapGroup("/playback").RequireAuthorization();
        playback.MapDelete("/{playbackId:guid}", RevokePlaybackAsync);

        api.MapMethods("/streams/{ticket}", [HttpMethods.Get, HttpMethods.Head], StreamAsync)
            .WithDisplayName("Stream media");
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
        ServerTlsIdentity tlsIdentity,
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
            isSetup,
            runtime.LanAccessEnabled,
            runtime.LanAccessEnabled ? runtime.LanHttpsPort : null,
            runtime.LanAccessEnabled ? tlsIdentity.PublicKeyFingerprint : null,
            runtime.LanAccessEnabled ? tlsIdentity.DisplayFingerprint : null));
    }

    private static async Task<IResult> SetupOwnerAsync(
        HttpContext context,
        IWebHostEnvironment environment,
        SetupOwnerRequest request,
        AccountService accounts,
        BootstrapSetupAuthorizer bootstrap,
        CancellationToken cancellationToken)
    {
        if (!IsLoopback(context, environment))
        {
            return Problem(
                "local_setup_required",
                "The first owner can only be created from the server computer.",
                StatusCodes.Status403Forbidden);
        }

        if (!bootstrap.IsAuthorized(context.Request.Headers[BootstrapSetupAuthorizer.HeaderName]))
        {
            return Problem(
                "bootstrap_required",
                "Native setup authorization is required.",
                StatusCodes.Status403Forbidden);
        }

        var result = await ExecuteAsync(
            () => accounts.SetupOwnerAsync(request, cancellationToken));
        if (result is IStatusCodeHttpResult { StatusCode: >= 200 and < 300 })
        {
            bootstrap.Consume();
        }

        return result;
    }

    private static Task<IResult> CurrentUserAsync(
        HttpContext context,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => accounts.GetUserAsync(
            context.User.RequireUserId(),
            cancellationToken));
    }

    private static Task<IResult> LoginAsync(
        HttpContext context,
        IWebHostEnvironment environment,
        LoginRequest request,
        AccountService accounts,
        CancellationToken cancellationToken)
    {
        if (!IsLoopback(context, environment))
        {
            return Task.FromResult(Problem(
                "local_login_required",
                "Password login is only available from the server computer. Use pairing on other devices.",
                StatusCodes.Status403Forbidden));
        }

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

    private static Task<IResult> ListLibrariesAsync(
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => libraries.ListAsync(cancellationToken));
    }

    private static async Task<IResult> CreateLibraryAsync(
        CreateLibraryRequest request,
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return await ExecuteResultAsync(async () =>
        {
            var library = await libraries.CreateAsync(request, cancellationToken);
            return Results.Created($"/api/v1/libraries/{library.Id}", library);
        });
    }

    private static Task<IResult> RemoveLibraryAsync(
        Guid libraryId,
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return ExecuteNoContentAsync(() => libraries.RemoveAsync(libraryId, cancellationToken));
    }

    private static Task<IResult> ListLibraryDiscoveriesAsync(
        Guid libraryId,
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => libraries.ListDiscoveriesAsync(libraryId, cancellationToken));
    }

    private static async Task<IResult> UpdateClassificationDecisionsAsync(
        Guid libraryId,
        UpdateClassificationDecisionsRequest request,
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return await ExecuteResultAsync(async () =>
        {
            var scan = await libraries.UpdateClassificationDecisionsAsync(
                libraryId,
                request,
                cancellationToken);
            return Results.Accepted($"/api/v1/scans/{scan.Id}", scan);
        });
    }

    private static async Task<IResult> ResetClassificationDecisionAsync(
        Guid libraryId,
        Guid discoveryId,
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return await ExecuteResultAsync(async () =>
        {
            var scan = await libraries.ResetClassificationDecisionAsync(
                libraryId,
                discoveryId,
                cancellationToken);
            return Results.Accepted($"/api/v1/scans/{scan.Id}", scan);
        });
    }

    private static async Task<IResult> StartLibraryScanAsync(
        Guid libraryId,
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return await ExecuteResultAsync(async () =>
        {
            var scan = await libraries.StartScanAsync(libraryId, cancellationToken);
            return Results.Accepted($"/api/v1/scans/{scan.Id}", scan);
        });
    }

    private static async Task<IResult> StartAllLibraryScansAsync(
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return await ExecuteResultAsync(async () =>
        {
            var scans = await libraries.StartAllScansAsync(cancellationToken);
            return Results.Accepted("/api/v1/scans", scans);
        });
    }

    private static Task<IResult> GetLibraryScanAsync(
        Guid scanId,
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => libraries.GetScanAsync(scanId, cancellationToken));
    }

    private static Task<IResult> ListMoviesAsync(
        int? offset,
        int? limit,
        CatalogService catalog,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => catalog.ListMoviesAsync(offset ?? 0, limit ?? 100, cancellationToken));
    }

    private static Task<IResult> GetMovieAsync(
        Guid movieId,
        CatalogService catalog,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => catalog.GetMovieAsync(movieId, cancellationToken));
    }

    private static Task<IResult> ListSeriesAsync(
        int? offset,
        int? limit,
        CatalogService catalog,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => catalog.ListSeriesAsync(offset ?? 0, limit ?? 100, cancellationToken));
    }

    private static Task<IResult> GetSeriesAsync(
        Guid seriesId,
        CatalogService catalog,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => catalog.GetSeriesAsync(seriesId, cancellationToken));
    }

    private static Task<IResult> CreatePlaybackAsync(
        HttpContext context,
        Guid mediaId,
        PlaybackService playback,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => playback.CreateAsync(
            context.User.RequireUserId(),
            context.User.RequireSessionId(),
            mediaId,
            cancellationToken));
    }

    private static Task<IResult> RevokePlaybackAsync(
        HttpContext context,
        Guid playbackId,
        PlaybackService playback,
        CancellationToken cancellationToken)
    {
        return ExecuteNoContentAsync(() => playback.RevokeAsync(
            context.User.RequireUserId(),
            playbackId,
            cancellationToken));
    }

    private static Task<IResult> GetPlaybackProgressAsync(
        HttpContext context,
        Guid mediaId,
        PlaybackProgressService progress,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => progress.GetAsync(
            context.User.RequireUserId(),
            mediaId,
            cancellationToken));
    }

    private static Task<IResult> UpdatePlaybackProgressAsync(
        HttpContext context,
        Guid mediaId,
        UpdatePlaybackProgressRequest request,
        PlaybackProgressService progress,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => progress.UpdateAsync(
            context.User.RequireUserId(),
            mediaId,
            request,
            cancellationToken));
    }

    private static async Task<IResult> StreamAsync(
        HttpContext context,
        string ticket,
        PlaybackService playback,
        CancellationToken cancellationToken)
    {
        var source = await playback.OpenStreamAsync(ticket, cancellationToken);
        if (source is null)
        {
            return Results.NotFound();
        }

        context.Response.Headers.CacheControl = "private, no-store";
        context.Response.Headers.XContentTypeOptions = "nosniff";
        if (context.Request.Headers.Range.Count > 0
            && (!RangeHeaderValue.TryParse(context.Request.Headers.Range.ToString(), out var range)
                || !string.Equals(range.Unit, "bytes", StringComparison.OrdinalIgnoreCase)
                || range.Ranges.Count != 1))
        {
            source.Stream.Dispose();
            context.Response.Headers.ContentRange = $"bytes */{source.ContentLength}";
            return Results.StatusCode(StatusCodes.Status416RangeNotSatisfiable);
        }

        var entityTag = new EntityTagHeaderValue(
            $"\"{source.ContentLength:x}-{source.LastModified.ToUnixTimeMilliseconds():x}\"");
        return Results.File(
            source.Stream,
            contentType: source.ContentType,
            fileDownloadName: null,
            lastModified: source.LastModified,
            entityTag: entityTag,
            enableRangeProcessing: true);
    }

    private static bool IsLoopback(HttpContext context, IWebHostEnvironment environment)
    {
        return LocalRequestPolicy.IsAllowed(
            context.Connection.RemoteIpAddress,
            environment.IsEnvironment("Testing"));
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
        catch (LibraryException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
        catch (PlaybackException exception)
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
        catch (LibraryException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
        catch (PlaybackException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }

    private static async Task<IResult> ExecuteResultAsync(Func<Task<IResult>> action)
    {
        try
        {
            return await action();
        }
        catch (LibraryException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
        catch (PlaybackException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }

    private static IResult Problem(string code, string message, int statusCode)
    {
        return Results.Json(new ApiProblem(code, message), statusCode: statusCode);
    }
}
