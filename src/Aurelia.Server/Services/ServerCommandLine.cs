using System.Text;

namespace Aurelia.Server.Services;

public sealed record ServerCommandLine(
    string Command,
    string? Action,
    string? Username,
    string DeviceName,
    bool PasswordFromStandardInput,
    IReadOnlyDictionary<string, string> Options,
    IReadOnlySet<string> Flags)
{
    private static readonly HashSet<string> RunOptions = new(StringComparer.OrdinalIgnoreCase)
    {
        "--data-dir",
        "--urls",
        "--lan-port",
        "--host-parent-pid",
        "--lan",
        "--local-https",
        "--environment",
        "--contentRoot",
        "--webroot",
        "--applicationName",
    };

    private static readonly HashSet<string> SetupOwnerOptions = new(StringComparer.OrdinalIgnoreCase)
    {
        "--data-dir",
        "--urls",
        "--lan-port",
        "--username",
        "--device-name",
        "--password-stdin",
        "--headless",
        "--server-name",
        "--environment",
        "--contentRoot",
        "--applicationName",
    };

    private static readonly HashSet<string> SetupBrowserOptions = new(StringComparer.OrdinalIgnoreCase)
    {
        "--data-dir",
        "--urls",
        "--lan-port",
        "--server-name",
        "--environment",
        "--contentRoot",
        "--applicationName",
    };

    private static readonly HashSet<string> KnownCommands = new(StringComparer.OrdinalIgnoreCase)
    {
        "run",
        "setup-owner",
        "setup-browser",
        "library",
        "metadata",
        "pairing",
        "server",
        "move",
        "database",
        "help",
    };

    public static ServerCommandLine Parse(string[] args)
    {
        var commandIndex = Array.FindIndex(args, argument => KnownCommands.Contains(argument));
        var command = commandIndex >= 0 ? args[commandIndex].ToLowerInvariant() : "run";

        // Top-level --help / -h / --version / -v (when not targeting a subcommand that prints its own help).
        if (commandIndex < 0)
        {
            if (args.Any(argument => argument.Equals("--help", StringComparison.OrdinalIgnoreCase)
                    || argument.Equals("-h", StringComparison.OrdinalIgnoreCase)
                    || argument.Equals("-?", StringComparison.Ordinal)))
            {
                return Empty("help");
            }
            if (args.Any(argument => argument.Equals("--version", StringComparison.OrdinalIgnoreCase)
                    || argument.Equals("-v", StringComparison.Ordinal)))
            {
                return Empty("version");
            }
        }
        else if (command == "help")
        {
            return Empty("help");
        }
        else if (command is "run" or "setup-owner" or "setup-browser"
            && args.Any(argument => argument.Equals("--help", StringComparison.OrdinalIgnoreCase)
                || argument.Equals("-h", StringComparison.OrdinalIgnoreCase)))
        {
            return Empty("help");
        }

        var action = command is "library" or "metadata" or "pairing" or "server" or "move" or "database"
            && commandIndex + 1 < args.Length
            && !args[commandIndex + 1].StartsWith('-')
                ? args[commandIndex + 1].ToLowerInvariant()
                : null;
        var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var flags = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var positionals = new List<string>();
        string? error = null;

        for (var index = 0; index < args.Length; index += 1)
        {
            var token = args[index];
            if (!token.StartsWith('-'))
            {
                if (IsConfigurationAssignment(token))
                {
                    continue;
                }
                // Words after the command and its action, such as the file of `move export FILE`.
                if (commandIndex >= 0 && index > commandIndex + (action is null ? 0 : 1))
                {
                    positionals.Add(token);
                }
                else if (commandIndex < 0 && error is null)
                {
                    error = $"Unknown command: {token}. Run 'Aurelia.Server --help' for usage.";
                }
                continue;
            }

            if (token.StartsWith("--", StringComparison.Ordinal) && token.IndexOf('=') is > 2 and var equals)
            {
                options[token[..equals]] = token[(equals + 1)..];
                continue;
            }

            if (token.StartsWith("--", StringComparison.Ordinal)
                && index + 1 < args.Length
                && !args[index + 1].StartsWith('-'))
            {
                options[token] = args[index + 1];
                index += 1;
            }
            else
            {
                flags.Add(token);
            }
        }

        if (error is null && command is "run" or "setup-owner" or "setup-browser")
        {
            var allowed = command switch
            {
                "setup-owner" => SetupOwnerOptions,
                "setup-browser" => SetupBrowserOptions,
                _ => RunOptions,
            };
            foreach (var name in options.Keys.Concat(flags))
            {
                if (allowed.Contains(name) || IsConfigurationKey(name)) continue;
                error = $"Unknown option: {name}. Run 'Aurelia.Server --help' for usage.";
                break;
            }
            if (error is null && positionals.Count > 0)
            {
                error = $"Unexpected argument: {positionals[0]}. Run 'Aurelia.Server --help' for usage.";
            }
        }

        return new ServerCommandLine(
            command,
            action,
            options.GetValueOrDefault("--username"),
            options.GetValueOrDefault("--device-name") ?? Environment.MachineName,
            flags.Contains("--password-stdin"),
            options,
            flags)
        {
            Positionals = positionals,
            Error = error,
        };
    }

    private static ServerCommandLine Empty(string command) =>
        new(command, null, null, Environment.MachineName, false,
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
            new HashSet<string>(StringComparer.OrdinalIgnoreCase));

    private static bool IsConfigurationKey(string name) =>
        name.Equals("--Aurelia", StringComparison.OrdinalIgnoreCase)
        || name.StartsWith("--Aurelia:", StringComparison.OrdinalIgnoreCase)
        || name.StartsWith("--Aurelia__", StringComparison.OrdinalIgnoreCase);

    private static bool IsConfigurationAssignment(string token) =>
        token.IndexOf('=') is > 0 and var equals
        && token[..equals] is var key
        && (key.StartsWith("Aurelia:", StringComparison.OrdinalIgnoreCase)
            || key.StartsWith("Aurelia__", StringComparison.OrdinalIgnoreCase)
            || key.Equals("applicationName", StringComparison.OrdinalIgnoreCase)
            || key.Equals("environment", StringComparison.OrdinalIgnoreCase)
            || key.Equals("contentRoot", StringComparison.OrdinalIgnoreCase)
            || key.Equals("webroot", StringComparison.OrdinalIgnoreCase)
            || key.Equals("urls", StringComparison.OrdinalIgnoreCase));

    public IReadOnlyList<string> Positionals { get; init; } = [];

    public string? Error { get; init; }

    public static string UsageText =>
        """
        Usage:
          Aurelia.Server [run] [--data-dir PATH] [--urls URL] [--lan] [--lan-port PORT] [--local-https]
          Aurelia.Server setup-owner --username NAME [--data-dir PATH] [--headless] [--password-stdin] [--device-name NAME] [--server-name NAME]
          Aurelia.Server setup-browser [--data-dir PATH] [--server-name NAME]
          Aurelia.Server library <list|add|scan|remove|help> ...
          Aurelia.Server metadata <status|configure|refresh|help> ...
          Aurelia.Server pairing <create|list|revoke|help> ...
          Aurelia.Server server <identity|help> ...
          Aurelia.Server move <export|receive|status|help> ...
          Aurelia.Server database <backup|verify|restore|restore-prepared|help> ...
          Aurelia.Server --help | --version
        """;

    public string? Option(string name) => Options.GetValueOrDefault(name);

    public bool HasFlag(string name) => Flags.Contains(name);

    public string ReadPassword()
        => ReadSecret("Server Password: ");

    public string ReadSecret(string prompt)
    {
        if (PasswordFromStandardInput || Console.IsInputRedirected)
        {
            return Console.ReadLine() ?? string.Empty;
        }

        Console.Error.Write(prompt);
        var password = new StringBuilder();
        while (true)
        {
            var key = Console.ReadKey(intercept: true);
            if (key.Key == ConsoleKey.Enter)
            {
                Console.Error.WriteLine();
                return password.ToString();
            }

            if (key.Key == ConsoleKey.Backspace)
            {
                if (password.Length > 0)
                {
                    password.Length -= 1;
                }

                continue;
            }

            if (!char.IsControl(key.KeyChar))
            {
                password.Append(key.KeyChar);
            }
        }
    }

}
