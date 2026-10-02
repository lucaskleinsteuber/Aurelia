using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Endpoints;

public static class MediaEditingEndpoints
{
    public static void MapMediaEditing(this WebApplication app)
    {
        var api = app.MapGroup("/api/v1").RequireAuthorization("Administrator");
        api.MapGet("/media/{id:guid}/editor", (Guid id, MediaEditorService editor, CancellationToken token) => editor.GetAsync(id, token));
        api.MapPut("/media/{id:guid}/editor", (Guid id, SaveMediaEditorRequest request, MediaEditorService editor, HttpContext context) =>
            editor.SaveAsync(id, context.User.RequireUserId(), context.User.RequireSessionId(), request, context.RequestAborted));
        api.MapGet("/media/{id:guid}/editor/files", (Guid id, string? path, MediaEditorService editor, CancellationToken token) => editor.FilesAsync(id, path, token));
        api.MapPost("/media/{id:guid}/editor/uploads", async (Guid id, MediaEditorService editor, EditorArtworkStore images, CatalogMutationGate mutations, HttpContext context) =>
        {
            using var lease = await mutations.EnterAsync(context.RequestAborted);
            _ = await editor.GetAsync(id, context.RequestAborted);
            return await images.UploadAsync(id, context.User.RequireUserId(), context.User.RequireSessionId(), context.Request.Body, context.RequestAborted);
        });
        api.MapGet("/media/{id:guid}/editor/uploads/{upload:guid}", async (Guid id, Guid upload, MediaEditorService editor, EditorArtworkStore images, HttpContext context) =>
        {
            _ = await editor.GetAsync(id, context.RequestAborted);
            return Image(context, images.DraftPath(upload, id, context.User.RequireUserId(), context.User.RequireSessionId()));
        });
        api.MapDelete("/media/{id:guid}/editor/uploads/{upload:guid}", async (Guid id, Guid upload, MediaEditorService editor, EditorArtworkStore images, HttpContext context) =>
        {
            _ = await editor.GetAsync(id, context.RequestAborted);
            images.Discard(upload, id, context.User.RequireUserId(), context.User.RequireSessionId());
            return Results.NoContent();
        });
        api.MapGet("/media/{id:guid}/editor/artwork/{asset:guid}", async (Guid id, Guid asset, MediaEditorService editor, EditorArtworkStore images, AureliaDbContext database, HttpContext context) =>
        {
            _ = await editor.GetAsync(id, context.RequestAborted);
            var image = await database.ArtworkAssets.SingleOrDefaultAsync(value => value.Id == asset && value.MediaItemId == id, context.RequestAborted)
                ?? throw new AccountException("artwork_not_found", "The image was not found.", 404);
            return Image(context, images.OriginalPath(image), image.ContentType);
        });
        api.MapDelete("/media/{id:guid}", (Guid id, LibraryMutationService service, HttpContext context) => service.RemoveAsync(context.User.RequireUserId(), id, context.RequestAborted));
        api.MapPost("/libraries/reset/preview", (Guid[] libraryIds, LibraryMutationService service, CancellationToken token) => service.PreviewAsync(libraryIds, token));
        api.MapPost("/libraries/reset", (ResetLibraryRequest request, LibraryMutationService service, HttpContext context) => service.ResetAsync(context.User.RequireUserId(), request, context.RequestAborted));
        api.MapPost("/libraries/reset/approval", async (AdministrationApprovalRequest request, AccountService accounts, AdministrationApprovalStore approvals, HttpContext context) =>
        {
            if (request.Action != "POST /api/v1/libraries/reset") throw new AccountException("invalid_approval_action", "This approval is only valid for a library reset.", 400);
            if (!context.Request.IsHttps && context.Connection.RemoteIpAddress is { } ip && !System.Net.IPAddress.IsLoopback(ip))
                throw new AccountException("https_required", "Password confirmation requires HTTPS.", 403);
            await accounts.ConfirmPasswordAsync(context.User.RequireUserId(), request.Password, context.RequestAborted);
            var result = approvals.Issue(context.User.RequireSessionId(), request.Action, request.PayloadHash);
            return new AdministrationApprovalResponse(result.Token, result.ExpiresAt);
        }).RequireRateLimiting("pairing");
        api.MapGet("/library-operations/{id:guid}", (Guid id, LibraryMutationService service, CancellationToken token) => service.StatusAsync(id, token));
        api.MapGet("/libraries/{id:guid}/exclusions", async (Guid id, AureliaDbContext database, CancellationToken token) =>
        {
            if (!await database.LibraryRoots.AnyAsync(root => root.Id == id, token)) throw new AccountException("library_not_found", "The storage location was not found.", 404);
            return await database.MediaExclusions.Where(value => value.LibraryRootId == id).OrderBy(value => value.RelativePath)
                .Select(value => new ExcludedMediaSummary(value.Id, id, value.RelativePath, value.IsDirectory)).ToArrayAsync(token);
        });
        api.MapDelete("/libraries/{id:guid}/exclusions/{excluded:guid}", async (Guid id, Guid excluded, AureliaDbContext database, CatalogMutationGate mutations, LibraryService libraries, CancellationToken token) =>
        {
            using (await mutations.EnterAsync(token))
            {
                var source = await database.MediaExclusions.SingleOrDefaultAsync(value => value.LibraryRootId == id && value.Id == excluded, token)
                    ?? throw new AccountException("exclusion_not_found", "The excluded source was not found.", 404);
                var root = await database.LibraryRoots.SingleAsync(value => value.Id == id, token);
                await using var transaction = await database.Database.BeginTransactionAsync(token);
                var prefix = source.NormalizedSourcePath.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                await database.MediaExclusions.Where(value => value.LibraryRootId == id
                    && (value.Id == excluded || source.IsDirectory && value.NormalizedSourcePath.StartsWith(prefix))).ExecuteDeleteAsync(token);
                root.ImportAssignmentRevision++;
                await database.SaveChangesAsync(token);
                await transaction.CommitAsync(token);
            }
            return await libraries.StartScanAsync(id, token);
        });
    }

    private static IResult Image(HttpContext context, string path, string type = "image/png")
    {
        context.Response.Headers.CacheControl = "private, no-store";
        context.Response.Headers.XContentTypeOptions = "nosniff";
        return Results.File(File.OpenRead(path), type);
    }
}
