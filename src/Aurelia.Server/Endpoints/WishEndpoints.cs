using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Net.Http.Headers;

namespace Aurelia.Server.Endpoints;

/// <summary>Family wishlist endpoints under <c>/api/v1/wishes</c>.</summary>
public static class WishEndpoints
{
    public static void MapWishes(this WebApplication app)
    {
        var wishes = app.MapGroup("/api/v1/wishes").RequireAuthorization();

        wishes.MapGet(string.Empty, (HttpContext context, string? state, WishService service, CancellationToken cancellationToken) =>
            RunAsync(() => service.ListAsync(context.User.RequireUserId(), ParseWishState(state), cancellationToken)));

        wishes.MapGet("/summary", (HttpContext context, WishService service, CancellationToken cancellationToken) =>
            RunAsync(() => service.GetSummaryAsync(context.User.RequireUserId(), cancellationToken)));

        wishes.MapGet("/search", (HttpContext context, string? query, string? kind, WishService service, CancellationToken cancellationToken) =>
            RunAsync(() => service.SearchAsync(context.User.RequireUserId(), query, ParseWishKind(kind), cancellationToken)));

        wishes.MapPost(string.Empty, (HttpContext context, CreateWishRequest request, WishService service, CancellationToken cancellationToken) =>
            RunAsync(async () =>
            {
                var created = await service.CreateAsync(context.User.RequireUserId(), request, cancellationToken);
                return created.MergedIntoExistingSupport
                    ? Results.Ok(created)
                    : Results.Created($"/api/v1/wishes/{created.Wish.Id}", created);
            }));

        wishes.MapDelete("/{id:guid}", (HttpContext context, Guid id, WishService service, CancellationToken cancellationToken) =>
            RunAsync(async () =>
            {
                await service.DeleteAsync(context.User.RequireUserId(), id, cancellationToken);
                return Results.NoContent();
            }));

        wishes.MapPut("/{id:guid}/support", (HttpContext context, Guid id, SetWishSupportRequest request, WishService service, CancellationToken cancellationToken) =>
            RunAsync(() => service.SetSupportAsync(context.User.RequireUserId(), id, request.Supported, cancellationToken)));

        wishes.MapPut("/{id:guid}/state", (HttpContext context, Guid id, UpdateWishStateRequest request, WishService service, CancellationToken cancellationToken) =>
            RunAsync(() => service.UpdateStateAsync(context.User.RequireUserId(), id, request, cancellationToken)))
            .RequireAuthorization("Administrator");

        wishes.MapPost("/seen", (HttpContext context, WishService service, CancellationToken cancellationToken) =>
            RunAsync(async () =>
            {
                await service.MarkSeenAsync(context.User.RequireUserId(), cancellationToken);
                return Results.NoContent();
            }));

        wishes.MapGet("/poster", async (HttpContext context, string? path, int? width, WishPosterCache cache, AureliaDbContext database, CancellationToken cancellationToken) =>
        {
            var file = await cache.OpenAsync(path, width, database, cancellationToken);
            if (file is null)
                return Results.NotFound();

            context.Response.Headers.CacheControl = "private, max-age=86400";
            return Results.File(
                file.Stream,
                contentType: file.ContentType,
                lastModified: file.LastModified,
                // Stable for a poster and size; the cache touches files as it uses them.
                entityTag: new EntityTagHeaderValue($"\"{Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes($"{WishPosterCache.NormalizeSize(width)}:{path}")))[..24]}-{file.ContentLength}\""),
                enableRangeProcessing: false);
        });
    }

    private static Task<IResult> RunAsync<T>(Func<Task<T>> action) =>
        RunAsync(async () => Results.Ok(await action()));

    private static async Task<IResult> RunAsync(Func<Task<IResult>> action)
    {
        try
        {
            return await action();
        }
        catch (WishAlreadyInLibraryException conflict)
        {
            return Results.Json(
                new WishAlreadyInLibraryProblem("already_in_library", conflict.Message, conflict.MediaId, conflict.Title, conflict.Kind),
                statusCode: StatusCodes.Status409Conflict);
        }
        catch (AccountException exception)
        {
            return Results.Json(new ApiProblem(exception.Code, exception.Message), statusCode: exception.StatusCode);
        }
    }

    private static WishState? ParseWishState(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (Enum.TryParse<WishState>(value.Trim(), ignoreCase: true, out var state)) return state;
        throw new AccountException("invalid_wish_state", "State must be open, fulfilled or declined.", StatusCodes.Status400BadRequest);
    }

    private static MediaKind ParseWishKind(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return MediaKind.Movie;
        var trimmed = value.Trim();
        if (string.Equals(trimmed, "tv", StringComparison.OrdinalIgnoreCase)) return MediaKind.Series;
        if (Enum.TryParse<MediaKind>(trimmed, ignoreCase: true, out var kind) && kind is MediaKind.Movie or MediaKind.Series)
            return kind;
        throw new AccountException("invalid_wish_kind", "Choose movie or series.", StatusCodes.Status400BadRequest);
    }
}
