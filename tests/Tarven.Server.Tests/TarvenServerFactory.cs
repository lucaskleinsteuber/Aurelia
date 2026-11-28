using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Tarven.Server.Tests;

public sealed class TarvenServerFactory : WebApplicationFactory<Program>
{
    private readonly bool ownsDataDirectory;
    private readonly Action<IServiceCollection>? configureServices;
    private readonly Action<ILoggingBuilder>? configureLogging;
    private readonly IReadOnlyDictionary<string, string>? settings;

    public TarvenServerFactory(
        string? dataDirectory = null,
        Action<IServiceCollection>? configureServices = null,
        Action<ILoggingBuilder>? configureLogging = null,
        IReadOnlyDictionary<string, string>? settings = null)
    {
        this.settings = settings;
        DataDirectory = dataDirectory ?? TestPaths.CreateDataDirectory();
        ownsDataDirectory = dataDirectory is null;
        this.configureServices = configureServices;
        this.configureLogging = configureLogging;
    }

    public string DataDirectory { get; }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("Tarven:DataDirectory", DataDirectory);
        builder.UseSetting("Tarven:ListenUrl", "http://127.0.0.1:0");
        builder.UseSetting("Tarven:BootstrapToken", ApiTestClient.BootstrapToken);
        foreach (var (key, value) in settings ?? new Dictionary<string, string>())
        {
            builder.UseSetting(key, value);
        }
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
