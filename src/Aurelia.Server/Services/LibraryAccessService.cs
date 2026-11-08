using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

// One request-scoped boundary. Background workers and offline migration contexts have no actor.
// EF filters use this scope before ordering, counts and pagination, including legacy services.
public sealed class LibraryAccessService(AureliaDbContext database)
{
    public void Bind(HttpContext context)
    {
        if (context.User.Identity?.IsAuthenticated != true) return;
        database.AccessUserId = context.User.RequireUserId();
        database.AccessIsOwner = context.User.IsInRole(UserRole.Owner.ToString());
        database.AccessMode = Enum.TryParse<ProfileAccessMode>(context.User.FindFirst("aurelia_access_mode")?.Value, out var mode)
            ? mode : ProfileAccessMode.LegacyLibraries;
        database.AccessAgeLimit = int.TryParse(context.User.FindFirst("aurelia_age_limit")?.Value, System.Globalization.NumberStyles.None,
            System.Globalization.CultureInfo.InvariantCulture, out var age) && AgeRatings.IsLimit(age) ? age : null;
    }

    public async Task RequireMediaAsync(Guid id, CancellationToken cancellationToken)
    {
        if (!await database.MediaItems.AnyAsync(item => item.Id == id, cancellationToken))
            throw new AccountException("media_not_found", "The media was not found.", StatusCodes.Status404NotFound);
    }
}
