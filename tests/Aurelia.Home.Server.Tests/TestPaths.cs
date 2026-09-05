namespace Aurelia.Home.Server.Tests;

internal static class TestPaths
{
    public static string CreateDataDirectory()
    {
        var root = Environment.GetEnvironmentVariable("AURELIA_HOME_TEST_ROOT");
        if (string.IsNullOrWhiteSpace(root))
        {
            root = FindRepositoryRoot() is { } repositoryRoot
                ? Path.Combine(
                    Directory.GetParent(repositoryRoot)!.FullName,
                    "Aurelia Home Other",
                    "Test Runs")
                : Path.Combine(Path.GetTempPath(), "AureliaHomeTests");
        }

        Directory.CreateDirectory(root);
        return Path.Combine(root, Guid.NewGuid().ToString("N"));
    }

    private static string? FindRepositoryRoot()
    {
        DirectoryInfo? directory = new(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "AureliaHome.slnx")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        return null;
    }
}
