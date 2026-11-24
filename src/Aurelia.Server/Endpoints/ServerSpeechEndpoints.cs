using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Aurelia.Server.Services.Speech;
using Microsoft.EntityFrameworkCore;

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
            if (jobs.HasActiveJobs && models.Current is { } activeModel && !string.Equals(activeModel.Name, request.Name, StringComparison.Ordinal))
                return Results.Json(new ApiProblem("speech_job_running", "Stop active speech jobs before changing the speech model."), statusCode: StatusCodes.Status409Conflict);
            models.StartDownload(request.Name);
            return Results.Ok(Settings(jobs, models));
        });
        server.MapDelete("/model", (SpeechJobService jobs, SpeechModelStore models) =>
        {
            if (jobs.HasActiveJobs)
                return Results.Json(new ApiProblem("speech_job_running", "Stop active speech jobs before removing the speech model."), statusCode: StatusCodes.Status409Conflict);
            try
            {
                models.Remove();
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                return Results.Json(new ApiProblem("speech_model_remove_failed", "The speech model could not be removed right now."), statusCode: StatusCodes.Status500InternalServerError);
            }
            return Results.Ok(Settings(jobs, models));
        });

        var media = app.MapGroup("/api/v1/media/{mediaId:guid}/speech").RequireAuthorization("Administrator");
        media.MapGet(string.Empty, async (Guid mediaId, AureliaDbContext database, SpeechJobService jobs, CancellationToken token) =>
        {
            if (!await database.MediaItems.AsNoTracking().AnyAsync(item => item.Id == mediaId, token))
                return Results.Json(new ApiProblem("media_not_found", "The media item was not found."), statusCode: StatusCodes.Status404NotFound);
            return Results.Ok(new MediaSpeechResponse(jobs.Available, jobs.ModelReady, jobs.Status(mediaId)));
        });
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
