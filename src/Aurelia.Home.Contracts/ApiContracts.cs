namespace Aurelia.Home.Contracts;

public enum UserRole
{
    Owner,
    Admin,
    User,
}

public sealed record HealthResponse(
    string Status,
    string Version,
    DateTimeOffset CheckedAt);

public sealed record ServerInfoResponse(
    Guid ServerId,
    string Name,
    string Version,
    bool IsSetup);

public sealed record SetupOwnerRequest(
    string Username,
    string Password,
    string DeviceName);

public sealed record LoginRequest(
    string Username,
    string Password,
    string DeviceName);

public sealed record AuthenticationResponse(
    UserSummary User,
    Guid SessionId,
    string Token,
    DateTimeOffset ExpiresAt);

public sealed record UserSummary(
    Guid Id,
    string Username,
    UserRole Role,
    DateTimeOffset CreatedAt);

public sealed record CreateUserRequest(
    string Username,
    string Password,
    UserRole Role);

public sealed record ChangeUserRoleRequest(UserRole Role);

public sealed record DeviceSessionSummary(
    Guid Id,
    Guid UserId,
    string DeviceName,
    DateTimeOffset CreatedAt,
    DateTimeOffset LastSeenAt,
    DateTimeOffset ExpiresAt,
    DateTimeOffset? RevokedAt,
    bool IsCurrent);

public sealed record CreatePairingCodeRequest;

public sealed record PairingCodeResponse(
    string Code,
    DateTimeOffset ExpiresAt);

public sealed record RedeemPairingCodeRequest(
    string Code,
    string DeviceName);

public sealed record ApiProblem(
    string Code,
    string Message);
