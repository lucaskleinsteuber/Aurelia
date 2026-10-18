using Aurelia.Contracts;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

public static class MediaSegmentEndpoints
{
    public static void MapMediaSegments(this WebApplication app)
    {
        var segments = app.MapGroup("/api/v1/media/{mediaId:guid}/segments").RequireAuthorization();
        segments.MapGet(string.Empty, (Guid mediaId, MediaSegmentService service, CancellationToken token) =>
            service.GetAsync(mediaId, token));
        segments.MapPut(string.Empty, (Guid mediaId, SetMediaSegmentsRequest request, MediaSegmentService service, CancellationToken token) =>
            service.SetAsync(mediaId, request, token)).RequireAuthorization("Administrator");
        segments.MapDelete(string.Empty, async (Guid mediaId, MediaSegmentService service, CancellationToken token) =>
        {
            await service.ClearAsync(mediaId, token);
            return Results.NoContent();
        }).RequireAuthorization("Administrator");
        app.MapGet("/api/v1/media/segment-analysis", (int? analysisVersion, int? limit, MediaSegmentService service, CancellationToken token) =>
            service.QueueAsync(analysisVersion ?? 1, limit ?? 10, token)).RequireAuthorization("Administrator");
    }
}
