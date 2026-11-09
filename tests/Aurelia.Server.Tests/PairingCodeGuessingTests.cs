using Aurelia.Contracts;
using Aurelia.Server.Services;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class PairingCodeGuessingTests
{
    // The request limits count per address, and a device in the home network can use thousands
    // of addresses. A code therefore survives only a fixed number of wrong guesses in total,
    // whoever sends them.
    [Fact]
    public async Task APairingCodeEndsAfterTooManyWrongGuessesFromAnyAddress()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        var code = await CreateCodeAsync(factory, owner.User.Id);
        // The service is asked directly, as requests from ever new addresses would reach it.
        for (var guess = 0; guess < PairingCodeAttemptGuard.MaximumFailures; guess++)
        {
            var wrong = WrongCode(code, guess);
            var refused = await Assert.ThrowsAsync<AccountException>(() => RedeemAsync(factory, wrong));
            Assert.Equal("invalid_pairing_code", refused.Code);
        }

        var late = await Assert.ThrowsAsync<AccountException>(() => RedeemAsync(factory, code));
        Assert.Equal("invalid_pairing_code", late.Code);

        // A new code starts over, and a few typing mistakes do not end it.
        var next = await CreateCodeAsync(factory, owner.User.Id);
        for (var guess = 0; guess < 3; guess++)
            await Assert.ThrowsAsync<AccountException>(() => RedeemAsync(factory, WrongCode(next, guess)));
        var paired = await RedeemAsync(factory, next);
        Assert.Equal(owner.User.Id, paired.User.Id);
    }

    private static async Task<string> CreateCodeAsync(AureliaServerFactory factory, Guid ownerId)
    {
        await using var scope = factory.Services.CreateAsyncScope();
        return (await scope.ServiceProvider.GetRequiredService<AccountService>().CreatePairingCodeAsync(ownerId, default)).Code;
    }

    private static async Task<AuthenticationResponse> RedeemAsync(AureliaServerFactory factory, string code)
    {
        await using var scope = factory.Services.CreateAsyncScope();
        return await scope.ServiceProvider.GetRequiredService<AccountService>()
            .RedeemPairingCodeAsync(new RedeemPairingCodeRequest(code, "Synthetic Device"), default);
    }

    private static string WrongCode(string code, int guess) =>
        ((long.Parse(code, System.Globalization.CultureInfo.InvariantCulture) + 1 + guess) % 100_000_000)
            .ToString("D8", System.Globalization.CultureInfo.InvariantCulture);
}
