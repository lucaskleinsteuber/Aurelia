namespace Aurelia.Contracts;

/// <summary>Turning the server off now ("power-now-v1"): what the owner can choose in Settings › Power.</summary>
public static class PowerNowActions
{
    public const string Sleep = "sleep";
    public const string Shutdown = "shutdown";
    public const string Stop = "stop";
}

/// <summary>What this server can do now, in the order an app offers them; empty when it can't turn itself off.</summary>
public sealed record PowerNowOptions(IReadOnlyList<string> Actions);

public sealed record PowerNowRequest(string Action, bool Force = false);

public sealed record PowerNowResponse(string Action, string Message);
