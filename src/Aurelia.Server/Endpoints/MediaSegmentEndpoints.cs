using Aurelia.Contracts;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

/// <summary>Intro and credits times ("media-segments-v2", docs/CLIENT_PROTOCOL.md).</summary>
public static class MediaSegmentEndpoints
{
    public static void MapMediaSegments(this WebApplication app)
    {
        var media = app.MapGroup("/api/v1/media/{mediaId:guid}/segments").RequireAuthorization();
        media.MapGet(string.Empty, (Guid mediaId, MediaSegmentService service, CancellationToken token) => service.GetAsync(mediaId, token));
        // Corrections are library editing: an administrator's profile with management unlocked.
        media.MapPut(string.Empty, (Guid mediaId, SetMediaSegmentsRequest request, MediaSegmentService service, CancellationToken token) =>
            service.SetAsync(mediaId, request, token)).RequireAuthorization("Administrator");
        media.MapDelete(string.Empty, (Guid mediaId, MediaSegmentService service, CancellationToken token) =>
            service.ClearManualAsync(mediaId, token)).RequireAuthorization("Administrator");
        media.MapPost("/reanalyze", (Guid mediaId, MediaSegmentService service, CancellationToken token) =>
            service.ReanalyzeAsync(mediaId, token)).RequireAuthorization("Administrator");

        var server = app.MapGroup("/api/v1/server/media-segments").RequireAuthorization("Owner");
        server.MapGet(string.Empty, (SegmentDetectionService detection, CancellationToken token) => detection.ReadSettingsAsync(token));
        server.MapPut(string.Empty, (UpdateMediaSegmentSettingsRequest request, SegmentDetectionService detection, CancellationToken token) =>
            detection.UpdateSettingsAsync(request, token));
        server.MapGet("/series", (SegmentDetectionService detection, CancellationToken token) => detection.SeriesStatusAsync(token));
        server.MapPost("/reanalyze", (ReanalyzeMediaSegmentsRequest request, SegmentDetectionService detection, CancellationToken token) =>
            detection.ReanalyzeAsync(request.SeriesId, request.SeasonNumber, token, request.Movies));
    }
}
