using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.RateLimiting;
using Microsoft.Extensions.Configuration;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Endpoints;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;

var commandLine = ServerCommandLine.Parse(args);
if (commandLine.Command == "library")
{
    Environment.ExitCode = await LibraryCommandClient.RunAsync(commandLine, CancellationToken.None);
    return;
}

if (commandLine.Command == "metadata")
{
    Environment.ExitCode = await MetadataCommandClient.RunAsync(commandLine, CancellationToken.None);
    return;
}

if (commandLine.Command == "pairing")
{
    Environment.ExitCode = await PairingCommandClient.RunAsync(commandLine, CancellationToken.None);
    return;
}

if (commandLine.Command == "server")
{
    Environment.ExitCode = await ServerIdentityCommandClient.RunAsync(
        commandLine,
        CancellationToken.None);
    return;
}

if (commandLine.Command == "database")
{
    var configuration = new ConfigurationBuilder().Build();
    var databaseRuntime = ServerRuntimeOptions.Resolve(configuration, args);
    Environment.ExitCode = await DatabaseCommandClient.RunAsync(
        commandLine,
        databaseRuntime,
        CancellationToken.None);
    return;
}

var builder = WebApplication.CreateBuilder(args);
var runtime = ServerRuntimeOptions.Resolve(builder.Configuration, args);

PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
using var instanceLock = runtime.HostParentProcessId is not null
    ? await ServerInstanceLock.AcquireForHostAsync(runtime.DataDirectory, CancellationToken.None)
    : appInstanceLock();
await FullServerBackupService.RecoverInterruptedRestoreAsync(runtime, CancellationToken.None);
runtime = ServerRuntimeOptions.Resolve(builder.Configuration, args);
await new DatabaseBackupService(runtime).RecoverPendingRestoreAsync(CancellationToken.None);
using var tlsIdentity = ServerTlsIdentity.LoadOrCreate(runtime);
var dataProtectionDirectory = Path.Combine(runtime.DataDirectory, "DataProtectionKeys");
PrivateFilePermissions.CreatePrivateDirectory(dataProtectionDirectory);
builder.WebHost.UseUrls(runtime.ListenUrl);
builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.MaxRequestBodySize = ServerRequestGuard.MaximumJsonBytes;
    options.Limits.MaxRequestHeadersTotalSize = 16_384;
    options.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(15);
});
if (tlsIdentity.Certificate is not null)
{
    builder.WebHost.ConfigureKestrel(options =>
        options.ConfigureHttpsDefaults(https =>
            https.ServerCertificate = tlsIdentity.Certificate));
}
builder.Logging.AddFilter("Microsoft.AspNetCore.Hosting.Diagnostics", LogLevel.Warning);
builder.Logging.AddFilter("Microsoft.AspNetCore.Routing", LogLevel.Warning);
if (commandLine.Command == "setup-owner")
{
    builder.Logging.SetMinimumLevel(LogLevel.Warning);
}

var connectionString = new SqliteConnectionStringBuilder
{
    DataSource = runtime.DatabasePath,
    Mode = SqliteOpenMode.ReadWriteCreate,
    // Shared-cache table locks defeat WAL reader/writer concurrency, even when
    // readers use deferred transactions. Each pooled connection needs a private cache.
    Cache = SqliteCacheMode.Private,
    ForeignKeys = true,
    Pooling = true,
}.ToString();

builder.Services.AddSingleton(runtime);
builder.Services.AddSingleton(tlsIdentity);
builder.Services.AddSingleton<BootstrapSetupAuthorizer>();
builder.Services.AddDataProtection()
    .SetApplicationName("Aurelia.Server")
    .PersistKeysToFileSystem(new DirectoryInfo(dataProtectionDirectory));
builder.Services.AddSingleton<DatabaseChangeSignal>();
builder.Services.AddSingleton<DatabaseSaveSignal>();
builder.Services.AddSingleton<DatabaseCommitSignal>();
builder.Services.AddDbContext<AureliaDbContext>((services, options) =>
    options.UseSqlite(connectionString).AddInterceptors(services.GetRequiredService<DatabaseSaveSignal>(), services.GetRequiredService<DatabaseCommitSignal>()));
builder.Services.AddSingleton<TokenService>();
builder.Services.AddSingleton<SessionActivityRecorder>();
builder.Services.AddSingleton<DatabaseBackupService>();
builder.Services.AddSingleton<FullServerBackupService>();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton(PlaybackTicketPolicy.Resolve(
    builder.Environment.IsEnvironment("Testing"),
    Environment.GetEnvironmentVariable("AURELIA_TEST_TICKET_LIFETIME_SECONDS")));
builder.Services.AddScoped<AccountService>();
builder.Services.AddScoped<ProfileService>();
builder.Services.AddSingleton<ProfileSessionStore>();
builder.Services.AddSingleton<ProfilePinAttemptGuard>();
builder.Services.AddSingleton<LocalOwnerPinRecovery>();
builder.Services.AddScoped<LibraryAccessService>();
builder.Services.AddSingleton<CatalogMutationGate>();
builder.Services.AddSingleton<EditorArtworkStore>();
builder.Services.AddScoped<MediaEditorService>();
builder.Services.AddScoped<LibraryMutationService>();
builder.Services.AddHostedService<LibraryCleanupWorker>();
builder.Services.AddSingleton<ServerConfigurationStore>();
builder.Services.AddSingleton<CredentialAttemptGuard>();
builder.Services.AddSingleton<ActiveStreamRegistry>();
builder.Services.AddSingleton<AdministrationApprovalStore>();
builder.Services.AddSingleton<ServerRequestGuard>();
builder.Services.AddSingleton<NativeHostOperations>();
builder.Services.AddSingleton<ServerDiagnosticsStore>();
builder.Services.AddHostedService(services => services.GetRequiredService<ServerDiagnosticsStore>());
builder.Services.AddScoped<LibraryService>();
builder.Services.AddScoped<ImportPlanningService>();
builder.Services.AddScoped<CatalogService>();
builder.Services.AddScoped<PlaybackService>();
builder.Services.AddScoped<PlaybackProgressService>();
builder.Services.AddScoped<SceneNoteService>();
builder.Services.AddScoped<MetadataService>();
builder.Services.AddScoped<MetadataJobStore>();
builder.Services.AddScoped<PresentationService>();
builder.Services.AddScoped<LibraryStateService>();
builder.Services.AddScoped<LibraryReachabilityService>();
builder.Services.AddHostedService<LibraryReachabilityWorker>();
builder.Services.AddScoped<SyncChangeService>();
builder.Services.AddScoped<MediaSearchIndexService>();
builder.Services.AddSingleton<MetadataProviderSettingsStore>();
builder.Services.AddSingleton<ArtworkStore>();
builder.Services.AddSingleton<MetadataJobScheduler>();
builder.Services.AddHttpClient<ITmdbClient, TmdbClient>(client =>
{
    client.Timeout = TimeSpan.FromSeconds(30);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("Aurelia/1.0");
});
builder.Services.AddSingleton<IMediaLibraryScanner, MediaLibraryScanner>();
builder.Services.AddSingleton<LibraryScanScheduler>();
builder.Services.AddHostedService<LibraryScanWorker>();
builder.Services.AddHostedService<MetadataJobWorker>();
builder.Services.AddHostedService<LibraryMonitoringService>();
builder.Services.AddHostedService<MaintenanceService>();
builder.Services.AddHostedService<BonjourAdvertisementService>();
builder.Services.AddHostedService<ParentProcessMonitor>();
builder.Services.AddScoped<IPasswordHasher<ServerUser>, PasswordHasher<ServerUser>>();
builder.Services.Configure<PasswordHasherOptions>(options =>
{
    options.CompatibilityMode = PasswordHasherCompatibilityMode.IdentityV3;
    options.IterationCount = 210_000;
});

builder.Services
    .AddAuthentication(DeviceTokenAuthenticationHandler.SchemeName)
    .AddScheme<AuthenticationSchemeOptions, DeviceTokenAuthenticationHandler>(
        DeviceTokenAuthenticationHandler.SchemeName,
        _ => { });
builder.Services.AddAuthorizationBuilder()
    .SetDefaultPolicy(new Microsoft.AspNetCore.Authorization.AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser().RequireClaim("aurelia_credential_kind", "profile").Build())
    .AddPolicy("TrustedDevice", policy => policy.RequireAuthenticatedUser().RequireClaim("aurelia_credential_kind", "device"))
    .AddPolicy("Owner", policy => policy.RequireClaim("aurelia_credential_kind", "profile").RequireRole(UserRole.Owner.ToString()))
    .AddPolicy("Administrator", policy => policy.RequireClaim("aurelia_credential_kind", "profile").RequireRole(
        UserRole.Owner.ToString(),
        UserRole.Admin.ToString()));

builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.Converters.Add(
        new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
});

builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.OnRejected = async (context, token) =>
    {
        context.HttpContext.Response.Headers.RetryAfter = "60";
        await context.HttpContext.Response.WriteAsJsonAsync(new ApiProblem("rate_limited", "Too many requests. Try again shortly."), token);
    };
    options.AddPolicy("authentication", context => RateLimitPartition.GetFixedWindowLimiter(
        context.Connection.RemoteIpAddress?.ToString() ?? "local",
        _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 10,
            Window = TimeSpan.FromMinutes(1),
            QueueLimit = 0,
            AutoReplenishment = true,
        }));
    options.AddPolicy("pairing", context => RateLimitPartition.GetFixedWindowLimiter(
        context.User.Identity?.Name ?? "anonymous",
        _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 5,
            Window = TimeSpan.FromMinutes(1),
            QueueLimit = 0,
            AutoReplenishment = true,
        }));
});

var app = builder.Build();
// Long polling and active streams must not hold the old database instance open
// for the full HTTP shutdown timeout after the native helper disappears.
app.Use((context, next) => ServerShutdownRequest.RunAsync(context, next, app.Lifetime.ApplicationStopping));
HostReadinessSignal.Register(
    app.Services.GetRequiredService<Microsoft.Extensions.Hosting.IHostApplicationLifetime>(),
    Console.Out,
    Environment.GetEnvironmentVariable(HostReadinessSignal.EnvironmentVariableName));
app.Use(async (context, next) =>
{
    if (!context.RequestServices.GetRequiredService<ServerRequestGuard>().Admit(context.Connection.RemoteIpAddress))
    {
        context.Response.StatusCode = 429;
        context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record("request_rate_limited", "warning", status: 429);
        context.Response.Headers.RetryAfter = "60";
        await context.Response.WriteAsJsonAsync(new ApiProblem("rate_limited", "Too many requests. Try again shortly."));
        return;
    }
    var networks = context.RequestServices.GetRequiredService<ServerConfigurationStore>().Current.AllowedNetworks;
    if (!ServerRequestGuard.NetworkAllowed(context.Connection.RemoteIpAddress, networks))
    {
        context.Response.StatusCode = 403;
        context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record("network_access_rejected", "warning", status: 403);
        return;
    }
    var backupUpload = HttpMethods.IsPut(context.Request.Method) && (context.Request.Path.Value ?? "").StartsWith("/api/v1/server/backups/uploads/", StringComparison.OrdinalIgnoreCase);
    var editorPath = (context.Request.Path.Value ?? "").Contains("/editor", StringComparison.Ordinal);
    var imageUpload = editorPath && HttpMethods.IsPost(context.Request.Method) && context.Request.Path.Value!.EndsWith("/uploads", StringComparison.Ordinal);
    var maximumBytes = backupUpload ? EncryptedBackupContainer.MaximumBytes : imageUpload ? EditorArtworkStore.MaximumUploadBytes
        : editorPath ? 1024 * 1024 : ServerRequestGuard.MaximumJsonBytes;
    if (context.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } feature)
        feature.MaxRequestBodySize = maximumBytes;
    if (context.Request.ContentLength > maximumBytes)
    {
        context.Response.StatusCode = 413;
        context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record("request_too_large", "warning", status: 413);
        return;
    }
    await next(context);
    if (context.Response.StatusCode >= 400 && context.Items["Aurelia.FailureRecorded"] is not true)
    {
        var status = context.Response.StatusCode;
        var code = status switch { 401 => "authentication_rejected", 403 => "access_rejected", 429 => "request_rate_limited", >= 500 => "request_failed", _ => "request_rejected" };
        context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record(code, status >= 500 ? "error" : "warning",
            context.User.Identity?.IsAuthenticated == true ? context.User.RequireUserId() : null, status);
    }
});
app.UseAuthentication();
app.UseRateLimiter();
app.UseAuthorization();
app.Use(async (context, next) =>
{
    context.RequestServices.GetRequiredService<LibraryAccessService>().Bind(context);
    try
    {
        ServerRequestGuard.RequireManagement(context, context.RequestServices.GetRequiredService<ProfileSessionStore>());
        await ServerRequestGuard.RequireApprovalAsync(context, context.RequestServices.GetRequiredService<AdministrationApprovalStore>());
        if (context.User.Identity?.IsAuthenticated == true && context.Request.Path.StartsWithSegments("/api/v1/streams"))
        {
            var limits = context.RequestServices.GetRequiredService<ServerConfigurationStore>().Current;
            using var lease = context.RequestServices.GetRequiredService<ActiveStreamRegistry>().Enter(
                context.User.RequireUserId(), context.User.RequireProfileSessionId(), limits.GlobalStreamLimit, limits.UserStreamLimit, context.RequestAborted);
            context.RequestAborted = lease.Token;
            context.Items["Aurelia.StreamLease"] = lease;
            await next(context);
        }
        else await next(context);
        if (context.Items["Aurelia.AdministrationApproved"] is true && context.Response.StatusCode < 400)
            context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record("owner_change_completed", "information", context.User.RequireUserId(), context.Response.StatusCode);
    }
    catch (AccountException exception) when (!context.Response.HasStarted)
    {
        // Expected proof handshakes and a closed administrative window are state
        // transitions, not authentication attacks. Record the precise code once.
        var severity = exception.Code is "approval_required" or "management_locked" or "management_unlock_superseded"
            ? "information" : exception.StatusCode >= 500 ? "error" : "warning";
        context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record(exception.Code, severity, context.User.Identity?.IsAuthenticated == true ? context.User.RequireUserId() : null, exception.StatusCode);
        context.Items["Aurelia.FailureRecorded"] = true;
        context.Response.StatusCode = exception.StatusCode;
        if (exception.StatusCode == 429) context.Response.Headers.RetryAfter = "60";
        await context.Response.WriteAsJsonAsync(new ApiProblem(exception.Code, exception.Message));
    }
    catch (InvalidDataException) when (!context.Response.HasStarted)
    {
        context.Response.StatusCode = 400;
        context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record("invalid_server_data", "warning",
            context.User.Identity?.IsAuthenticated == true ? context.User.RequireUserId() : null, 400);
        context.Items["Aurelia.FailureRecorded"] = true;
        await context.Response.WriteAsJsonAsync(new ApiProblem("invalid_server_data", "The operation data could not be validated. Active server data was not replaced."));
    }
    catch (IOException) when (!context.Response.HasStarted && (context.Request.Path.StartsWithSegments("/api/v1/server")
        || context.Request.Path.StartsWithSegments("/api/v1/media") || context.Request.Path.StartsWithSegments("/api/v1/libraries")))
    {
        context.Response.StatusCode = 507;
        context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record("server_storage_operation_failed", "error",
            context.User.Identity?.IsAuthenticated == true ? context.User.RequireUserId() : null, 507);
        context.Items["Aurelia.FailureRecorded"] = true;
        await context.Response.WriteAsJsonAsync(new ApiProblem("server_storage_unavailable", "The storage operation failed. Check available disk space and permissions."));
    }
});
app.MapAureliaApi();
app.MapServerManagement();
app.MapMediaEditing();
app.MapImportPlanning();
app.MapSceneNotes();
app.MapProfiles();

try
{
    await DatabaseInitializer.InitializeAsync(app.Services, CancellationToken.None);

    if (runtime.LanAccessEnabled)
    {
        await using var readinessScope = app.Services.CreateAsyncScope();
        var database = readinessScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        if (!await database.Users.AnyAsync())
        {
            Console.Error.WriteLine(
                "LAN access requires an owner. Run setup-owner locally before starting with --lan.");
            Environment.ExitCode = 2;
            return;
        }
    }

    if (commandLine.Command == "setup-owner")
    {
        if (string.IsNullOrWhiteSpace(commandLine.Username))
        {
            Console.Error.WriteLine("setup-owner requires --username.");
            Environment.ExitCode = 2;
            return;
        }

        await using var scope = app.Services.CreateAsyncScope();
        var accounts = scope.ServiceProvider.GetRequiredService<AccountService>();
        try
        {
            var response = await accounts.SetupOwnerAsync(
                new SetupOwnerRequest(
                    commandLine.Username,
                    commandLine.ReadPassword(),
                    commandLine.DeviceName),
                CancellationToken.None);
            Console.WriteLine(JsonSerializer.Serialize(response, new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
                Converters =
                {
                    new JsonStringEnumConverter(
                        JsonNamingPolicy.CamelCase,
                        allowIntegerValues: false),
                },
            }));
        }
        catch (AccountException exception)
        {
            Console.Error.WriteLine($"{exception.Code}: {exception.Message}");
            Environment.ExitCode = 1;
        }

        return;
    }

    if (runtime.LanAccessEnabled)
    {
        Console.WriteLine($"Aurelia HTTPS is available on LAN port {runtime.LanHttpsPort}.");
        Console.WriteLine($"Verification fingerprint: {tlsIdentity.DisplayFingerprint}");
    }

    await app.RunAsync();
}
finally
{
    instanceLock?.Dispose();
}

ServerInstanceLock? appInstanceLock() => builder.Environment.IsEnvironment("Testing")
    ? null
    : ServerInstanceLock.Acquire(runtime.DataDirectory);

public partial class Program
{
}
