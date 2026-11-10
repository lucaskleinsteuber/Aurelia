using Aurelia.Server.Services;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ConversionFailureLogTests
{
    // ffmpeg names its input in its messages. On a Mac that is the media file's full path, which
    // the security model keeps out of logs.
    [Fact]
    public void AFailedConversionLogsFfmpegsMessageWithoutTheMediaPath()
    {
        const string path = "/Volumes/Synthetic Media/Private Folder/Synthetic Film (2020).mkv";
        var logger = new CaptureLogger();

        LiveConversionService.LogFailed(logger, "ffmpeg", 1, $"[in#0 @ 0x1] Error opening input: Invalid data\n{path}: Invalid data found when processing input", path);

        var message = Assert.Single(logger.Messages);
        Assert.DoesNotContain("Private Folder", message, StringComparison.Ordinal);
        Assert.DoesNotContain("Synthetic Film", message, StringComparison.Ordinal);
        Assert.Contains("<media>: Invalid data found when processing input", message, StringComparison.Ordinal);
    }

    private sealed class CaptureLogger : ILogger
    {
        public List<string> Messages { get; } = [];
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
            => Messages.Add(formatter(state, exception));
    }
}
