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
    public static ServerCommandLine Parse(string[] args)
    {
        var commandIndex = Array.FindIndex(args, argument =>
            argument.Equals("run", StringComparison.OrdinalIgnoreCase)
            || argument.Equals("setup-owner", StringComparison.OrdinalIgnoreCase)
            || argument.Equals("setup-browser", StringComparison.OrdinalIgnoreCase)
            || argument.Equals("library", StringComparison.OrdinalIgnoreCase)
            || argument.Equals("metadata", StringComparison.OrdinalIgnoreCase)
            || argument.Equals("pairing", StringComparison.OrdinalIgnoreCase)
            || argument.Equals("server", StringComparison.OrdinalIgnoreCase)
            || argument.Equals("move", StringComparison.OrdinalIgnoreCase)
            || argument.Equals("database", StringComparison.OrdinalIgnoreCase));
        var command = commandIndex >= 0 ? args[commandIndex].ToLowerInvariant() : "run";
        var action = command is "library" or "metadata" or "pairing" or "server" or "move" or "database"
            && commandIndex + 1 < args.Length
            && !args[commandIndex + 1].StartsWith("--", StringComparison.Ordinal)
                ? args[commandIndex + 1].ToLowerInvariant()
                : null;
        var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var flags = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var positionals = new List<string>();
        for (var index = 0; index < args.Length; index += 1)
        {
            if (!args[index].StartsWith("--", StringComparison.Ordinal))
            {
                // Words after the command and its action, such as the file of `move export FILE`.
                if (index > commandIndex + (action is null ? 0 : 1) && commandIndex >= 0) positionals.Add(args[index]);
                continue;
            }

            if (index + 1 < args.Length
                && !args[index + 1].StartsWith("--", StringComparison.Ordinal))
            {
                options[args[index]] = args[index + 1];
                index += 1;
            }
            else
            {
                flags.Add(args[index]);
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
        { Positionals = positionals };
    }

    public IReadOnlyList<string> Positionals { get; init; } = [];

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
