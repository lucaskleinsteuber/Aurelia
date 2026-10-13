using System.Security.Cryptography;

namespace Aurelia.Server.Services;

public sealed class AdministrationApprovalStore(TimeProvider clock, TokenService tokens, ProfileSessionStore sessions)
{
    private readonly object gate = new();
    private readonly Dictionary<string, Approval> approvals = [];
    private sealed record Approval(Guid SessionId, Guid ManagementGeneration, string Action, string PayloadHash, DateTimeOffset ExpiresAt);
    public static string Hash(ReadOnlySpan<byte> payload) => Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant();
    public (string Token, DateTimeOffset ExpiresAt) Issue(Guid sessionId, string action, string payloadHash)
    {
        var parts = action?.Split(' ', 2);
        if (action is null || action.Length is < 8 or > 250 || action.Any(char.IsControl)
            || parts is not { Length: 2 } || parts[0] is not ("POST" or "PUT" or "PATCH" or "DELETE")
            || !parts[1].StartsWith("/api/v1/", StringComparison.OrdinalIgnoreCase) || parts[1].Contains(' ')
            || payloadHash is null || payloadHash.Length != 64 || payloadHash.Any(character => !char.IsAsciiHexDigit(character)))
            throw new AccountException("invalid_approval", "Specify an API action and SHA-256 payload hash.", 400);
        lock (gate)
        {
            var now = clock.GetUtcNow();
            var management = sessions.CurrentManagementGrant(sessionId)
                ?? throw new AccountException("management_locked", "Unlock server management with the Server Password. Access lasts ten minutes.", 403);
            foreach (var key in approvals.Where(pair => pair.Value.ExpiresAt <= now).Select(pair => pair.Key).ToArray()) approvals.Remove(key);
            if (approvals.Count >= 1_000) throw new AccountException("approval_limit", "Too many pending approvals.", 429);
            var token = tokens.CreateDeviceToken();
            var expiry = now.AddMinutes(2);
            if (expiry > management.ExpiresAt) expiry = management.ExpiresAt;
            approvals.Add(tokens.Hash(token), new(sessionId, management.Generation, action, payloadHash.ToLowerInvariant(), expiry));
            return (token, expiry);
        }
    }
    public bool Consume(string token, Guid sessionId, string action, string payloadHash)
        => Consume(token, sessionId, action, payloadHash, out _);

    public bool Consume(string token, Guid sessionId, string action, string payloadHash, out Guid managementGeneration)
    {
        managementGeneration = Guid.Empty;
        if (token is null || token.Length is < 32 or > 256) return false;
        lock (gate)
        {
            // Even a mismatched attempt burns the grant. A second device cannot reuse it.
            var valid = approvals.Remove(tokens.Hash(token), out var approval) && approval.ExpiresAt > clock.GetUtcNow()
                && approval.SessionId == sessionId && approval.Action == action && approval.PayloadHash == payloadHash
                && sessions.ManagementGrantActive(sessionId, approval.ManagementGeneration);
            if (valid) managementGeneration = approval!.ManagementGeneration;
            return valid;
        }
    }
}
