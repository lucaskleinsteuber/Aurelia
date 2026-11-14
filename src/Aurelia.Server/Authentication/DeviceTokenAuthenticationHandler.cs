using System.Security.Claims;
using System.Text.Encodings.Web;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Aurelia.Contracts;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Aurelia.Server.Authentication;

public sealed class DeviceTokenAuthenticationHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder,
    AureliaDbContext database,
    TokenService tokenService,
    SessionActivityRecorder activity,
    ProfileSessionStore profiles,
    TimeProvider clock,
    ServerConfigurationStore configuration)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string SchemeName = "AureliaDeviceToken";
    public const string SessionIdClaim = "aurelia_session_id";
    public const string ProfileSessionIdClaim = "aurelia_profile_session_id";

    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var header = Request.Headers.Authorization.ToString();
        var rawToken = header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            ? header["Bearer ".Length..].Trim()
            : WebCookies.Credential(Request);
        // Integration keys for Home Assistant are checked by their own endpoints.
        if (rawToken is null || rawToken.StartsWith(Services.Automation.AutomationStore.TokenPrefix, StringComparison.Ordinal))
        {
            return AuthenticateResult.NoResult();
        }

        if (rawToken.Length is < 32 or > 256)
        {
            return AuthenticateResult.Fail("Invalid device token.");
        }

        var tokenHash = tokenService.Hash(rawToken);
        var now = clock.GetUtcNow();
        var viewing = profiles.Find(tokenHash);
        var session = await database.DeviceSessions
            .AsNoTracking()
            .Include(candidate => candidate.User)
            .SingleOrDefaultAsync(
                candidate => (viewing != null ? candidate.Id == viewing.DeviceId : candidate.TokenHash == tokenHash)
                    && candidate.RevokedAt == null
                    && candidate.ExpiresAt > now
                    && candidate.User.IsEnabled
                    && !database.DeviceAuthorizationRequests.Any(request => request.DeviceSessionId == candidate.Id
                        && request.AcknowledgedAt == null && (request.ExpiresAt <= now
                            || request.State != DeviceAuthorizationState.Approved || !configuration.Current.PairingEnabled)),
                Context.RequestAborted);

        if (session is null)
        {
            return AuthenticateResult.Fail("Invalid or expired device token.");
        }
        var user = viewing is null ? session.User : await database.Users.AsNoTracking()
            .SingleOrDefaultAsync(user => user.Id == viewing.UserId && user.IsEnabled, Context.RequestAborted);
        if (user is null) return AuthenticateResult.Fail("The profile is no longer available.");

        var client = ClientIdentity.From(Context);
        if (session.LastSeenAt <= now.AddMinutes(-1)
            || (client.IpAddress is not null && client.IpAddress != session.LastIpAddress)
            || (client.InstallationId is not null && session.InstallationId is null)
            || (client.Platform is not null && session.Platform is null))
        {
            await activity.RecordAsync(database, session.Id, now, client, Context.RequestAborted);
        }

        var claims = new List<Claim>
        {
            new Claim(ClaimTypes.NameIdentifier, user.Id.ToString()),
            new Claim(ClaimTypes.Name, user.Username),
            new Claim(SessionIdClaim, session.Id.ToString()),
            new Claim("aurelia_credential_kind", viewing is null ? "device" : "profile"),
        };
        if (viewing is not null)
        {
            claims.Add(new Claim(ClaimTypes.Role, user.Role.ToString()));
            claims.Add(new Claim(ProfileSessionIdClaim, viewing.Id.ToString()));
            claims.Add(new Claim("aurelia_access_mode", user.AccessMode.ToString()));
            if (user.AgeLimit is { } ageLimit && user.Role == UserRole.User)
                claims.Add(new Claim("aurelia_age_limit", ageLimit.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        }
        var identity = new ClaimsIdentity(claims, SchemeName);
        var principal = new ClaimsPrincipal(identity);
        return AuthenticateResult.Success(new AuthenticationTicket(principal, SchemeName));
    }
}
