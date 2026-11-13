using System.Globalization;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Library;

public sealed record WishNotificationEvent(string Title, string Body);

public enum CreateWishStatus
{
    Created,
    MergedSupport,
    AlreadyInLibrary,
}

public sealed record CreateWishOutcome(
    CreateWishStatus Status,
    WishSummary? Wish = null,
    WishAlreadyInLibraryProblem? Existing = null);

/// <summary>Shared badge, validation, and notification rules for Family Wishes.</summary>
public static class WishPresentation
{
    public const int PageSize = 30;
    public const int MinimumYear = 1888;

    public static bool IsAdmin(UserSummary? user) =>
        user?.Role is UserRole.Owner or UserRole.Admin;

    public static int BadgeCount(WishSummaryResponse? summary, bool isAdmin)
    {
        if (summary is null) return 0;
        var open = Math.Max(0, summary.OpenCount);
        var fulfilled = Math.Max(0, summary.NewlyFulfilledCount);
        return isAdmin ? open + fulfilled : fulfilled;
    }

    public static int? ParseYear(string? text, out string? validationError)
    {
        var trimmed = (text ?? "").Trim();
        if (trimmed.Length == 0)
        {
            validationError = null;
            return null;
        }
        var maxYear = DateTimeOffset.UtcNow.Year + 5;
        if (!int.TryParse(trimmed, NumberStyles.None, CultureInfo.InvariantCulture, out var year)
            || year < MinimumYear
            || year > maxYear)
        {
            validationError = $"Enter a year between {MinimumYear} and {maxYear}.";
            return null;
        }
        validationError = null;
        return year;
    }

    public static string StateLabel(WishState state) => state switch
    {
        WishState.Open => "Open",
        WishState.Fulfilled => "Added",
        WishState.Declined => "Declined",
        _ => "Open",
    };

    public static string KindLabel(MediaKind kind) => kind switch
    {
        MediaKind.Series => "TV Show",
        MediaKind.Movie => "Movie",
        _ => kind.ToString(),
    };

    public static string SupportersLine(WishSummary wish)
    {
        if (wish.Supporters.Count == 0) return "";
        var names = string.Join(", ", wish.Supporters.Select(s => s.Name).Where(n => !string.IsNullOrWhiteSpace(n)));
        return names.Length > 0 ? $"Also wished by {names}" : $"{wish.Supporters.Count} also want this";
    }

    public static WishNotificationEvent? NotificationForChange(
        WishSummaryResponse? previous,
        WishSummaryResponse current,
        bool isAdmin,
        WishSummary? newestFulfilled = null,
        WishSummary? newestOpen = null)
    {
        if (previous is null) return null;

        if (current.NewlyFulfilledCount > previous.NewlyFulfilledCount)
        {
            var added = current.NewlyFulfilledCount - previous.NewlyFulfilledCount;
            var title = "Your wish is here";
            var body = newestFulfilled is not null
                ? $"{newestFulfilled.Title} is now in your library."
                : added == 1
                    ? "One of your wished titles is now in your library."
                    : $"{added} of your wished titles are now in your library.";
            return new WishNotificationEvent(title, body);
        }

        if (isAdmin && current.OpenCount > previous.OpenCount)
        {
            var title = "New family wish";
            var body = newestOpen is not null
                ? $"{newestOpen.UserName} wished for {newestOpen.Title}."
                : "Someone in your household added a wish.";
            return new WishNotificationEvent(title, body);
        }

        return null;
    }
}
