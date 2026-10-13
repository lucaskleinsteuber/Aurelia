using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Services;

namespace Aurelia.Server.Endpoints;

public static class ProfileEndpoints
{
    public static void MapProfiles(this WebApplication app)
    {
        var devices = app.MapGroup("/api/v1/profiles").RequireAuthorization("TrustedDevice");
        app.MapDelete("/api/v1/device", async (AccountService accounts, HttpContext context) =>
        { await accounts.RevokeOwnDeviceAsync(context.User.RequireSessionId(), context.RequestAborted); return Results.NoContent(); }).RequireAuthorization("TrustedDevice");
        devices.MapGet("", (ProfileService service, CancellationToken token) => service.PickerAsync(token));
        devices.MapPost("/initialize", async (HttpContext context, InitializeProfilesRequest request, ProfileService service) =>
        {
            RequirePrivateTransport(context);
            await service.InitializeAsync(context.User.RequireSessionId(), request, context.RequestAborted);
            return Results.NoContent();
        }).RequireRateLimiting("authentication");
        devices.MapPost("/{id:guid}/unlock", (Guid id, UnlockProfileRequest request, ProfileService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            return service.UnlockAsync(context.User.RequireSessionId(), id, request.Pin, context.RequestAborted);
        }).RequireRateLimiting("authentication");

        app.MapPost("/api/v1/profile/end", (HttpContext context, ProfileSessionStore sessions) =>
        { sessions.End(context.User.RequireProfileSessionId()); return Results.NoContent(); }).RequireAuthorization();
        app.MapPut("/api/v1/profile/pin", async (ChangeProfilePinRequest request, ProfileService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            await service.ChangePinAsync(context.User.RequireSessionId(), context.User.RequireUserId(), request, context.RequestAborted);
            return Results.NoContent();
        }).RequireAuthorization().RequireRateLimiting("authentication");
        app.MapPut("/api/v1/profile/pin-protection", async (UpdateOwnPinProtectionRequest request, ProfileService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            await service.SetOwnPinProtectionAsync(context.User.RequireSessionId(), context.User.RequireUserId(), request, context.RequestAborted);
            return Results.NoContent();
        }).RequireAuthorization().RequireRateLimiting("authentication");

        var management = app.MapGroup("/api/v1/management").RequireAuthorization("Administrator");
        management.MapPost("/unlock", async (UnlockManagementRequest request, ProfileService service, ProfileSessionStore sessions, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            var profileId = context.User.RequireProfileSessionId();
            var epoch = sessions.ManagementEpoch(profileId);
            await service.VerifyManagementAsync(context.User.RequireUserId(), request.Password, context.RequestAborted);
            return new ManagementUnlockResponse(sessions.UnlockManagement(profileId, epoch));
        }).RequireRateLimiting("authentication");
        management.MapPost("/lock", (ProfileSessionStore sessions, HttpContext context) =>
        { sessions.LockManagement(context.User.RequireProfileSessionId()); return Results.NoContent(); });
        management.MapPost("/approval", (AdministrationApprovalRequest request, AdministrationApprovalStore approvals, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            var issued = approvals.Issue(context.User.RequireProfileSessionId(), request.Action, request.PayloadHash);
            return new AdministrationApprovalResponse(issued.Token, issued.ExpiresAt);
        });
        app.MapPut("/api/v1/users/{id:guid}/pin", async (Guid id, ResetProfilePinRequest request, ProfileService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            await service.ResetPinAsync(context.User.RequireUserId(), id, request.Pin, context.RequestAborted);
            return Results.NoContent();
        }).RequireAuthorization("Owner");
        app.MapGet("/api/v1/users/{id:guid}/profile", (Guid id, ProfileService service, CancellationToken token) =>
            service.EditorAsync(id, token)).RequireAuthorization("Owner");
        app.MapPut("/api/v1/users/{id:guid}/profile", (Guid id, UpdateProfileRequest request, ProfileService service, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            return service.UpdateAsync(context.User.RequireUserId(), id, request, context.RequestAborted);
        }).RequireAuthorization("Owner");
        app.MapGet("/api/v1/users/{id:guid}/titles", (Guid id, ProfileService service, CancellationToken token) => service.AccessAsync(id, token)).RequireAuthorization("Owner");
        app.MapPut("/api/v1/users/{id:guid}/enabled", async (Guid id, SetProfileEnabledRequest request, ProfileService service, HttpContext context) =>
        { await service.SetEnabledAsync(context.User.RequireUserId(), id, request.IsEnabled, context.RequestAborted); return Results.NoContent(); }).RequireAuthorization("Owner");
        app.MapPut("/api/v1/users/{id:guid}/titles", (Guid id, UpdateProfileTitleAccessRequest request, ProfileService service, HttpContext context) =>
            service.UpdateAccessAsync(context.User.RequireUserId(), id, request, context.RequestAborted)).RequireAuthorization("Owner");
        app.MapGet("/api/v1/capabilities", () => new
        {
            formatVersion = 2,
            minimumClientVersion = "1.5.1",
            profilePins = true,
            optionalProfilePins = true,
            atomicProfileEditing = true,
            automaticManagementApprovals = true,
            sceneNotes = true,
            titleAccess = true
        });
        app.MapPost("/api/v1/local/owner-pin", async (InitializeProfilesRequest request, LocalOwnerPinRecovery recovery,
            Aurelia.Server.Data.AureliaDbContext database, ProfileService profiles, HttpContext context) =>
        { recovery.Authorize(context); await recovery.RecoverAsync(request, database, profiles, context.RequestAborted); return Results.NoContent(); })
            .RequireRateLimiting("authentication");
    }

    private static void RequirePrivateTransport(HttpContext context)
    {
        if (!context.Request.IsHttps && context.Connection.RemoteIpAddress is { } ip && !System.Net.IPAddress.IsLoopback(ip))
            throw new AccountException("https_required", "Credentials require the verified HTTPS connection.", 403);
    }
}
