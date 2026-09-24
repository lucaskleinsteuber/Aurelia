using Microsoft.Data.Sqlite;

namespace Aurelia.Server.Services;

public static class DatabaseCommandClient
{
    public static async Task<int> RunAsync(
        ServerCommandLine commandLine,
        ServerRuntimeOptions runtime,
        CancellationToken cancellationToken)
    {
        if (commandLine.Action is "help" or "--help" || commandLine.HasFlag("--help"))
        {
            PrintUsage();
            return 0;
        }

        var backups = new DatabaseBackupService(runtime);
        try
        {
            switch (commandLine.Action)
            {
                case "backup":
                    {
                        var path = await backups.CreateBackupAsync(
                            DatabaseBackupKind.Manual,
                            cancellationToken);
                        Console.WriteLine($"Verified backup created: {path}");
                        return 0;
                    }
                case "verify":
                    {
                        var path = commandLine.Option("--from") ?? runtime.DatabasePath;
                        var result = await backups.VerifyAsync(path, cancellationToken);
                        Console.WriteLine(result.Message);
                        if (result.IsValid)
                        {
                            Console.WriteLine($"Applied migrations: {result.AppliedMigrationCount}");
                        }

                        return result.IsValid ? 0 : 1;
                    }
                case "restore":
                    {
                        var path = commandLine.Option("--from");
                        if (string.IsNullOrWhiteSpace(path))
                        {
                            Console.Error.WriteLine("database restore requires --from <path>.");
                            PrintUsage();
                            return 2;
                        }

                        if (!commandLine.HasFlag("--confirm"))
                        {
                            Console.Error.WriteLine(
                                "Restore was not started. Stop Aurelia Server and repeat with --confirm after checking the source.");
                            return 2;
                        }

                        using var instanceLock = ServerInstanceLock.Acquire(runtime.DataDirectory);
                        await backups.RestoreAsync(path, cancellationToken);
                        Console.WriteLine("Database restore verified. Start Aurelia Server to apply any required migrations.");
                        return 0;
                    }
                default:
                    PrintUsage();
                    return 2;
            }
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or InvalidOperationException
            or ArgumentException
            or SqliteException)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    private static void PrintUsage()
    {
        Console.WriteLine("Aurelia database commands:");
        Console.WriteLine("  database backup");
        Console.WriteLine("  database verify [--from <database-or-backup-path>]");
        Console.WriteLine("  database restore --from <backup-path> --confirm");
        Console.WriteLine("  Add --data-dir <path> to select the Aurelia Server data directory.");
        Console.WriteLine("  Restore requires Aurelia Server to be stopped; automatic rollback is never performed.");
    }
}
