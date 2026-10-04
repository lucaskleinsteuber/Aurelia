namespace Aurelia.Server.Tests;

internal static class TestPaths
{
    public static string CreateDataDirectory()
    {
        var root = Environment.GetEnvironmentVariable("AURELIA_TEST_ROOT");
        if (string.IsNullOrWhiteSpace(root))
        {
            root = Path.Combine(Path.GetTempPath(), "AureliaTests");
        }

        Directory.CreateDirectory(root);
        return Path.Combine(root, Guid.NewGuid().ToString("N"));
    }

}
