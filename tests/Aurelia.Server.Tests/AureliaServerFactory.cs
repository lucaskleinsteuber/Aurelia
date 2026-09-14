using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Aurelia.Server.Tests;

public sealed class AureliaServerFactory : WebApplicationFactory<Program>
{
    private readonly bool ownsDataDirectory;
    private readonly Action<IServiceCollection>? configureServices;
    private readonly Action<ILoggingBuilder>? configureLogging;

    public AureliaServerFactory(
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
        builder.UseSetting("Aurelia:DataDirectory", DataDirectory);
        builder.UseSetting("Aurelia:ListenUrl", "http://127.0.0.1:0");
        builder.UseSetting("Aurelia:BootstrapToken", ApiTestClient.BootstrapToken);
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
