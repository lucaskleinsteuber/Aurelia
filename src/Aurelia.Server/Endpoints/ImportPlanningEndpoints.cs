using Aurelia.Contracts;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

public static class ImportPlanningEndpoints
{
    public static void MapImportPlanning(this WebApplication app)
    {
        var group = app.MapGroup("/api/v1/libraries/{libraryId:guid}").RequireAuthorization("Administrator");
        group.MapGet("/import-assignments", (Guid libraryId, ImportPlanningService service, CancellationToken token) => service.AssignmentsAsync(libraryId, token));
        group.MapPost("/import-preview", (Guid libraryId, ImportPlanningService service, CancellationToken token) => service.AnalyzeAsync(libraryId, token));
        group.MapGet("/import-preview/{previewId:guid}/items", (Guid libraryId, Guid previewId, int? offset, int? limit, string? filter, ImportPlanningService service, CancellationToken token) =>
            service.PageAsync(libraryId, previewId, offset ?? 0, limit ?? 200, filter, token));
        group.MapPut("/import-preview/{previewId:guid}/assignments", (Guid libraryId, Guid previewId, ImportAssignmentsRequest request, ImportPlanningService service, CancellationToken token) =>
            service.UpdateAsync(libraryId, previewId, request, token));
        group.MapPost("/import-preview/{previewId:guid}/confirm", (Guid libraryId, Guid previewId, ConfirmImportPreviewRequest request, ImportPlanningService service, CancellationToken token) =>
            service.ConfirmAsync(libraryId, previewId, request, token));
    }
}
