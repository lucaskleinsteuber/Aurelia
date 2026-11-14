using Aurelia.Linux.Playback;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class VlcOptionsTests
{
    /// <summary>
    /// Without fast scaling a 4K HEVC title showed only every second picture on the owner's
    /// laptop (14.11.2026): the bicubic conversion on one thread took longer than a frame lasts.
    /// </summary>
    [Fact]
    public void PicturesAreScaledFast()
    {
        Assert.Contains("--swscale-mode=0", VlcEngineFactory.BaseOptions);
    }
}
