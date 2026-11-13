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
        // Pictures show in "Who's watching?" before a profile is open. A revision in the query lets clients cache them.
        devices.MapGet("/{id:guid}/picture", async (Guid id, ProfileService service, HttpContext context) =>
        {
            if (await service.PhotoAsync(id, context.RequestAborted) is not { } jpeg) return Results.NotFound();
            context.Response.Headers.CacheControl = "private, max-age=31536000, immutable";
            return Results.Bytes(jpeg, "image/jpeg");
        });
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

        // Every profile may change its own name and picture.
        app.MapPut("/api/v1/profile/name", (UpdateProfileNameRequest request, ProfileService service, HttpContext context) =>
            service.RenameAsync(context.User.RequireUserId(), context.User.RequireUserId(), request.Name, context.RequestAborted)).RequireAuthorization();
        app.MapPut("/api/v1/profile/picture", (UpdateProfilePictureRequest request, ProfileService service, HttpContext context) =>
            service.SetPictureAsync(context.User.RequireUserId(), context.User.RequireUserId(), request.Builtin, context.RequestAborted)).RequireAuthorization();
        app.MapPut("/api/v1/profile/picture/photo", (ProfileService service, HttpContext context) =>
            service.SetPhotoAsync(context.User.RequireUserId(), context.User.RequireUserId(), context.Request.Body, context.RequestAborted)).RequireAuthorization();

        var management = app.MapGroup("/api/v1/management").RequireAuthorization("Administrator");
        management.MapPost("/unlock", async (UnlockManagementRequest request, ProfileService service, ProfileSessionStore sessions,
            SecuritySettingsStore security, HttpContext context) =>
        {
            RequirePrivateTransport(context);
            // With Face ID or Touch ID required, the Server Password unlocks only on the server
            // computer itself (the way back if every key is lost); other devices use a key or ask one.
            if (security.Current.RequirePasskeysForAdministrators && !ClientIdentity.IsLoopback(context))
                throw new AccountException("passkey_required",
                    "Confirm with Face ID or Touch ID, or on a device that has it. The Server Password works only on the server computer now.", 403);
            var profileId = context.User.RequireProfileSessionId();
            var epoch = sessions.ManagementEpoch(profileId);
            await service.VerifyManagementAsync(context.User.RequireUserId(), request.Password, context.RequestAborted, context.User.RequireSessionId());
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
        app.MapPut("/api/v1/users/{id:guid}/name", (Guid id, UpdateProfileNameRequest request, ProfileService service, HttpContext context) =>
            service.RenameAsync(context.User.RequireUserId(), id, request.Name, context.RequestAborted)).RequireAuthorization("Owner");
        app.MapPut("/api/v1/users/{id:guid}/picture", (Guid id, UpdateProfilePictureRequest request, ProfileService service, HttpContext context) =>
            service.SetPictureAsync(context.User.RequireUserId(), id, request.Builtin, context.RequestAborted)).RequireAuthorization("Owner");
        app.MapPut("/api/v1/users/{id:guid}/picture/photo", (Guid id, ProfileService service, HttpContext context) =>
            service.SetPhotoAsync(context.User.RequireUserId(), id, context.Request.Body, context.RequestAborted)).RequireAuthorization("Owner");
        app.MapGet("/api/v1/users/{id:guid}/age-limit", (Guid id, ProfileService service, CancellationToken token) =>
            service.AgeLimitAsync(id, token)).RequireAuthorization("Owner");
        app.MapPut("/api/v1/users/{id:guid}/age-limit", (Guid id, UpdateProfileAgeLimitRequest request, ProfileService service, HttpContext context) =>
            service.UpdateAgeLimitAsync(context.User.RequireUserId(), id, request, context.RequestAborted)).RequireAuthorization("Owner");
        // Screen time of a children's profile (docs/SCREEN_TIME.md): rules, and exceptions for today.
        app.MapGet("/api/v1/users/{id:guid}/screen-time", (Guid id, ScreenTimeService service, CancellationToken token) =>
            service.ProfileAsync(id, token)).RequireAuthorization("Owner");
        app.MapPut("/api/v1/users/{id:guid}/screen-time", (Guid id, UpdateProfileScreenTimeRequest request, ScreenTimeService service, CancellationToken token) =>
            service.UpdateAsync(id, request, token)).RequireAuthorization("Owner");
        app.MapPost("/api/v1/users/{id:guid}/screen-time/today", (Guid id, GrantScreenTimeRequest request, ScreenTimeService service, CancellationToken token) =>
            service.GrantAsync(id, request, token)).RequireAuthorization("Owner");
        app.MapGet("/api/v1/profile/screen-time", async (ScreenTimeService service, HttpContext context) =>
            new OwnScreenTimeResponse(await service.StatusAsync(context.User.RequireUserId(), context.RequestAborted))).RequireAuthorization();
        app.MapGet("/api/v1/users/{id:guid}/titles", (Guid id, ProfileService service, CancellationToken token) => service.AccessAsync(id, token)).RequireAuthorization("Owner");
        app.MapPut("/api/v1/users/{id:guid}/enabled", async (Guid id, SetProfileEnabledRequest request, ProfileService service, HttpContext context) =>
        { await service.SetEnabledAsync(context.User.RequireUserId(), id, request.IsEnabled, context.RequestAborted); return Results.NoContent(); }).RequireAuthorization("Owner");
        app.MapPut("/api/v1/users/{id:guid}/titles", (Guid id, UpdateProfileTitleAccessRequest request, ProfileService service, HttpContext context) =>
            service.UpdateAccessAsync(context.User.RequireUserId(), id, request, context.RequestAborted)).RequireAuthorization("Owner");
        app.MapGet("/api/v1/capabilities", async (LiveConversionService live) => new ClientCapabilitiesResponse(
            2, "1.5.1", true, true, true, true, true, true, ServerFeatures.Reported(await live.IsAvailableAsync(), await live.SpeechAudioAvailableAsync(), await live.CanEncodeVideoAsync())));
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
