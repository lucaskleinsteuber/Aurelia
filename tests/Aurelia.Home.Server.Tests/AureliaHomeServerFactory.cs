using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Logging;

namespace Aurelia.Home.Server.Tests;

public sealed class AureliaHomeServerFactory : WebApplicationFactory<Program>
{
    private readonly bool ownsDataDirectory;

    public AureliaHomeServerFactory(string? dataDirectory = null)
    {
        DataDirectory = dataDirectory ?? TestPaths.CreateDataDirectory();
        ownsDataDirectory = dataDirectory is null;
    }

    public string DataDirectory { get; }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("AureliaHome:DataDirectory", DataDirectory);
        builder.UseSetting("AureliaHome:ListenUrl", "http://127.0.0.1:0");
        builder.ConfigureLogging(logging => logging.SetMinimumLevel(LogLevel.Warning));
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
