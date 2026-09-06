using System.Runtime.InteropServices;

namespace Aurelia.Home.Server.Services;

public sealed record ServerRuntimeOptions(
    string DataDirectory,
    string DatabasePath,
    string ListenUrl,
    string ServerName)
{
    public static ServerRuntimeOptions Resolve(IConfiguration configuration, string[]? arguments = null)
    {
        var configuredDataDirectory = FirstNonEmpty(
            OptionValue(arguments, "--data-dir"),
            configuration["data-dir"],
            configuration["AureliaHome:DataDirectory"],
            Environment.GetEnvironmentVariable("AURELIA_HOME_DATA_DIR"));

        var dataDirectory = Path.GetFullPath(
            configuredDataDirectory ?? DefaultDataDirectory());
        var listenUrl = ValidateListenUrl(FirstNonEmpty(
            OptionValue(arguments, "--urls"),
            configuration["urls"],
            configuration["AureliaHome:ListenUrl"],
            Environment.GetEnvironmentVariable("AURELIA_HOME_URLS"))
            ?? "http://127.0.0.1:43110");
        var serverName = FirstNonEmpty(
            configuration["AureliaHome:ServerName"],
            Environment.GetEnvironmentVariable("AURELIA_HOME_SERVER_NAME"))
            ?? "Aurelia Home";

        return new ServerRuntimeOptions(
            dataDirectory,
            Path.Combine(dataDirectory, "aurelia-home.db"),
            listenUrl,
            serverName);
    }

    private static string? FirstNonEmpty(params string?[] values)
    {
        return values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
    }

    private static string? OptionValue(string[]? arguments, string option)
    {
        if (arguments is null)
        {
            return null;
        }

        for (var index = 0; index < arguments.Length - 1; index += 1)
        {
            if (arguments[index].Equals(option, StringComparison.OrdinalIgnoreCase))
            {
                return arguments[index + 1];
            }
        }

        return null;
    }

    private static string ValidateListenUrl(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || uri.Scheme is not ("http" or "https")
            || !uri.IsLoopback
            || !string.IsNullOrEmpty(uri.UserInfo)
            || uri.AbsolutePath != "/"
            || !string.IsNullOrEmpty(uri.Query)
            || !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new ArgumentException(
                "Build 3 only accepts a single loopback HTTP or HTTPS listen URL.",
                nameof(value));
        }

        return value;
    }

    private static string DefaultDataDirectory()
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "Library",
                "Application Support",
                "Aurelia Home Server");
        }

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Aurelia Home Server");
        }

        var xdgDataHome = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
        return !string.IsNullOrWhiteSpace(xdgDataHome)
            ? Path.Combine(xdgDataHome, "aurelia-home")
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".local",
                "share",
                "aurelia-home");
    }
}
