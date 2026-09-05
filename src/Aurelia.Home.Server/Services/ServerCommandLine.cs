using System.Text;

namespace Aurelia.Home.Server.Services;

public sealed record ServerCommandLine(
    string Command,
    string? Username,
    string DeviceName,
    bool PasswordFromStandardInput)
{
    public static ServerCommandLine Parse(string[] args)
    {
        var command = args.FirstOrDefault(argument =>
            argument.Equals("run", StringComparison.OrdinalIgnoreCase)
            || argument.Equals("setup-owner", StringComparison.OrdinalIgnoreCase)) ?? "run";

        return new ServerCommandLine(
            command.ToLowerInvariant(),
            OptionValue(args, "--username"),
            OptionValue(args, "--device-name") ?? Environment.MachineName,
            args.Contains("--password-stdin", StringComparer.OrdinalIgnoreCase));
    }

    public string ReadPassword()
    {
        if (PasswordFromStandardInput || Console.IsInputRedirected)
        {
            return Console.ReadLine() ?? string.Empty;
        }

        Console.Error.Write("Password: ");
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

    private static string? OptionValue(string[] args, string option)
    {
        for (var index = 0; index < args.Length - 1; index += 1)
        {
            if (args[index].Equals(option, StringComparison.OrdinalIgnoreCase))
            {
                return args[index + 1];
            }
        }

        return null;
    }
}
