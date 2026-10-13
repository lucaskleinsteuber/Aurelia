namespace Aurelia.Contracts;

public sealed record UserAccessSummary(UserSummary User, bool IsEnabled, IReadOnlyList<Guid> LibraryIds);
public sealed record UpdateUserAccessRequest(bool IsEnabled, IReadOnlyList<Guid> LibraryIds);
public sealed record ResetUserPasswordRequest(string Password);
// Password is accepted only for wire compatibility. Authorization comes from the active management grant.
public sealed record AdministrationApprovalRequest(string Action, string PayloadHash, string? Password = null);
public sealed record AdministrationApprovalResponse(string Token, DateTimeOffset ExpiresAt);
