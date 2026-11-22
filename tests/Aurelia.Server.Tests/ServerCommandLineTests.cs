using System.Diagnostics;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerCommandLineTests
{
    [Theory]
    [InlineData("--help")]
    [InlineData("-h")]
    [InlineData("-?")]
    [InlineData("help")]
    public void HelpArgumentsSelectHelpCommandWithoutError(string argument)
    {
        var parsed = ServerCommandLine.Parse([argument]);
        Assert.Equal("help", parsed.Command);
        Assert.Null(parsed.Error);
    }

    [Theory]
    [InlineData("--version")]
    [InlineData("-v")]
    public void VersionArgumentsSelectVersionCommandWithoutError(string argument)
    {
        var parsed = ServerCommandLine.Parse([argument]);
        Assert.Equal("version", parsed.Command);
        Assert.Null(parsed.Error);
    }

    [Theory]
    [InlineData("--unknown")]
    [InlineData("--bogus=1")]
    [InlineData("-z")]
    [InlineData("not-a-command")]
    public void UnknownArgumentsProduceAnErrorInsteadOfStartingTheServer(string argument)
    {
        var parsed = ServerCommandLine.Parse([argument]);
        Assert.NotNull(parsed.Error);
    }

    [Fact]
    public void ValidRunAndSubcommandInvocationsAreAccepted()
    {
        var run = ServerCommandLine.Parse(["run", "--data-dir", "/tmp/a", "--urls", "http://127.0.0.1:48000", "--lan", "--lan-port", "48001", "--local-https", "--host-parent-pid", "123"]);
        Assert.Equal("run", run.Command);
        Assert.Null(run.Error);

        var setup = ServerCommandLine.Parse(["setup-owner", "--headless", "--data-dir", "/tmp/a", "--username", "owner", "--device-name", "dev", "--password-stdin"]);
        Assert.Equal("setup-owner", setup.Command);
        Assert.Null(setup.Error);

        var libraryHelp = ServerCommandLine.Parse(["library", "--help"]);
        Assert.Equal("library", libraryHelp.Command);
        Assert.True(libraryHelp.HasFlag("--help"));
        Assert.Null(libraryHelp.Error);
    }

    [Fact]
    public async Task RunningServerBinaryWithHelpOrUnknownOptionExitsWithoutCreatingDataDirectory()
    {
        var serverDll = typeof(ServerCommandLine).Assembly.Location;
        var isolatedData = Path.Combine(TestPaths.CreateDataDirectory(), "MustNotExist");
        try
        {
            var help = await RunServerCliAsync(serverDll, isolatedData, ["--help"]);
            Assert.Equal(0, help.ExitCode);
            Assert.Contains("Usage:", help.Stdout, StringComparison.Ordinal);
            Assert.False(Directory.Exists(isolatedData), "Running --help must not create a data directory.");

            var version = await RunServerCliAsync(serverDll, isolatedData, ["--version"]);
            Assert.Equal(0, version.ExitCode);
            Assert.Contains("Aurelia Server", version.Stdout, StringComparison.Ordinal);
            Assert.False(Directory.Exists(isolatedData), "Running --version must not create a data directory.");

            var bad = await RunServerCliAsync(serverDll, isolatedData, ["--not-a-real-option"]);
            Assert.Equal(2, bad.ExitCode);
            Assert.Contains("Unknown option", bad.Stderr, StringComparison.Ordinal);
            Assert.False(Directory.Exists(isolatedData), "Running with an unknown option must not create a data directory.");
        }
        finally
        {
            var parent = Path.GetDirectoryName(isolatedData);
            if (parent is not null && Directory.Exists(parent)) Directory.Delete(parent, recursive: true);
        }
    }

    private static async Task<(int ExitCode, string Stdout, string Stderr)> RunServerCliAsync(string serverDll, string isolatedDataDir, string[] args)
    {
        var dotnet = Environment.ProcessPath ?? "dotnet";
        var start = new ProcessStartInfo(dotnet)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        start.ArgumentList.Add(serverDll);
        foreach (var arg in args) start.ArgumentList.Add(arg);
        start.Environment["AURELIA_DATA_DIR"] = isolatedDataDir;
        start.Environment["AURELIA_LAN_ENABLED"] = "false";
        using var process = Process.Start(start)!;
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        await process.WaitForExitAsync(timeout.Token);
        return (process.ExitCode, await stdout, await stderr);
    }
}
