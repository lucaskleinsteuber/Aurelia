using System.Net;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class HostHeaderTests
{
    // Plain HTTP exists only on the server computer's own address. A web page opened in a
    // browser on that computer can point its own name at 127.0.0.1 (DNS rebinding) and would
    // then talk to the server as if it were the computer itself; its requests carry its name.
    [Theory]
    [InlineData("evil.example")]
    [InlineData("evil.example:43110")]
    [InlineData("192.168.1.20:43110")]
    [InlineData("localhost.evil.example")]
    public async Task PlainHttpRefusesANameThatIsNotTheComputerItself(string host)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();

        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/v1/server/info");
        request.Headers.Host = host;
        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        Assert.Contains("host_not_allowed", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("localhost")]
    [InlineData("LOCALHOST:43110")]
    [InlineData("127.0.0.1:43110")]
    [InlineData("[::1]:43110")]
    public async Task PlainHttpAnswersTheComputersOwnNames(string host)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();

        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/v1/server/info");
        request.Headers.Host = host;
        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}
