using Aurelia.Contracts;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

public static class ServerReadinessEndpoints
{
    public static void MapServerReadiness(this WebApplication app)
    {
        app.MapMethods("/api/v1/health/live", ["GET", "HEAD"], (HttpContext context) =>
            HttpMethods.IsHead(context.Request.Method) ? (IResult)Results.StatusCode(200) : Results.Json(new ServerLivenessResponse("alive")));
        app.MapGet("/api/v1/health/ready", (ServerReadinessService readiness) =>
        {
            var state = readiness.Current.State;
            return Results.Json(new ServerReadinessResponse(state), statusCode: state is "starting" or "recovering" or "unavailable" ? 503 : 200);
        });
    }
}
