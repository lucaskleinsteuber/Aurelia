using System.Security.Cryptography;

namespace Aurelia.Server.Services;

public sealed class AdministrationApprovalStore(TimeProvider clock, TokenService tokens)
{
    private readonly object gate = new();
    private readonly Dictionary<string, Approval> approvals = [];
    private sealed record Approval(Guid SessionId, string Action, string PayloadHash, DateTimeOffset ExpiresAt);
    public static string Hash(ReadOnlySpan<byte> payload) => Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant();
    public (string Token, DateTimeOffset ExpiresAt) Issue(Guid sessionId, string action, string payloadHash)
    {
        if (action is null || action.Length is < 8 or > 250 || action.Any(char.IsControl) || !action.Contains(" /api/v1/", StringComparison.Ordinal)
            || payloadHash is null || payloadHash.Length != 64 || payloadHash.Any(character => !char.IsAsciiHexDigit(character)))
            throw new AccountException("invalid_approval", "Specify an API action and SHA-256 payload hash.", 400);
        lock (gate)
        {
            var now = clock.GetUtcNow();
            foreach (var key in approvals.Where(pair => pair.Value.ExpiresAt <= now).Select(pair => pair.Key).ToArray()) approvals.Remove(key);
            if (approvals.Count >= 1_000) throw new AccountException("approval_limit", "Too many pending approvals.", 429);
            var token = tokens.CreateDeviceToken();
            var expiry = now.AddMinutes(2);
            approvals.Add(tokens.Hash(token), new(sessionId, action, payloadHash.ToLowerInvariant(), expiry));
            return (token, expiry);
        }
    }
    public bool Consume(string token, Guid sessionId, string action, string payloadHash)
    {
        if (token is null || token.Length is < 32 or > 256) return false;
        lock (gate)
        {
            // Even a mismatched attempt burns the grant. A second device cannot reuse it.
            return approvals.Remove(tokens.Hash(token), out var approval) && approval.ExpiresAt > clock.GetUtcNow()
                && approval.SessionId == sessionId && approval.Action == action && approval.PayloadHash == payloadHash;
        }
    }
}
