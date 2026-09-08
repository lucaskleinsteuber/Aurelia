using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Aurelia.Home.Server.Tests;

public sealed class AureliaHomeServerFactory : WebApplicationFactory<Program>
{
    private readonly bool ownsDataDirectory;
    private readonly Action<IServiceCollection>? configureServices;
    private readonly Action<ILoggingBuilder>? configureLogging;

    public AureliaHomeServerFactory(
        string? dataDirectory = null,
        Action<IServiceCollection>? configureServices = null,
        Action<ILoggingBuilder>? configureLogging = null)
    {
        DataDirectory = dataDirectory ?? TestPaths.CreateDataDirectory();
        ownsDataDirectory = dataDirectory is null;
        this.configureServices = configureServices;
        this.configureLogging = configureLogging;
    }

    public string DataDirectory { get; }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("AureliaHome:DataDirectory", DataDirectory);
        builder.UseSetting("AureliaHome:ListenUrl", "http://127.0.0.1:0");
        builder.UseSetting("AureliaHome:BootstrapToken", ApiTestClient.BootstrapToken);
        builder.ConfigureLogging(logging =>
        {
            logging.SetMinimumLevel(LogLevel.Warning);
            configureLogging?.Invoke(logging);
        });
        if (configureServices is not null)
        {
            builder.ConfigureServices(configureServices);
        }
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing && ownsDataDirectory && Directory.Exists(DataDirectory))
        {
            Directory.Delete(DataDirectory, recursive: true);
        }
    }
}
