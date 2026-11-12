using Aurelia.Contracts;
using Aurelia.Server.Services;
using Aurelia.Server.Services.Speech;

namespace Aurelia.Server.Endpoints;

/// <summary>
/// Speech recognition on the server ("server-speech-v1", docs/CLIENT_PROTOCOL.md): the owner
/// downloads or removes the model; administrators start, follow and stop a title's job.
/// </summary>
public static class ServerSpeechEndpoints
{
    public static void MapServerSpeech(this WebApplication app)
    {
        var server = app.MapGroup("/api/v1/server/speech").RequireAuthorization("Owner");
        server.MapGet(string.Empty, (SpeechJobService jobs, SpeechModelStore models) => Results.Ok(Settings(jobs, models)));
        server.MapPost("/model", (DownloadSpeechModelRequest request, SpeechJobService jobs, SpeechModelStore models) =>
        {
            if (SpeechModelStore.Choices.All(choice => choice.Name != request.Name))
                return Results.Json(new ApiProblem("invalid_speech_model", "Choose base, small or medium."), statusCode: StatusCodes.Status400BadRequest);
            models.StartDownload(request.Name);
            return Results.Ok(Settings(jobs, models));
        });
        server.MapDelete("/model", (SpeechJobService jobs, SpeechModelStore models) =>
        {
            models.Remove();
            return Results.Ok(Settings(jobs, models));
        });

        var media = app.MapGroup("/api/v1/media/{mediaId:guid}/speech").RequireAuthorization("Administrator");
        media.MapGet(string.Empty, (Guid mediaId, SpeechJobService jobs) =>
            Results.Ok(new MediaSpeechResponse(jobs.Available, jobs.ModelReady, jobs.Status(mediaId))));
        media.MapPost(string.Empty, async (Guid mediaId, StartSpeechJobRequest request, SpeechJobService jobs, CancellationToken token) =>
        {
            try
            {
                return Results.Ok(new MediaSpeechResponse(jobs.Available, jobs.ModelReady, await jobs.StartAsync(mediaId, request, token)));
            }
            catch (MetadataException exception)
            {
                return Results.Json(new ApiProblem(exception.Code, exception.Message), statusCode: exception.StatusCode);
            }
        });
        media.MapDelete(string.Empty, (Guid mediaId, SpeechJobService jobs) =>
            jobs.Cancel(mediaId) ? Results.Ok(new MediaSpeechResponse(jobs.Available, jobs.ModelReady, jobs.Status(mediaId))) : Results.NotFound());
    }

    private static ServerSpeechSettings Settings(SpeechJobService jobs, SpeechModelStore models)
    {
        var current = models.Current;
        return new ServerSpeechSettings(jobs.Available, current?.Name, current?.Bytes ?? 0, models.Download, models.DownloadError,
            SpeechModelStore.Choices, jobs.Jobs);
    }
}
