using Tarven.Contracts;

namespace Tarven.Linux.Core.Management;

/// <summary>Sleep, Turn Off or Stop Now for the owner in Settings › Power ("power-now-v1").</summary>
public sealed partial class ManagementClient
{
    /// <summary>
    /// What this server can do now. Servers from 2.16.0 to 2.22 listed it in their Smart Home
    /// overview ("automation-v1"), since removed.
    /// </summary>
    public async Task<IReadOnlyList<string>> PowerNowActionsAsync()
    {
        if (Library.Supports(PowerNowText.Capability))
            return (await GetAsync<PowerNowOptions>("/api/v1/server/power/now")).Actions;
        return (await GetAsync<LegacyPowerNowOptions>("/api/v1/server/automation")).PowerActions;
    }

    public Task<PowerNowResponse> PowerNowAsync(string action, bool force = false) =>
        SendAsync<PowerNowResponse>(HttpMethod.Post, "/api/v1/server/power/now", new PowerNowRequest(action, force));

    private sealed record LegacyPowerNowOptions(IReadOnlyList<string> PowerActions);
}

/// <summary>The words of Settings › Power › Right Now, the same as in the other apps.</summary>
public static class PowerNowText
{
    public const string Capability = ServerFeatures.PowerNow;
    /// <summary>The name older servers (2.16.0 to 2.22) gave the same feature, under Smart Home.</summary>
    public const string LegacyCapability = "automation-v1";

    public static bool IsOffered(Func<string, bool> supports) => supports(Capability) || supports(LegacyCapability);

    /// <summary>The actions in the server's order, without ones this app has no words for.</summary>
    public static IReadOnlyList<string> Known(IEnumerable<string> actions) =>
        actions.Where(action => action is PowerNowActions.Sleep or PowerNowActions.Shutdown or PowerNowActions.Stop).ToList();

    public static string Title(string action) => action switch
    {
        PowerNowActions.Sleep => "Sleep Now",
        PowerNowActions.Shutdown => "Turn Off Now",
        _ => "Stop Tarven Now",
    };

    public static string Detail(string action) => action switch
    {
        PowerNowActions.Sleep => "The computer sleeps; Wake-on-LAN wakes it in about 10 to 20 seconds.",
        PowerNowActions.Shutdown => "The computer turns off; Wake-on-LAN starts it in about 30 to 60 seconds.",
        _ => "Only Tarven Server stops.",
    };
}
