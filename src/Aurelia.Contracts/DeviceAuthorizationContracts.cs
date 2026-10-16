namespace Aurelia.Contracts;

public enum DeviceAuthorizationState
{
    Pending,
    Approved,
    Denied,
    Cancelled,
    Expired,
}

public sealed record DeviceAuthorizationStartRequest(string DeviceName);

public sealed record DeviceAuthorizationStartResponse(
    Guid Id,
    string Code,
    string Secret,
    DateTimeOffset ExpiresAt,
    int PollIntervalSeconds = 5);

public sealed record DeviceAuthorizationSecretRequest(string Secret);

public sealed record DeviceAuthorizationLookupRequest(string Code);

public sealed record DeviceAuthorizationPreview(
    Guid Id,
    string DeviceName,
    Guid ServerId,
    string ServerName,
    DeviceAuthorizationState State,
    DateTimeOffset ExpiresAt);

public sealed record DeviceAuthorizationStatusResponse(
    DeviceAuthorizationState State,
    DateTimeOffset ExpiresAt,
    int PollIntervalSeconds = 5,
    AuthenticationResponse? Authentication = null,
    bool Acknowledged = false);
