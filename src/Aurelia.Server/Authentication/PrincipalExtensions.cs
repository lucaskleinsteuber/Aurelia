using System.Security.Claims;

namespace Aurelia.Server.Authentication;

public static class PrincipalExtensions
{
    public static Guid RequireUserId(this ClaimsPrincipal principal)
    {
        return ParseRequiredGuidClaim(principal, ClaimTypes.NameIdentifier);
    }

    public static Guid RequireSessionId(this ClaimsPrincipal principal)
    {
        return ParseRequiredGuidClaim(principal, DeviceTokenAuthenticationHandler.SessionIdClaim);
    }

    private static Guid ParseRequiredGuidClaim(ClaimsPrincipal principal, string claimType)
    {
        var value = principal.FindFirstValue(claimType);
        if (!Guid.TryParse(value, out var result))
        {
            throw new InvalidOperationException("The authenticated principal is missing a required claim.");
        }

        return result;
    }
}
