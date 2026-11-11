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

/// <summary>Whether this server still waits for its first owner, who can set it up in a browser.</summary>
public sealed record WebSetupStatusResponse(bool Open);

/// <summary>The setup code from the server computer, and the owner's name and Server Password.</summary>
public sealed record WebSetupRequest(string Code, string OwnerName, string Password, string DeviceName);
