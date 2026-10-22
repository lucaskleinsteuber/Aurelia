using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Endpoints;

public static class ServerManagementEndpoints
{
    public static void MapServerManagement(this WebApplication app)
    {
        var server = app.MapGroup("/api/v1/server").RequireAuthorization("Owner");
        server.MapGet("/settings", (ServerConfigurationStore configuration) => configuration.Read());
        server.MapGet("/capabilities", (NativeHostOperations operations) => new ServerManagementCapabilities(operations.Available, true, false));
        server.MapGet("/operations/current", (NativeHostOperations operations, CancellationToken token) => operations.StatusAsync(token));
        server.MapGet("/hosting", (NativeHostOperations operations, CancellationToken token) => operations.HostingStatusAsync(token));
        server.MapPost("/operations/restart", (HttpContext context, NativeHostOperations operations) => operations.RestartAsync(context.User.RequireSessionId(), context.RequestAborted));
        server.MapPost("/operations/hosting", (HttpContext context, HostingChangeRequest request, NativeHostOperations operations, CancellationToken token) =>
            operations.AuthorizeHostingAsync(context.User.RequireSessionId(), request, token));
        server.MapPost("/operations/network", (HttpContext context, NetworkTrialRequest request, NativeHostOperations operations) => operations.TrialAsync(context.User.RequireSessionId(), request, context.RequestAborted));
        server.MapPost("/operations/{id:guid}/confirm", async (HttpContext context, Guid id, NativeHostOperations operations) =>
        { await operations.ConfirmAsync(id, context.User.RequireSessionId(), context.RequestAborted); return Results.NoContent(); });
        server.MapGet("/diagnostics", (ServerDiagnosticsStore diagnostics) => diagnostics.Read());
        server.MapGet("/power", (ServerPowerSettingsStore power) => power.Read());
        server.MapPut("/power", (UpdateServerPowerSettingsRequest request, ServerPowerSettingsStore power) => power.Update(request));
        server.MapGet("/jobs", async (LibraryService libraries, MetadataService metadata, CancellationToken token) => new
        { scans = await libraries.ListScansAsync(null, false, 100, token), metadata = await metadata.ListJobsAsync(false, 100, token) });
        app.MapPost("/api/v1/metadata/jobs/{id:guid}/retry", (Guid id, MetadataService metadata, CancellationToken token) => metadata.RetryJobAsync(id, token))
            .RequireAuthorization("Administrator");
        server.MapGet("/diagnostics/export", (ServerDiagnosticsStore diagnostics, ServerConfigurationStore configuration) => new
        { formatVersion = 1, version = ServerProductVersion.Current, policy = new { configuration.Current.DeviceSessionDays, configuration.Current.GlobalStreamLimit, configuration.Current.UserStreamLimit }, events = diagnostics.Read() });
        server.MapGet("/backups", (DatabaseBackupService backups) => backups.ListBackups().OrderByDescending(value => value.CreatedAt).Select(value => new
        { name = Path.GetFileName(value.Path), kind = value.Kind.ToString().ToLowerInvariant(), value.CreatedAt, bytes = new FileInfo(value.Path).Length }));
        server.MapPost("/backups/database", async (DatabaseBackupService backups, CancellationToken token) => new
        { name = Path.GetFileName(await backups.CreateBackupAsync(DatabaseBackupKind.Manual, token)) });
        server.MapPost("/backups/{name}/verify", async (string name, DatabaseBackupService backups, CancellationToken token) =>
        {
            var backup = backups.ListBackups().SingleOrDefault(value => Path.GetFileName(value.Path) == name)
                ?? throw new AccountException("backup_not_found", "The backup was not found.", 404);
            return await backups.VerifyAsync(backup.Path, token);
        });
        server.MapPost("/backups/export", (BackupExportRequest request, FullServerBackupService backups, CancellationToken token) => backups.ExportAsync(request.Passphrase, token));
        server.MapGet("/backups/transfers/{id:guid}", (Guid id, FullServerBackupService backups) =>
        {
            var path = backups.TransferPath(id);
            if (!File.Exists(path) || new FileInfo(path).LinkTarget is not null) return Results.NotFound();
            return Results.File(path, "application/octet-stream", "Aurelia-Server.aureliabackup");
        });
        server.MapDelete("/backups/transfers/{id:guid}", (Guid id, FullServerBackupService backups) =>
        { var path = backups.TransferPath(id); if (File.Exists(path)) File.Delete(path); return Results.NoContent(); });
        server.MapPut("/backups/uploads/{id:guid}", async (HttpContext context, Guid id, FullServerBackupService backups) =>
        {
            await backups.UploadAsync(id, context.Request.Body, context.Request.ContentLength ?? 0, context.RequestAborted);
            return Results.NoContent();
        });
        server.MapPost("/backups/restore/prepare", (BackupRestoreRequest request, FullServerBackupService backups, CancellationToken token) => backups.PrepareRestoreAsync(request, token));
        server.MapPost("/backups/restore/{id:guid}/apply", (HttpContext context, Guid id, NativeHostOperations operations) => operations.ApplyRestoreAsync(context.User.RequireSessionId(), id, context.RequestAborted));
        server.MapPut("/settings", (ServerHostSettings request, ServerConfigurationStore configuration) => configuration.Update(request));
        server.MapPost("/approval", (HttpContext context, AdministrationApprovalRequest request,
            AdministrationApprovalStore approvals) =>
        {
            if (!context.Request.IsHttps && context.Connection.RemoteIpAddress is { } ip && !System.Net.IPAddress.IsLoopback(ip))
                throw new AccountException("https_required", "Administrative authorization requires the verified HTTPS connection.", 403);
            var result = approvals.Issue(context.User.RequireProfileSessionId(), request.Action, request.PayloadHash);
            return new AdministrationApprovalResponse(result.Token, result.ExpiresAt);
        });
        server.MapGet("/users", (AccountService accounts, CancellationToken token) => accounts.ListAccessAsync(token));
        server.MapGet("/status", (ServerReadinessService readiness, ServerTlsIdentity identity, ActiveStreamRegistry streams) =>
            readiness.Status(identity, streams));
        server.MapGet("/sessions/{userId:guid}", (HttpContext context, Guid userId, AccountService accounts) =>
            accounts.ListSessionsAsync(userId, context.User.RequireSessionId(), context.RequestAborted));
        server.MapDelete("/sessions/{sessionId:guid}", async (HttpContext context, Guid sessionId, AccountService accounts) =>
        {
            await accounts.RevokeSessionAsync(context.User.RequireUserId(), context.User.RequireSessionId(), sessionId, context.RequestAborted);
            return Results.NoContent();
        });
        var users = app.MapGroup("/api/v1/users").RequireAuthorization("Owner");
        users.MapPut("/{userId:guid}/access", async (HttpContext context, Guid userId, UpdateUserAccessRequest request, AccountService accounts) =>
        {
            await accounts.UpdateAccessAsync(context.User.RequireUserId(), userId, request, context.RequestAborted);
            return Results.NoContent();
        });
        users.MapPut("/{userId:guid}/password", async (HttpContext context, Guid userId, ResetUserPasswordRequest request, AccountService accounts) =>
        {
            await accounts.ResetPasswordAsync(context.User.RequireUserId(), userId, request.Password, context.RequestAborted);
            return Results.NoContent();
        });
        users.MapDelete("/{userId:guid}/sessions", async (HttpContext context, Guid userId, AccountService accounts) =>
        {
            await accounts.RevokeAllSessionsAsync(context.User.RequireUserId(), userId, context.RequestAborted);
            return Results.NoContent();
        });
    }
}
