using System.Runtime.InteropServices;

namespace Aurelia.Server.Services;

public sealed record ServerRuntimeOptions(
    string DataDirectory,
    string DatabasePath,
    string ListenUrl,
    string ServerName,
    bool LanAccessEnabled,
    int LanHttpsPort,
    string CertificatePath,
    string PrivateKeyPath,
    int? HostParentProcessId)
{
    public const int DefaultLanHttpsPort = 43111;

    public static ServerRuntimeOptions Resolve(IConfiguration configuration, string[]? arguments = null)
    {
        var configuredDataDirectory = FirstNonEmpty(
            OptionValue(arguments, "--data-dir"),
            configuration["data-dir"],
            configuration["Aurelia:DataDirectory"],
            Environment.GetEnvironmentVariable("AURELIA_DATA_DIR"),
            configuration["AureliaHome:DataDirectory"],
            Environment.GetEnvironmentVariable("AURELIA_HOME_DATA_DIR"));

        var dataDirectory = Path.GetFullPath(
            configuredDataDirectory ?? DefaultDataDirectory());
        var persisted = ServerHostSettings.Load(dataDirectory);
        var localListenUrl = ValidateLocalListenUrl(FirstNonEmpty(
            OptionValue(arguments, "--urls"),
            configuration["urls"],
            configuration["Aurelia:ListenUrl"],
            Environment.GetEnvironmentVariable("AURELIA_URLS"),
            configuration["AureliaHome:ListenUrl"],
            Environment.GetEnvironmentVariable("AURELIA_HOME_URLS"))
            ?? "http://127.0.0.1:43110");
        var lanAccessEnabled = ResolveLanAccess(configuration, arguments, persisted);
        var lanHttpsPort = ParsePort(FirstNonEmpty(
            OptionValue(arguments, "--lan-port"),
            configuration["Aurelia:LanHttpsPort"],
            Environment.GetEnvironmentVariable("AURELIA_LAN_PORT"),
            configuration["AureliaHome:LanHttpsPort"],
            Environment.GetEnvironmentVariable("AURELIA_HOME_LAN_PORT"),
            persisted?.LanHttpsPort.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        var serverName = FirstNonEmpty(
            configuration["Aurelia:ServerName"],
            Environment.GetEnvironmentVariable("AURELIA_SERVER_NAME"),
            configuration["AureliaHome:ServerName"],
            Environment.GetEnvironmentVariable("AURELIA_HOME_SERVER_NAME"),
            persisted?.ServerName)
            ?? "Aurelia";
        var hostParentProcessId = ParseProcessId(FirstNonEmpty(
            OptionValue(arguments, "--host-parent-pid"),
            Environment.GetEnvironmentVariable("AURELIA_HOST_PARENT_PID")));

        var listenUrl = lanAccessEnabled
            ? $"{localListenUrl};https://*:{lanHttpsPort}"
            : localListenUrl;

        return new ServerRuntimeOptions(
            dataDirectory,
            Path.Combine(dataDirectory, "aurelia.db"),
            listenUrl,
            serverName,
            lanAccessEnabled,
            lanHttpsPort,
            Path.Combine(dataDirectory, "server-certificate.pem"),
            Path.Combine(dataDirectory, "server-private-key.pem"),
            hostParentProcessId);
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

    private static bool HasFlag(string[]? arguments, string flag)
    {
        return arguments?.Any(argument => argument.Equals(
            flag,
            StringComparison.OrdinalIgnoreCase)) == true;
    }

    private static bool ResolveLanAccess(
        IConfiguration configuration,
        string[]? arguments,
        ServerHostSettings? persisted)
    {
        if (HasFlag(arguments, "--lan"))
        {
            return true;
        }

        foreach (var value in new[]
        {
            configuration["Aurelia:LanAccessEnabled"],
            Environment.GetEnvironmentVariable("AURELIA_LAN_ENABLED"),
            configuration["AureliaHome:LanAccessEnabled"],
            Environment.GetEnvironmentVariable("AURELIA_HOME_LAN_ENABLED"),
        })
        {
            if (bool.TryParse(value, out var parsed))
            {
                return parsed;
            }
        }

        return persisted?.LanAccessEnabled == true;
    }

    private static int ParsePort(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return DefaultLanHttpsPort;
        }

        if (!int.TryParse(value, out var port) || port is < 1024 or > 65535)
        {
            throw new ArgumentException("The LAN HTTPS port must be between 1024 and 65535.");
        }

        return port;
    }

    private static int? ParseProcessId(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        if (!int.TryParse(value, out var processId) || processId <= 1)
        {
            throw new ArgumentException("The native host parent process ID is invalid.");
        }

        return processId;
    }

    private static string ValidateLocalListenUrl(string value)
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
                "The local listen URL must be a single loopback HTTP or HTTPS URL.",
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
                "Aurelia Server");
        }

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Aurelia Server");
        }

        var xdgDataHome = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
        return !string.IsNullOrWhiteSpace(xdgDataHome)
            ? Path.Combine(xdgDataHome, "aurelia")
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".local",
                "share",
                "aurelia");
    }
}

public sealed record ServerHostSettings(
    int Version,
    string ServerName,
    bool LanAccessEnabled,
    int LanHttpsPort)
{
    public const string FileName = "server-settings.json";
    private static readonly System.Text.Json.JsonSerializerOptions JsonOptions =
        new(System.Text.Json.JsonSerializerDefaults.Web);

    public static ServerHostSettings? Load(string dataDirectory)
    {
        var path = Path.Combine(dataDirectory, FileName);
        if (!File.Exists(path))
        {
            return null;
        }

        var settings = System.Text.Json.JsonSerializer.Deserialize<ServerHostSettings>(
            File.ReadAllText(path),
            JsonOptions);
        if (settings is null
            || settings.Version != 1
            || string.IsNullOrWhiteSpace(settings.ServerName)
            || settings.ServerName.Length > 128
            || settings.LanHttpsPort is < 1024 or > 65535)
        {
            throw new InvalidDataException("The server host settings file is invalid.");
        }

        return settings;
    }
}
