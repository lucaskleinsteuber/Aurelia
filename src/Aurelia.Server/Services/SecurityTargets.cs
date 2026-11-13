using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>The short name a security log entry shows for its target, read before the change happens.</summary>
public static class SecurityTargets
{
    public static async Task<string?> NameAsync(HttpContext context, SecurityChange change)
    {
        if (change.TargetId is not { } id) return null;
        var database = context.RequestServices.GetRequiredService<AureliaDbContext>();
        var token = context.RequestAborted;
        return change.Target switch
        {
            SecurityTarget.Profile => await database.Users.AsNoTracking().Where(user => user.Id == id)
                .Select(user => user.DisplayName ?? user.Username).SingleOrDefaultAsync(token),
            // Only the folder's own name, never the full path.
            SecurityTarget.Library => await database.LibraryRoots.AsNoTracking().Where(library => library.Id == id)
                .Select(library => library.Name).SingleOrDefaultAsync(token),
            SecurityTarget.Title => await database.MediaItems.AsNoTracking().Where(item => item.Id == id)
                .Select(item => item.DetectedTitle).SingleOrDefaultAsync(token),
            SecurityTarget.Device => await database.DeviceSessions.AsNoTracking().Where(session => session.Id == id)
                .Select(session => session.DeviceName).SingleOrDefaultAsync(token),
            _ => null,
        };
    }

    /// <summary>What a failed attempt tried: "Profile PIN", "Server Password" or "Device code".</summary>
    public static string? Path(string? path) => path switch
    {
        null => null,
        _ when path.Contains("/unlock", StringComparison.OrdinalIgnoreCase) && path.Contains("/profiles/", StringComparison.OrdinalIgnoreCase) => "Profile PIN",
        _ when path.Contains("/management/", StringComparison.OrdinalIgnoreCase) || path.EndsWith("/auth/login", StringComparison.OrdinalIgnoreCase) => "Server Password",
        _ when path.Contains("pair", StringComparison.OrdinalIgnoreCase) => "Device code",
        _ => null,
    };
}
