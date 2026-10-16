using Aurelia.Contracts;

namespace Aurelia.Server.Data;

public sealed class DeviceAuthorizationRequest
{
    public Guid Id { get; set; }
    public required string DeviceName { get; set; }
    public required string CodeHash { get; set; }
    public required string SecretHash { get; set; }
    public DeviceAuthorizationState State { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset? LastPolledAt { get; set; }
    public DateTimeOffset? AcknowledgedAt { get; set; }
    public Guid? DeviceSessionId { get; set; }
    public DeviceSession? DeviceSession { get; set; }
    public string? ProtectedAuthentication { get; set; }
}
