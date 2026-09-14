namespace Aurelia.Server.Tests;

internal static class TestPaths
{
    public static string CreateDataDirectory()
    {
        var root = Environment.GetEnvironmentVariable("AURELIA_TEST_ROOT");
        if (string.IsNullOrWhiteSpace(root))
        {
            root = FindRepositoryRoot() is { } repositoryRoot
                ? Path.Combine(
                    Directory.GetParent(repositoryRoot)!.FullName,
                    "Aurelia Home Other",
                    "Test Runs")
                : Path.Combine(Path.GetTempPath(), "AureliaTests");
        }

        Directory.CreateDirectory(root);
        return Path.Combine(root, Guid.NewGuid().ToString("N"));
    }

    private static string? FindRepositoryRoot()
    {
        DirectoryInfo? directory = new(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "Aurelia.slnx")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        return null;
    }
}
