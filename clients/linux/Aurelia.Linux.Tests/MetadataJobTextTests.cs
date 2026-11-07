using Aurelia.Contracts;
using Aurelia.Linux.Core.Management;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>A finished metadata job says so in words, as on the Mac, instead of leaving a full bar.</summary>
public sealed class MetadataJobTextTests
{
    private static MetadataJobSummary Job(MetadataJobState state, int matched, int review, int skipped = 0) =>
        new(Guid.NewGuid(), null, null, state, 25, 25, matched, review, 0, null, DateTimeOffset.UtcNow, null, null, ItemsSkipped: skipped);

    [Fact]
    public void FinishedJobsAreSummarized()
    {
        Assert.Null(MetadataEditing.FinishedSummary(Job(MetadataJobState.Running, 3, 0)));
        Assert.Equal("Done · 23 matched, 2 need review", MetadataEditing.FinishedSummary(Job(MetadataJobState.Completed, 23, 2)));
        Assert.Equal("Done · 25 titles checked", MetadataEditing.FinishedSummary(Job(MetadataJobState.Completed, 0, 0)));
        Assert.Equal("Stopped · 1 matched, 1 needs review, 4 skipped", MetadataEditing.FinishedSummary(Job(MetadataJobState.Cancelled, 1, 1, 4)));
    }
}
