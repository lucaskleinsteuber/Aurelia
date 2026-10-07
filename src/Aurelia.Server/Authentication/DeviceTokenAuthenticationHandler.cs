using System.Security.Claims;
using System.Text.Encodings.Web;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
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
    SessionActivityRecorder activity)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string SchemeName = "AureliaDeviceToken";
    public const string SessionIdClaim = "aurelia_session_id";

    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var header = Request.Headers.Authorization.ToString();
        if (!header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            return AuthenticateResult.NoResult();
        }

        var rawToken = header["Bearer ".Length..].Trim();
        if (rawToken.Length is < 32 or > 256)
        {
            return AuthenticateResult.Fail("Invalid device token.");
        }

        var tokenHash = tokenService.Hash(rawToken);
        var now = DateTimeOffset.UtcNow;
        var session = await database.DeviceSessions
            .AsNoTracking()
            .Include(candidate => candidate.User)
            .SingleOrDefaultAsync(
                candidate => candidate.TokenHash == tokenHash
                    && candidate.RevokedAt == null
                    && candidate.ExpiresAt > now
                    && candidate.User.IsEnabled,
                Context.RequestAborted);

        if (session is null)
        {
            return AuthenticateResult.Fail("Invalid or expired device token.");
        }

        if (session.LastSeenAt <= now.AddMinutes(-1))
        {
            await activity.RecordAsync(database, session.Id, now, Context.RequestAborted);
        }

        var claims = new[]
        {
            new Claim(ClaimTypes.NameIdentifier, session.UserId.ToString()),
            new Claim(ClaimTypes.Name, session.User.Username),
            new Claim(ClaimTypes.Role, session.User.Role.ToString()),
            new Claim(SessionIdClaim, session.Id.ToString()),
        };
        var identity = new ClaimsIdentity(claims, SchemeName);
        var principal = new ClaimsPrincipal(identity);
        return AuthenticateResult.Success(new AuthenticationTicket(principal, SchemeName));
    }
}
