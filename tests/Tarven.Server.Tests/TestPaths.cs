namespace Tarven.Server.Tests;

internal static class TestPaths
{
    public static string CreateDataDirectory()
    {
        var root = Environment.GetEnvironmentVariable("TARVEN_TEST_ROOT");
        if (string.IsNullOrWhiteSpace(root))
        {
            root = Path.Combine(Path.GetTempPath(), "TarvenTests");
        }

        Directory.CreateDirectory(root);
        return Path.Combine(root, Guid.NewGuid().ToString("N"));
    }

}
