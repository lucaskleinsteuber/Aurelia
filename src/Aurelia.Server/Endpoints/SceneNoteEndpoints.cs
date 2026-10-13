using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

public static class SceneNoteEndpoints
{
    public static void MapSceneNotes(this WebApplication app)
    {
        var notes = app.MapGroup("/api/v1/media/{mediaId:guid}/notes").RequireAuthorization();
        notes.MapGet(string.Empty, (HttpContext context, Guid mediaId, SceneNoteService service) =>
            service.ListAsync(context.User.RequireUserId(), mediaId, context.RequestAborted));
        notes.MapPut("/{noteId:guid}", (HttpContext context, Guid mediaId, Guid noteId, SaveSceneNoteRequest request, SceneNoteService service) =>
            service.SaveAsync(context.User.RequireUserId(), mediaId, noteId, request, context.RequestAborted));
        notes.MapDelete("/{noteId:guid}", async (HttpContext context, Guid mediaId, Guid noteId, long revision, SceneNoteService service) =>
        {
            await service.RemoveAsync(context.User.RequireUserId(), mediaId, noteId, revision, context.RequestAborted);
            return Results.NoContent();
        });
    }
}
