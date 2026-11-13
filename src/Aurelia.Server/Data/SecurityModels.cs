namespace Aurelia.Server.Data;

/// <summary>One entry of the security log (see SecurityLog). Never holds a secret or a full path.</summary>
public sealed class SecurityEvent
{
    public Guid Id { get; set; }
    public DateTimeOffset At { get; set; }
    public required string Kind { get; set; }
    public required string Outcome { get; set; }
    public Guid? UserId { get; set; }
    public string? UserName { get; set; }
    public Guid? DeviceSessionId { get; set; }
    public string? DeviceName { get; set; }
    public string? Platform { get; set; }
    public string? IpAddress { get; set; }
    public string? Detail { get; set; }
}

/// <summary>A device the owner blocked: it can't sign in or pair again until unblocked.</summary>
public sealed class BlockedDevice
{
    public Guid Id { get; set; }
    public required string InstallationId { get; set; }
    public required string DeviceName { get; set; }
    public string? Platform { get; set; }
    public string? IpAddress { get; set; }
    public DateTimeOffset BlockedAt { get; set; }
    public Guid? BlockedByUserId { get; set; }
}

/// <summary>
/// A Face ID or Touch ID key of one profile on one device. Only the public key is kept; the
/// private key never leaves the device's Secure Enclave.
/// </summary>
public sealed class ManagementPasskey
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public required ServerUser User { get; set; }
    public Guid DeviceSessionId { get; set; }
    public required DeviceSession DeviceSession { get; set; }
    public required string Name { get; set; }
    public required byte[] PublicKey { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? LastUsedAt { get; set; }
}
