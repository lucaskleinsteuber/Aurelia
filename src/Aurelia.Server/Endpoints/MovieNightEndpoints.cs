using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Endpoints;

/// <summary>
/// Movie Night. Every query here runs with the asking profile's own title filters, so the shelf
/// a member brings, and every card dealt from it, only holds titles that profile may open.
/// </summary>
public static class MovieNightEndpoints
{
    public static void MapMovieNight(this WebApplication app)
    {
        var nights = app.MapGroup("/api/v1/movie-night").RequireAuthorization();

        nights.MapGet(string.Empty, (MovieNightService service) => Results.Ok(service.List()));

        nights.MapPost(string.Empty, (HttpContext context, CreateMovieNightRequest request, MovieNightService service, AureliaDbContext database,
            CancellationToken token) => Run(async () =>
        {
            var person = await PersonAsync(database, context.User.RequireUserId(), token);
            var shelf = await ShelfAsync(database, token);
            return service.Create(context.User.RequireProfileSessionId(), person.Name, request.DeviceName, request.IsVoting, person.Gentle,
                shelf, await GenresAsync(database, shelf, token));
        }));

        nights.MapGet("/{nightId:guid}", (HttpContext context, Guid nightId, long? after, int? deckVersion, int? waitMs, MovieNightService service) =>
            Run(() => service.WaitAsync(nightId, context.User.RequireProfileSessionId(), after, deckVersion, waitMs ?? 0, context.RequestAborted)));

        nights.MapPost("/{nightId:guid}/join", (HttpContext context, Guid nightId, JoinMovieNightRequest request, MovieNightService service,
            AureliaDbContext database, CancellationToken token) => Run(async () =>
        {
            var person = await PersonAsync(database, context.User.RequireUserId(), token);
            return service.Join(nightId, context.User.RequireProfileSessionId(), person.Name, request.DeviceName, request.IsVoting, person.Gentle,
                await ShelfAsync(database, token));
        }));

        nights.MapPost("/{nightId:guid}/settings", (HttpContext context, Guid nightId, MovieNightSettingsRequest request, MovieNightService service) =>
            Run(() => Task.FromResult(service.Settings(nightId, context.User.RequireProfileSessionId(), request.Kinds, request.Genre))));

        // Starting and dealing again are the same: a fresh deck for everyone.
        nights.MapPost("/{nightId:guid}/deal", (HttpContext context, Guid nightId, MovieNightService service, AureliaDbContext database,
            PresentationService presentation, CancellationToken token) => Run(async () =>
        {
            var session = context.User.RequireProfileSessionId();
            var plan = service.Plan(nightId, session);
            var cards = await DealAsync(database, presentation, context.User.RequireUserId(), plan, token);
            return service.Deal(nightId, session, cards);
        }));

        nights.MapPost("/{nightId:guid}/votes", (HttpContext context, Guid nightId, MovieNightVoteRequest request, MovieNightService service) =>
            Run(() => Task.FromResult(service.Vote(nightId, context.User.RequireProfileSessionId(), request.MediaId, request.Like))));

        nights.MapPost("/{nightId:guid}/keep-swiping", (HttpContext context, Guid nightId, MovieNightService service) =>
            Run(() => Task.FromResult(service.KeepSwiping(nightId, context.User.RequireProfileSessionId()))));

        nights.MapPost("/{nightId:guid}/role", (HttpContext context, Guid nightId, MovieNightRoleRequest request, MovieNightService service) =>
            Run(() => Task.FromResult(service.Role(nightId, context.User.RequireProfileSessionId(), request.IsVoting))));

        nights.MapDelete("/{nightId:guid}/members/me", (HttpContext context, Guid nightId, MovieNightService service) =>
        {
            service.Leave(nightId, context.User.RequireProfileSessionId());
            return Results.NoContent();
        });
    }

    /// <summary>The films and shows this profile may open and play now.</summary>
    private static async Task<IReadOnlySet<Guid>> ShelfAsync(AureliaDbContext database, CancellationToken token) =>
        await database.MediaItems.AsNoTracking()
            .Where(item => item.ParentId == null && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Series)
                && item.Availability == MediaAvailability.Available)
            .Select(item => item.Id)
            .ToHashSetAsync(token);

    /// <summary>The genres on the shelf, most common first, for the host to choose from.</summary>
    private static async Task<IReadOnlyList<string>> GenresAsync(AureliaDbContext database, IReadOnlySet<Guid> shelf, CancellationToken token)
    {
        var ids = shelf.ToList();
        var lists = await database.MediaMetadata.AsNoTracking()
            .Where(metadata => ids.Contains(metadata.MediaItemId))
            .Select(metadata => metadata.ManualGenresJson ?? metadata.ProviderGenresJson)
            .ToListAsync(token);
        return lists.SelectMany(MetadataPresentation.ParseList)
            .Where(genre => !string.IsNullOrWhiteSpace(genre))
            .GroupBy(genre => genre.Trim(), StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(group => group.Count()).ThenBy(group => group.Key, StringComparer.OrdinalIgnoreCase)
            .Take(16)
            .Select(group => group.Key)
            .ToList();
    }

    /// <summary>
    /// Up to <see cref="MovieNightService.DeckSize"/> titles from the plan, in one shuffled order
    /// for everyone. Films the asking profile has already finished are left out.
    /// </summary>
    private static async Task<IReadOnlyList<MovieNightCard>> DealAsync(AureliaDbContext database, PresentationService presentation, Guid userId,
        MovieNightService.DealPlan plan, CancellationToken token)
    {
        var allowed = plan.Allowed.ToList();
        var shows = plan.Kinds == "all";
        var candidates = await database.MediaItems.AsNoTracking()
            .Where(item => allowed.Contains(item.Id)
                && (item.Kind == MediaKind.Movie || (shows && item.Kind == MediaKind.Series))
                && !item.PlaybackProgress.Any(progress => progress.UserId == userId && progress.IsCompleted))
            .Select(item => new { item.Id, Genres = item.Metadata == null ? null : item.Metadata.ManualGenresJson ?? item.Metadata.ProviderGenresJson })
            .ToListAsync(token);
        var picked = candidates
            .Where(candidate => plan.Genre is null || MetadataPresentation.ParseList(candidate.Genres)
                .Any(genre => string.Equals(genre.Trim(), plan.Genre, StringComparison.OrdinalIgnoreCase)))
            .Select(candidate => candidate.Id)
            .OrderBy(id => id)
            .ToArray();
        new Random(plan.Seed).Shuffle(picked);
        var ids = picked.Take(MovieNightService.DeckSize).ToList();
        if (ids.Count == 0) return [];

        var summaries = await presentation.SummariesAsync(userId, ids, token);
        var runtimes = (await database.MediaItems.AsNoTracking().Include(item => item.Metadata)
                .Where(item => ids.Contains(item.Id)).ToListAsync(token))
            .ToDictionary(item => item.Id, item => MetadataPresentation.ToSummary(item).RuntimeMinutes);
        return summaries.Select(summary => new MovieNightCard(summary.Id, summary.Kind, summary.Title, summary.Year, summary.Overview,
            summary.Genres, runtimes.GetValueOrDefault(summary.Id), summary.Poster, summary.Backdrop)).ToList();
    }

    private static async Task<(string Name, bool Gentle)> PersonAsync(AureliaDbContext database, Guid userId, CancellationToken token)
    {
        var person = await database.Users.AsNoTracking().Where(user => user.Id == userId)
            .Select(user => new { Name = user.DisplayName ?? user.Username, user.AgeLimit })
            .FirstOrDefaultAsync(token);
        return (person?.Name ?? "Someone", person?.AgeLimit is not null);
    }

    private static async Task<IResult> Run<T>(Func<Task<T>> action)
    {
        try
        {
            return Results.Ok(await action());
        }
        catch (PlaybackException exception)
        {
            return Results.Json(new ApiProblem(exception.Code, exception.Message), statusCode: exception.StatusCode);
        }
    }
}
