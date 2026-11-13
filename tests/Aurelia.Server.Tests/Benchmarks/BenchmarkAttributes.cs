using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// A benchmark: skipped in the normal test run and run by <c>scripts/test-server-benchmarks.sh</c>
/// (which sets <c>AURELIA_BENCHMARKS=1</c>), alone and one after another so the times mean something.
/// </summary>
public sealed class BenchmarkFactAttribute : FactAttribute
{
    public BenchmarkFactAttribute()
    {
        if (!BenchmarkSettings.Enabled) Skip = BenchmarkSettings.SkipReason;
    }
}

/// <inheritdoc cref="BenchmarkFactAttribute"/>
public sealed class BenchmarkTheoryAttribute : TheoryAttribute
{
    public BenchmarkTheoryAttribute()
    {
        if (!BenchmarkSettings.Enabled) Skip = BenchmarkSettings.SkipReason;
    }
}

internal static class BenchmarkSettings
{
    public const string SkipReason = "Benchmarks run with scripts/test-server-benchmarks.sh.";
    public static bool Enabled => Environment.GetEnvironmentVariable("AURELIA_BENCHMARKS") == "1";
}
