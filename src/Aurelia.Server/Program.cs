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
using var tlsIdentity = ServerTlsIdentity.LoadOrCreate(runtime);
var dataProtectionDirectory = Path.Combine(runtime.DataDirectory, "DataProtectionKeys");
PrivateFilePermissions.CreatePrivateDirectory(dataProtectionDirectory);
builder.WebHost.UseUrls(runtime.ListenUrl);
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
    Cache = SqliteCacheMode.Shared,
    ForeignKeys = true,
    Pooling = true,
}.ToString();

builder.Services.AddSingleton(runtime);
builder.Services.AddSingleton(tlsIdentity);
builder.Services.AddSingleton<BootstrapSetupAuthorizer>();
builder.Services.AddDataProtection()
    .SetApplicationName("Aurelia.Server")
    .PersistKeysToFileSystem(new DirectoryInfo(dataProtectionDirectory));
builder.Services.AddDbContext<AureliaDbContext>(options =>
    options.UseSqlite(connectionString));
builder.Services.AddSingleton<TokenService>();
builder.Services.AddSingleton<DatabaseBackupService>();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddScoped<AccountService>();
builder.Services.AddScoped<LibraryService>();
builder.Services.AddScoped<CatalogService>();
builder.Services.AddScoped<PlaybackService>();
builder.Services.AddScoped<PlaybackProgressService>();
builder.Services.AddScoped<MetadataService>();
builder.Services.AddScoped<PresentationService>();
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
    .AddPolicy("Administrator", policy => policy.RequireRole(
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
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();
app.MapAureliaApi();

ServerInstanceLock? instanceLock = null;
try
{
    if (!app.Environment.IsEnvironment("Testing"))
    {
        instanceLock = ServerInstanceLock.Acquire(runtime.DataDirectory);
    }

    await app.Services.GetRequiredService<DatabaseBackupService>()
        .RecoverPendingRestoreAsync(CancellationToken.None);

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

public partial class Program
{
}
