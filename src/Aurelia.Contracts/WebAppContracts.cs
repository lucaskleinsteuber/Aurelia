namespace Aurelia.Contracts;

// The browser app never receives a token: the server keeps its credentials in HttpOnly cookies,
// so these responses describe the state of a sign-in only.

public sealed record WebPairingResponse(
    string Code,
    DateTimeOffset ExpiresAt,
    int PollIntervalSeconds);

public sealed record WebPairingStatusResponse(
    DeviceAuthorizationState State,
    DateTimeOffset ExpiresAt,
    int PollIntervalSeconds);

public sealed record WebProfileResponse(
    UserSummary User,
    DateTimeOffset ExpiresAt);
