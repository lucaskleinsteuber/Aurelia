using System.Net.Http.Headers;
using System.Reflection;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using EntityTagHeaderValue = Microsoft.Net.Http.Headers.EntityTagHeaderValue;

namespace Aurelia.Server.Endpoints;

public static class ApiEndpointMappings
{
    public static void MapAureliaApi(this WebApplication app)
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
        libraries.MapPut("/{libraryId:guid}/monitoring", UpdateLibraryMonitoringAsync);
        libraries.MapPost("/{libraryId:guid}/scans", StartLibraryScanAsync);
        libraries.MapGet("/{libraryId:guid}/scans", ListLibraryScansAsync);
        libraries.MapGet("/{libraryId:guid}/discoveries", ListLibraryDiscoveriesAsync);
        libraries.MapPut(
            "/{libraryId:guid}/classification-decisions",
            UpdateClassificationDecisionsAsync);
        libraries.MapDelete(
            "/{libraryId:guid}/classification-decisions/{discoveryId:guid}",
            ResetClassificationDecisionAsync);
        libraries.MapPost("/scans", StartAllLibraryScansAsync);
        libraries.MapGet("/scans", ListActiveLibraryScansAsync);

        var scans = api.MapGroup("/scans").RequireAuthorization("Administrator");
        scans.MapGet("/{scanId:guid}", GetLibraryScanAsync);
        scans.MapDelete("/{scanId:guid}", CancelLibraryScanAsync);

        var catalog = api.MapGroup("/catalog").RequireAuthorization();
        catalog.MapGet("/movies", ListMoviesAsync);
        catalog.MapGet("/movies/{movieId:guid}", GetMovieAsync);
        catalog.MapGet("/series", ListSeriesAsync);
        catalog.MapGet("/series/{seriesId:guid}", GetSeriesAsync);
        catalog.MapGet("/items", ListCatalogItemsAsync);
        catalog.MapGet("/items/{mediaId:guid}", GetCatalogDetailAsync);
        catalog.MapGet("/search", SearchCatalogAsync);
        catalog.MapPost("/search/rebuild", RebuildCatalogSearchAsync)
            .RequireAuthorization("Administrator");
        catalog.MapGet("/collections", ListCollectionsAsync);

        var collections = api.MapGroup("/collections").RequireAuthorization("Administrator");
        collections.MapPost(string.Empty, CreateCollectionAsync);
        collections.MapPut("/{collectionId:guid}", UpdateCollectionAsync);
        collections.MapDelete("/{collectionId:guid}", DeleteCollectionAsync);

        api.MapGet("/home", GetHomeAsync).RequireAuthorization();

        var metadata = api.MapGroup("/metadata").RequireAuthorization("Administrator");
        metadata.MapGet("/provider", GetMetadataProviderAsync);
        metadata.MapPut("/provider", UpdateMetadataProviderAsync);
        metadata.MapDelete("/provider/token", RemoveMetadataProviderTokenAsync);
        metadata.MapPost("/jobs", StartMetadataJobAsync);
        metadata.MapGet("/jobs", ListMetadataJobsAsync);
        metadata.MapGet("/jobs/{jobId:guid}", GetMetadataJobAsync);
        metadata.MapDelete("/jobs/{jobId:guid}", CancelMetadataJobAsync);
        metadata.MapGet("/reviews", ListMetadataReviewsAsync);
        metadata.MapPost("/artwork/prune", PruneArtworkAsync);

        var media = api.MapGroup("/media").RequireAuthorization();
        media.MapPost("/{mediaId:guid}/playback", CreatePlaybackAsync);
        media.MapGet("/{mediaId:guid}/progress", GetPlaybackProgressAsync);
        media.MapPut("/{mediaId:guid}/progress", UpdatePlaybackProgressAsync);
        media.MapGet("/{mediaId:guid}/metadata", GetMediaMetadataAsync);
        media.MapPut("/{mediaId:guid}/metadata", UpdateMediaMetadataAsync)
            .RequireAuthorization("Administrator");
        media.MapDelete("/{mediaId:guid}/metadata/match", ClearMetadataMatchAsync)
            .RequireAuthorization("Administrator");
        media.MapGet("/{mediaId:guid}/metadata/search", SearchMetadataAsync)
            .RequireAuthorization("Administrator");
        media.MapPut("/{mediaId:guid}/metadata/match", SelectMetadataMatchAsync)
            .RequireAuthorization("Administrator");
        media.MapPut("/{mediaId:guid}/favorite", SetFavoriteAsync);

        var playback = api.MapGroup("/playback").RequireAuthorization();
        playback.MapDelete("/{playbackId:guid}", RevokePlaybackAsync);

        api.MapMethods("/streams/{ticket}", [HttpMethods.Get, HttpMethods.Head], StreamAsync)
            .WithDisplayName("Stream media");
        api.MapMethods("/artwork/{artworkId:guid}", [HttpMethods.Get, HttpMethods.Head], ArtworkAsync)
            .RequireAuthorization()
            .WithDisplayName("Artwork");
        api.MapGet("/sync/changes", GetSyncChangesAsync).RequireAuthorization();
    }

    private static async Task<IResult> HealthAsync(
        AureliaDbContext database,
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
        AureliaDbContext database,
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

    private static Task<IResult> UpdateLibraryMonitoringAsync(
        Guid libraryId,
        UpdateLibraryMonitoringRequest request,
        LibraryService libraries,
        CancellationToken cancellationToken) =>
        ExecuteAsync(() => libraries.SetMonitoringAsync(libraryId, request.Enabled, cancellationToken));

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

    private static Task<IResult> ListActiveLibraryScansAsync(
        int? limit,
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => libraries.ListScansAsync(
            libraryId: null,
            activeOnly: true,
            limit ?? 100,
            cancellationToken));
    }

    private static Task<IResult> ListLibraryScansAsync(
        Guid libraryId,
        int? limit,
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => libraries.ListScansAsync(
            libraryId,
            activeOnly: false,
            limit ?? 10,
            cancellationToken));
    }

    private static Task<IResult> GetLibraryScanAsync(
        Guid scanId,
        LibraryService libraries,
        CancellationToken cancellationToken)
    {
        return ExecuteAsync(() => libraries.GetScanAsync(scanId, cancellationToken));
    }

    private static Task<IResult> CancelLibraryScanAsync(
        Guid scanId,
        LibraryService libraries,
        CancellationToken cancellationToken) =>
        ExecuteNoContentAsync(() => libraries.CancelScanAsync(scanId, cancellationToken));

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

    private static Task<IResult> SearchCatalogAsync(
        HttpContext context, string? query, string? kind, Guid? libraryId, string? genre,
        string? availability, bool? favorite, string? watchState, int? yearFrom, int? yearTo,
        string? sort, string? direction, int? offset, int? limit,
        PresentationService presentation, SyncChangeService changes, CancellationToken cancellationToken) =>
        ExecuteRevisionedAsync(context, changes, () => presentation.SearchAsync(
            context.User.RequireUserId(), query ?? string.Empty,
            ParseCatalogQuery(kind, libraryId, genre, availability, favorite, watchState,
                yearFrom, yearTo, sort, direction, offset, limit),
            cancellationToken));

    private static Task<IResult> ListCatalogItemsAsync(
        HttpContext context, string? kind, Guid? libraryId, string? genre,
        string? availability, bool? favorite, string? watchState, int? yearFrom, int? yearTo,
        string? sort, string? direction, int? offset, int? limit,
        PresentationService presentation, SyncChangeService changes, CancellationToken cancellationToken) =>
        ExecuteRevisionedAsync(context, changes, () => presentation.CatalogAsync(
            context.User.RequireUserId(),
            ParseCatalogQuery(kind, libraryId, genre, availability, favorite, watchState,
                yearFrom, yearTo, sort, direction, offset, limit),
            cancellationToken));

    private static Task<IResult> GetCatalogDetailAsync(HttpContext context, Guid mediaId, PresentationService presentation, SyncChangeService changes, CancellationToken cancellationToken) =>
        ExecuteRevisionedAsync(context, changes, () => presentation.DetailAsync(context.User.RequireUserId(), mediaId, cancellationToken));

    private static async Task<IResult> RebuildCatalogSearchAsync(
        MediaSearchIndexService searchIndex,
        CancellationToken cancellationToken)
    {
        await searchIndex.RebuildAsync(cancellationToken);
        return Results.NoContent();
    }

    private static Task<IResult> ListCollectionsAsync(HttpContext context, int? offset, int? limit, PresentationService presentation, CancellationToken cancellationToken) =>
        ExecuteAsync(() => presentation.CollectionsAsync(context.User.RequireUserId(), offset ?? 0, limit ?? 100, cancellationToken));

    private static Task<IResult> GetHomeAsync(HttpContext context, PresentationService presentation, SyncChangeService changes, CancellationToken cancellationToken) =>
        ExecuteRevisionedAsync(context, changes, () => presentation.HomeAsync(context.User.RequireUserId(), cancellationToken));

    private static Task<IResult> CreateCollectionAsync(HttpContext context, SaveCollectionRequest request, PresentationService presentation, CancellationToken cancellationToken) =>
        ExecuteAsync(() => presentation.CreateCollectionAsync(context.User.RequireUserId(), request, cancellationToken));

    private static Task<IResult> UpdateCollectionAsync(HttpContext context, Guid collectionId, SaveCollectionRequest request, PresentationService presentation, CancellationToken cancellationToken) =>
        ExecuteAsync(() => presentation.UpdateCollectionAsync(context.User.RequireUserId(), collectionId, request, cancellationToken));

    private static Task<IResult> DeleteCollectionAsync(Guid collectionId, PresentationService presentation, CancellationToken cancellationToken) =>
        ExecuteNoContentAsync(() => presentation.DeleteCollectionAsync(collectionId, cancellationToken));

    private static Task<IResult> GetMetadataProviderAsync(MetadataService metadata, CancellationToken cancellationToken) =>
        ExecuteAsync(() => metadata.GetStatusAsync(cancellationToken));

    private static Task<IResult> UpdateMetadataProviderAsync(UpdateMetadataProviderRequest request, MetadataService metadata, CancellationToken cancellationToken) =>
        ExecuteAsync(() => metadata.ConfigureAsync(request, cancellationToken));

    private static Task<IResult> RemoveMetadataProviderTokenAsync(MetadataService metadata, CancellationToken cancellationToken) =>
        ExecuteAsync(() => metadata.RemoveTokenAsync(cancellationToken));

    private static async Task<IResult> StartMetadataJobAsync(HttpContext context, Guid? libraryId, Guid? mediaId, MetadataService metadata, CancellationToken cancellationToken) =>
        await ExecuteResultAsync(async () =>
        {
            var hasBody = context.Request.ContentLength is > 0
                || context.Request.Headers.TransferEncoding.Count > 0;
            var job = hasBody
                ? await metadata.StartAsync(
                    await context.Request.ReadFromJsonAsync<StartMetadataJobRequest>(cancellationToken)
                        ?? throw new MetadataException("invalid_metadata_job", "The metadata job request is invalid.", StatusCodes.Status400BadRequest),
                    cancellationToken)
                : await metadata.StartAsync(libraryId, mediaId, cancellationToken);
            return Results.Accepted($"/api/v1/metadata/jobs/{job.Id}", job);
        });

    private static Task<IResult> ListMetadataJobsAsync(
        bool? activeOnly,
        int? limit,
        MetadataService metadata,
        CancellationToken cancellationToken) =>
        ExecuteAsync(() => metadata.ListJobsAsync(activeOnly ?? false, limit ?? 25, cancellationToken));

    private static Task<IResult> GetMetadataJobAsync(Guid jobId, MetadataService metadata, CancellationToken cancellationToken) =>
        ExecuteAsync(() => metadata.GetJobAsync(jobId, cancellationToken));

    private static Task<IResult> CancelMetadataJobAsync(
        Guid jobId,
        MetadataService metadata,
        CancellationToken cancellationToken) =>
        ExecuteNoContentAsync(() => metadata.CancelJobAsync(jobId, cancellationToken));

    private static Task<IResult> GetSyncChangesAsync(
        HttpContext context,
        long? after,
        int? waitSeconds,
        SyncChangeService changes,
        CancellationToken cancellationToken) =>
        ExecuteAsync(() => changes.ChangesAsync(
            context.User.RequireUserId(),
            context.User.IsInRole(UserRole.Owner.ToString()) || context.User.IsInRole(UserRole.Admin.ToString()),
            after ?? 0,
            waitSeconds ?? 0,
            cancellationToken));

    private static Task<IResult> ListMetadataReviewsAsync(MetadataService metadata, CancellationToken cancellationToken) =>
        ExecuteAsync(() => metadata.ReviewsAsync(cancellationToken));

    private static async Task<IResult> PruneArtworkAsync(ArtworkStore artwork, AureliaDbContext database, CancellationToken cancellationToken) =>
        Results.Ok(new { Removed = await artwork.PruneOrphansAsync(database, cancellationToken) });

    private static async Task<IResult> GetMediaMetadataAsync(Guid mediaId, AureliaDbContext database, CancellationToken cancellationToken)
    {
        var item = await database.MediaItems.AsNoTracking()
            .Include(media => media.Metadata)!.ThenInclude(metadata => metadata!.Credits)
            .Include(media => media.Metadata)!.ThenInclude(metadata => metadata!.Artwork)
            .SingleOrDefaultAsync(media => media.Id == mediaId, cancellationToken);
        return item is null ? Problem("media_not_found", "The media item was not found.", StatusCodes.Status404NotFound) : Results.Ok(MetadataPresentation.ToSummary(item));
    }

    private static Task<IResult> UpdateMediaMetadataAsync(Guid mediaId, UpdateMediaMetadataRequest request, MetadataService metadata, CancellationToken cancellationToken) =>
        ExecuteAsync(() => metadata.UpdateAsync(mediaId, request, cancellationToken));

    private static Task<IResult> ClearMetadataMatchAsync(Guid mediaId, MetadataService metadata, CancellationToken cancellationToken) =>
        ExecuteAsync(() => metadata.ClearMatchAsync(mediaId, cancellationToken));

    private static Task<IResult> SearchMetadataAsync(Guid mediaId, string? query, MetadataService metadata, CancellationToken cancellationToken) =>
        ExecuteAsync(() => metadata.SearchAsync(mediaId, query, cancellationToken));

    private static Task<IResult> SelectMetadataMatchAsync(Guid mediaId, SelectMetadataMatchRequest request, MetadataService metadata, CancellationToken cancellationToken) =>
        ExecuteAsync(() => metadata.SelectAsync(mediaId, request, cancellationToken));

    private static Task<IResult> SetFavoriteAsync(HttpContext context, Guid mediaId, SetFavoriteRequest request, PresentationService presentation, CancellationToken cancellationToken) =>
        ExecuteAsync(() => presentation.SetFavoriteAsync(context.User.RequireUserId(), mediaId, request.IsFavorite, cancellationToken));

    private static MediaKind? ParseCatalogKind(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (Enum.TryParse<MediaKind>(value, ignoreCase: true, out var kind)) return kind;
        throw new MetadataException(
            "invalid_catalog_kind",
            "Catalog kind must be movie or series.",
            StatusCodes.Status400BadRequest);
    }

    private static CatalogQuery ParseCatalogQuery(
        string? kind,
        Guid? libraryId,
        string? genre,
        string? availability,
        bool? favorite,
        string? watchState,
        int? yearFrom,
        int? yearTo,
        string? sort,
        string? direction,
        int? offset,
        int? limit) => new(
            ParseCatalogKind(kind),
            libraryId,
            genre,
            ParseOptionalEnum<MediaAvailability>(availability, "invalid_availability", "Availability is not valid."),
            favorite,
            ParseOptionalEnum<CatalogWatchState>(watchState, "invalid_watch_state", "Watch state is not valid."),
            yearFrom,
            yearTo,
            ParseOptionalEnum<CatalogSort>(sort, "invalid_sort", "Sort is not valid.") ?? CatalogSort.Title,
            ParseOptionalEnum<SortDirection>(direction, "invalid_direction", "Direction is not valid.") ?? SortDirection.Ascending,
            offset ?? 0,
            limit ?? 100);

    private static T? ParseOptionalEnum<T>(string? value, string code, string message)
        where T : struct, Enum
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (Enum.TryParse<T>(value, ignoreCase: true, out var parsed) && Enum.IsDefined(parsed)) return parsed;
        throw new MetadataException(code, message, StatusCodes.Status400BadRequest);
    }

    private static async Task<IResult> ArtworkAsync(HttpContext context, Guid artworkId, ArtworkStore artwork, AureliaDbContext database, CancellationToken cancellationToken)
    {
        var source = await artwork.OpenAsync(artworkId, database, cancellationToken);
        if (source is null) return Results.NotFound();
        context.Response.Headers.CacheControl = "private, max-age=86400";
        context.Response.Headers.XContentTypeOptions = "nosniff";
        return Results.File(source.Stream, source.ContentType, lastModified: source.LastModified,
            entityTag: new EntityTagHeaderValue($"\"{artworkId:N}-{source.ContentLength:x}\""));
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

    private static Task<IResult> ExecuteRevisionedAsync<T>(
        HttpContext context,
        SyncChangeService changes,
        Func<Task<T>> action) =>
        ExecuteResultAsync(async () =>
        {
            var userId = context.User.RequireUserId();
            var isAdministrator = context.User.IsInRole(UserRole.Owner.ToString())
                || context.User.IsInRole(UserRole.Admin.ToString());
            var cursor = await changes.CurrentCursorAsync(
                userId,
                isAdministrator,
                context.RequestAborted);
            var tag = $"\"revision-{cursor}\"";
            context.Response.Headers.ETag = tag;
            var matches = context.Request.Headers.IfNoneMatch.ToString()
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Any(value => value == "*" || string.Equals(value, tag, StringComparison.Ordinal));
            return matches
                ? Results.StatusCode(StatusCodes.Status304NotModified)
                : Results.Ok(await action());
        });

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
        catch (MetadataException exception)
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
        catch (MetadataException exception)
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
        catch (MetadataException exception)
        {
            return Problem(exception.Code, exception.Message, exception.StatusCode);
        }
    }

    private static IResult Problem(string code, string message, int statusCode)
    {
        return Results.Json(new ApiProblem(code, message), statusCode: statusCode);
    }
}
