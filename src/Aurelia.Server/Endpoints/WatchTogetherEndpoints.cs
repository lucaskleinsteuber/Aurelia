using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Endpoints;

/// <summary>
/// Watch Together. Any profile that may play a title can start or join a party for it; the
/// party only holds titles its members' profiles can open, and a member whose profile cannot
/// open a newly chosen title leaves the party.
/// </summary>
public static class WatchTogetherEndpoints
{
    public static void MapWatchTogether(this WebApplication app)
    {
        var parties = app.MapGroup("/api/v1/watch-together").RequireAuthorization();

        parties.MapGet(string.Empty, async (Guid? mediaId, WatchTogetherService service, AureliaDbContext database, CancellationToken token) =>
        {
            var ids = service.MediaIds();
            var visible = await database.MediaItems.AsNoTracking().Where(item => ids.Contains(item.Id)).Select(item => item.Id).ToHashSetAsync(token);
            return Results.Ok(service.List(visible.Contains, mediaId));
        });

        parties.MapPost(string.Empty, (HttpContext context, CreateWatchPartyRequest request, WatchTogetherService service, AureliaDbContext database,
            PresentationService presentation, CancellationToken token) => Run(async () =>
        {
            var userId = context.User.RequireUserId();
            var title = await TitleAsync(database, presentation, userId, request.MediaId, token);
            return service.Create(context.User.RequireProfileSessionId(), await NameAsync(database, userId, token), request.DeviceName,
                request.MediaId, title, request.PositionMilliseconds, request.IsPlaying);
        }));

        parties.MapGet("/{partyId:guid}", (HttpContext context, Guid partyId, long? after, int? waitMs, WatchTogetherService service, AureliaDbContext database) =>
            Run(async () => await VisibleAsync(context, service, database,
                await service.WaitAsync(partyId, context.User.RequireProfileSessionId(), after, waitMs ?? 0, context.RequestAborted))));

        parties.MapPost("/{partyId:guid}/join", (HttpContext context, Guid partyId, JoinWatchPartyRequest request, WatchTogetherService service,
            AureliaDbContext database, CancellationToken token) => Run(async () =>
        {
            var media = service.MediaOf(partyId) ?? throw new PlaybackException("party_not_found", "This Watch Together party has ended.", StatusCodes.Status404NotFound);
            var allowed = await database.MediaItems.AsNoTracking().AnyAsync(item => item.Id == media, token);
            var userId = context.User.RequireUserId();
            return service.Join(partyId, context.User.RequireProfileSessionId(), await NameAsync(database, userId, token), request.DeviceName, _ => allowed);
        }));

        parties.MapPost("/{partyId:guid}/commands", (HttpContext context, Guid partyId, WatchPartyCommandRequest request, WatchTogetherService service,
            AureliaDbContext database, PresentationService presentation, CancellationToken token) => Run(async () =>
        {
            string? title = null;
            if (request.MediaId is { } media && string.Equals(request.Action?.Trim(), "change", StringComparison.OrdinalIgnoreCase))
                title = await TitleAsync(database, presentation, context.User.RequireUserId(), media, token);
            return await VisibleAsync(context, service, database, service.Command(partyId, context.User.RequireProfileSessionId(), request, title));
        }));

        parties.MapDelete("/{partyId:guid}/members/me", (HttpContext context, Guid partyId, WatchTogetherService service) =>
        {
            service.Leave(partyId, context.User.RequireProfileSessionId());
            return Results.NoContent();
        });
    }

    /// <summary>"Breaking Point · S1 E2" for an episode, the title otherwise; only titles the profile may open.</summary>
    private static async Task<string> TitleAsync(AureliaDbContext database, PresentationService presentation, Guid userId, Guid mediaId, CancellationToken token)
    {
        if (!await database.MediaItems.AsNoTracking().AnyAsync(item => item.Id == mediaId && (item.Kind == MediaKind.Movie || item.Kind == MediaKind.Episode
                || item.Kind == MediaKind.Extra || item.Kind == MediaKind.Trailer), token))
            throw new PlaybackException("media_not_found", "The title was not found.", StatusCodes.Status404NotFound);
        var summary = await presentation.SummaryAsync(userId, mediaId, token);
        return summary.Kind == MediaKind.Episode && summary.ParentTitle is { } series
            ? $"{series} · S{summary.SeasonNumber} E{summary.EpisodeNumber}"
            : summary.Title;
    }

    /// <summary>
    /// Another member may change the party to a title this profile cannot open. The profile then
    /// leaves the party and learns neither the title nor its id.
    /// </summary>
    private static async Task<WatchPartyState> VisibleAsync(HttpContext context, WatchTogetherService service, AureliaDbContext database, WatchPartyState state)
    {
        if (await database.MediaItems.AsNoTracking().AnyAsync(item => item.Id == state.MediaId, context.RequestAborted)) return state;
        service.Leave(state.Id, context.User.RequireProfileSessionId());
        throw new PlaybackException("party_title_unavailable", "The party changed to a title this profile cannot open.", StatusCodes.Status404NotFound);
    }

    private static async Task<string> NameAsync(AureliaDbContext database, Guid userId, CancellationToken token) =>
        await database.Users.AsNoTracking().Where(user => user.Id == userId).Select(user => user.Username).FirstOrDefaultAsync(token) ?? "Someone";

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
