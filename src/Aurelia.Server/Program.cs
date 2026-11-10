using System.IO.Compression;
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
using Microsoft.AspNetCore.ResponseCompression;
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
    // A new TLS connection costs about 50 ms on macOS because the key lives in a keychain;
    // idle client connections therefore stay open longer so they can be reused.
    options.Limits.KeepAliveTimeout = TimeSpan.FromMinutes(10);
    // A household needs a few dozen connections; the cap stops one device from holding
    // thousands of idle connections open. The server name is not advertised.
    options.Limits.MaxConcurrentConnections = 512;
    options.AddServerHeader = false;
});
if (tlsIdentity.Certificate is not null)
{
    builder.WebHost.ConfigureKestrel(options =>
        options.ConfigureHttpsDefaults(https =>
            https.ServerCertificate = tlsIdentity.Certificate));
}
// Every request would otherwise leave lines in the journal, all night while an app waits for changes.
builder.Logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);
builder.Logging.AddFilter("System.Net.Http.HttpClient", LogLevel.Warning);
// Every database command at the default level would fill a Linux journal with hundreds of
// thousands of lines an hour; warnings and errors still appear.
builder.Logging.AddFilter("Microsoft.EntityFrameworkCore", LogLevel.Warning);
if (commandLine.Command == "setup-owner")
{
    builder.Logging.SetMinimumLevel(LogLevel.Warning);
    // A model design note, not a problem with this server; setup over SSH stays readable.
    builder.Logging.AddFilter("Microsoft.EntityFrameworkCore.Model.Validation", LogLevel.Error);
}

var connectionString = SqliteConnections.ConnectionString(runtime.DatabasePath);

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
    options.UseSqlite(connectionString).AddInterceptors(services.GetRequiredService<DatabaseSaveSignal>(), services.GetRequiredService<DatabaseCommitSignal>(),
        SqliteWriteMode.Interceptor));
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
builder.Services.AddSingleton<DeviceAuthorizationGuard>();
builder.Services.AddScoped<DeviceAuthorizationService>();
builder.Services.AddSingleton<LocalOwnerPinRecovery>();
builder.Services.AddSingleton<WebAppAssets>();
builder.Services.AddScoped<LibraryAccessService>();
builder.Services.AddSingleton<CatalogMutationGate>();
builder.Services.AddSingleton<EditorArtworkStore>();
builder.Services.AddScoped<MediaEditorService>();
builder.Services.AddScoped<LibraryMutationService>();
builder.Services.AddHostedService<LibraryCleanupWorker>();
builder.Services.AddSingleton<ServerConfigurationStore>();
builder.Services.AddSingleton<CredentialAttemptGuard>();
builder.Services.AddSingleton<PairingCodeAttemptGuard>();
builder.Services.AddSingleton<ActiveStreamRegistry>();
builder.Services.AddSingleton<LiveConversionService>();
builder.Services.AddSingleton<ScrubPreviewService>();
if (!builder.Environment.IsEnvironment("Testing")) builder.Services.AddHostedService(services => services.GetRequiredService<ScrubPreviewService>());
builder.Services.AddSingleton<ServerSleepSignal>();
builder.Services.AddSingleton<ServerUseClock>();
builder.Services.AddSingleton(services => new ServerPowerSettingsStore(services.GetRequiredService<ServerRuntimeOptions>()));
builder.Services.AddSingleton(services => new ServerUpdateStore(services.GetRequiredService<ServerRuntimeOptions>(), services.GetRequiredService<TimeProvider>()));
builder.Services.AddSingleton<LinuxServiceRestart>();
builder.Services.AddHostedService<ServerSleepWorker>();
builder.Services.AddSingleton<AdministrationApprovalStore>();
builder.Services.AddSingleton<ServerRequestGuard>();
builder.Services.AddSingleton<NativeHostOperations>();
builder.Services.AddSingleton<ServerDiagnosticsStore>();
builder.Services.AddHostedService(services => services.GetRequiredService<ServerDiagnosticsStore>());
builder.Services.AddSingleton<ServerReadinessService>();
builder.Services.AddHostedService(services => services.GetRequiredService<ServerReadinessService>());
builder.Services.AddScoped<LibraryService>();
builder.Services.AddScoped<ImportPlanningService>();
builder.Services.AddScoped<CatalogService>();
builder.Services.AddScoped<PlaybackService>();
builder.Services.AddScoped<PlaybackProgressService>();
builder.Services.AddScoped<SceneNoteService>();
builder.Services.AddScoped<MetadataService>();
builder.Services.AddScoped<MetadataJobStore>();
builder.Services.AddScoped<PresentationService>();
builder.Services.AddScoped<WatchlistService>();
builder.Services.AddScoped<LibraryStateService>();
builder.Services.AddScoped<LibraryReachabilityService>();
builder.Services.AddHostedService<LibraryReachabilityWorker>();
builder.Services.AddScoped<SyncChangeService>();
builder.Services.AddScoped<MediaSearchIndexService>();
builder.Services.AddScoped<ServerHealthService>();
builder.Services.AddScoped<WatchHistoryService>();
builder.Services.AddScoped<LibraryHealthService>();
builder.Services.AddSingleton<RemotePlaybackService>();
builder.Services.AddSingleton<WatchTogetherService>();
builder.Services.AddSingleton<MovieNightService>();
builder.Services.AddSingleton<MetadataProviderSettingsStore>();
builder.Services.AddSingleton<ArtworkStore>();
builder.Services.AddSingleton<ArtworkVariantStore>();
// Prepares common artwork widths in the background; tests drive it explicitly.
if (!builder.Environment.IsEnvironment("Testing")) builder.Services.AddHostedService<ArtworkVariantWarmer>();
if (!builder.Environment.IsEnvironment("Testing")) builder.Services.AddHostedService<QueryWarmer>();
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
builder.Services.AddHttpClient<IOpenSubtitlesClient, OpenSubtitlesClient>(client =>
{
    client.Timeout = TimeSpan.FromSeconds(30);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("Aurelia v" + ServerProductVersion.Current);
});
builder.Services.AddSingleton<SubtitleProviderSettingsStore>();
builder.Services.AddSingleton<DownloadedSubtitleStore>();
builder.Services.AddSingleton<SubtitleQuota>();
builder.Services.AddScoped<SubtitleDownloadService>();
if (!builder.Environment.IsEnvironment("Testing")) builder.Services.AddHostedService<SubtitleAutoDownloader>();
builder.Services.AddSingleton<ContentRatingRefresh>();
if (!builder.Environment.IsEnvironment("Testing")) builder.Services.AddHostedService(services => services.GetRequiredService<ContentRatingRefresh>());
builder.Services.AddSingleton<CreditRefresh>();
if (!builder.Environment.IsEnvironment("Testing")) builder.Services.AddHostedService(services => services.GetRequiredService<CreditRefresh>());
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

// Library lists compress well and travel over Wi-Fi to the TV. Only GET catalog
// responses are compressed: they never contain credentials (no BREACH exposure),
// and media streams keep their exact byte ranges.
builder.Services.AddResponseCompression(options =>
{
    options.EnableForHttps = true;
    options.MimeTypes = ["application/json"];
    options.Providers.Add<BrotliCompressionProvider>();
    options.Providers.Add<GzipCompressionProvider>();
});
builder.Services.Configure<BrotliCompressionProviderOptions>(options => options.Level = CompressionLevel.Fastest);
builder.Services.Configure<GzipCompressionProviderOptions>(options => options.Level = CompressionLevel.Fastest);

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
app.Use((context, next) =>
{
    context.Response.OnStarting(() =>
    {
        SecurityHeaders.Apply(context.Response.Headers);
        return Task.CompletedTask;
    });
    return next(context);
});
HostReadinessSignal.Register(
    app.Services.GetRequiredService<Microsoft.Extensions.Hosting.IHostApplicationLifetime>(),
    Console.Out,
    Environment.GetEnvironmentVariable(HostReadinessSignal.EnvironmentVariableName));
app.Use(async (context, next) =>
{
    if (!context.RequestServices.GetRequiredService<ServerRequestGuard>().Admit(context.Connection.RemoteIpAddress, ServerRequestGuard.IsPreviewStream(context.Request)))
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
        // Say why, so a device can tell a network setting from a missing permission or an outage.
        await context.Response.WriteAsJsonAsync(new ApiProblem("network_not_allowed",
            "This device's network address is not allowed by the server's network settings."));
        return;
    }
    if (!ServerRequestGuard.HostAllowed(context.Request))
    {
        context.Response.StatusCode = 403;
        context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record("host_rejected", "warning", status: 403);
        await context.Response.WriteAsJsonAsync(new ApiProblem("host_not_allowed",
            "Without HTTPS, Aurelia Server only answers on the server computer's own address."));
        return;
    }
    var backupUpload = HttpMethods.IsPut(context.Request.Method) && (context.Request.Path.Value ?? "").StartsWith("/api/v1/server/backups/uploads/", StringComparison.OrdinalIgnoreCase);
    var editorPath = (context.Request.Path.Value ?? "").Contains("/editor", StringComparison.Ordinal);
    var imageUpload = editorPath && HttpMethods.IsPost(context.Request.Method) && context.Request.Path.Value!.EndsWith("/uploads", StringComparison.Ordinal);
    var photoUpload = HttpMethods.IsPut(context.Request.Method) && (context.Request.Path.Value ?? "").EndsWith("/picture/photo", StringComparison.OrdinalIgnoreCase);
    var maximumBytes = backupUpload ? EncryptedBackupContainer.MaximumBytes : imageUpload ? EditorArtworkStore.MaximumUploadBytes
        : photoUpload ? ProfilePictures.MaximumUploadBytes
        : SpeechSubtitleEndpoints.IsUpload(context.Request) ? SpeechSubtitleEndpoints.MaximumSubtitleBytes
        : editorPath ? 1024 * 1024 : ServerRequestGuard.MaximumJsonBytes;
    if (context.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } feature)
        feature.MaxRequestBodySize = maximumBytes;
    if (context.Request.ContentLength > maximumBytes)
    {
        context.Response.StatusCode = 413;
        context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record("request_too_large", "warning", status: 413);
        await context.Response.WriteAsJsonAsync(new ApiProblem("request_too_large", "The request is larger than the server accepts."));
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
app.UseWhen(CatalogCompression.Applies, branch => branch.UseResponseCompression());
app.Use(async (context, next) =>
{
    if (ServerUseClock.CountsAsUse(context)) context.RequestServices.GetRequiredService<ServerUseClock>().Record();
    context.RequestServices.GetRequiredService<LibraryAccessService>().Bind(context);
    try
    {
        ServerRequestGuard.RequireManagement(context, context.RequestServices.GetRequiredService<ProfileSessionStore>());
        await ServerRequestGuard.RequireApprovalAsync(context, context.RequestServices.GetRequiredService<AdministrationApprovalStore>());
        if (context.User.Identity?.IsAuthenticated == true && context.Request.Path.StartsWithSegments("/api/v1/streams"))
        {
            var limits = context.RequestServices.GetRequiredService<ServerConfigurationStore>().Current;
            using var lease = context.RequestServices.GetRequiredService<ActiveStreamRegistry>().Enter(
                context.User.RequireUserId(), context.User.RequireProfileSessionId(), limits.GlobalStreamLimit, limits.UserStreamLimit, context.RequestAborted,
                preview: ServerRequestGuard.IsPreviewStream(context.Request));
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
        if (exception.StatusCode == 429) context.Response.Headers.RetryAfter = exception.Code == "device_pairing_slow_down" ? "5" : "60";
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
    // A request body that ends early or exceeds the limit is the device's request, not the
    // server's storage: it is also an IOException, so it is answered before the storage case.
    catch (BadHttpRequestException exception) when (!context.Response.HasStarted)
    {
        context.Response.StatusCode = exception.StatusCode;
        context.RequestServices.GetRequiredService<ServerDiagnosticsStore>().Record("request_body_rejected", "warning",
            context.User.Identity?.IsAuthenticated == true ? context.User.RequireUserId() : null, exception.StatusCode);
        context.Items["Aurelia.FailureRecorded"] = true;
        await context.Response.WriteAsJsonAsync(exception.StatusCode == StatusCodes.Status413PayloadTooLarge
            ? new ApiProblem("request_too_large", "The request is larger than the server accepts.")
            : new ApiProblem("request_incomplete", "The request did not arrive completely. Try again."));
    }
    catch (IOException) when (context.RequestAborted.IsCancellationRequested)
    {
        // The device went away mid-request; nothing failed on the server.
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
app.MapServerReadiness();
app.MapMediaEditing();
app.MapImportPlanning();
app.MapSceneNotes();
app.MapProfiles();
app.MapDeviceAuthorization();
app.MapWebApp();
app.MapLiveConversion();
app.MapScrubPreviews();
app.MapRemotePlayback();
app.MapSubtitleDownloads();
app.MapSpeechSubtitles();
app.MapWatchTogether();
app.MapMovieNight();

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
            // --headless sets up a server without a screen over SSH: the password is typed twice,
            // network access is turned on for the next start and no session token is printed.
            var headless = commandLine.HasFlag("--headless");
            var password = commandLine.ReadPassword();
            if (headless && !commandLine.PasswordFromStandardInput && !Console.IsInputRedirected
                && commandLine.ReadSecret("Repeat the Server Password: ") != password)
            {
                Console.Error.WriteLine("The passwords do not match. Nothing was changed.");
                Environment.ExitCode = 1;
                return;
            }

            var response = await accounts.SetupOwnerAsync(
                new SetupOwnerRequest(
                    commandLine.Username,
                    password,
                    commandLine.DeviceName),
                CancellationToken.None);
            if (headless)
            {
                // Nobody keeps the setup session's token, so it is revoked at once.
                await accounts.RevokeOwnDeviceAsync(response.SessionId, CancellationToken.None);
                var settings = scope.ServiceProvider.GetRequiredService<ServerConfigurationStore>();
                var name = commandLine.Option("--server-name")?.Trim();
                settings.Update(settings.Current with
                {
                    LanAccessEnabled = true,
                    ServerName = string.IsNullOrEmpty(name) ? settings.Current.ServerName : name,
                }, allowNetworkChange: true);
                Console.WriteLine($"{response.User.Username} owns this server. Network access starts with the server.");
                return;
            }

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
