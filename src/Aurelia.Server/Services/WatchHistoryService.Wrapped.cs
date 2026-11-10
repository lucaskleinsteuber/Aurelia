using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Wrapped: a year, or one month, as slides with cheeky lines. Only slides with something to say
/// are shown. The lines are picked from fixed lists by the profile and the period, so they stay
/// the same every time the profile opens it. A children's profile (one with an age limit) gets
/// the friendly lines. A month is ready from the 2nd of the following month, like a monthly
/// replay: the last evening of the month still counts.
/// </summary>
public sealed partial class WatchHistoryService
{
    public Task<YearWrapped> GetWrappedAsync(Guid userId, int year, CancellationToken cancellationToken) =>
        GetWrappedAsync(userId, year, null, cancellationToken);

    public async Task<YearWrapped> GetWrappedAsync(Guid userId, int year, int? month, CancellationToken cancellationToken)
    {
        if (year is < 2000 or > 9998)
            throw new MetadataException("invalid_year", "Choose a year between 2000 and 9998.", StatusCodes.Status400BadRequest);
        if (month is < 1 or > 12)
            throw new MetadataException("invalid_month", "Choose a month from 1 to 12.", StatusCodes.Status400BadRequest);

        var zone = clock.LocalTimeZone;
        var first = month is { } m ? new DateTime(year, m, 1) : new DateTime(year, 1, 1);
        var last = month is null ? first.AddYears(1) : first.AddMonths(1);
        var monthName = month is { } number ? CultureInfo.InvariantCulture.DateTimeFormat.GetMonthName(number) : null;
        if (month is not null && Local(clock.GetUtcNow()).DateTime < last.AddDays(1))
        {
            throw new MetadataException("wrapped_not_ready",
                $"{monthName}'s Wrapped arrives on {last.AddDays(1).ToString("d MMMM", CultureInfo.InvariantCulture)}.", StatusCodes.Status404NotFound);
        }

        var person = await database.Users.AsNoTracking().Where(user => user.Id == userId)
            .Select(user => new { Name = user.DisplayName ?? user.Username, user.AgeLimit })
            .FirstOrDefaultAsync(cancellationToken);
        var name = person?.Name ?? "You";
        var period = month is null ? "year" : "month";
        var lines = new WrappedLines(userId, month is { } key ? year * 100 + key : year, period, Gentle: person?.AgeLimit is not null);
        var title = monthName is null ? Text(year) : $"{monthName} {Text(year)}";

        var start = new DateTimeOffset(first, zone.GetUtcOffset(first));
        var end = new DateTimeOffset(last, zone.GetUtcOffset(last));
        var events = await WatchedAsync(database.WatchEvents.AsNoTracking()
            .Where(e => e.UserId == userId && e.Timestamp >= start && e.Timestamp < end), artwork: true, cancellationToken);
        events = events.Where(e => e.SecondsWatched > 0).ToList();

        if (events.Count == 0)
        {
            return new YearWrapped(year, name,
            [
                new WrappedSlide("empty", $"{title} in Aurelia", "Nothing here yet.", null, null, null,
                    lines.Pick("empty", WrappedLines.Empty, WrappedLines.EmptyGentle), "night"),
            ], month);
        }

        var slides = new List<WrappedSlide>();
        var totalSeconds = events.Sum(e => e.SecondsWatched);
        var hours = totalSeconds / 3600.0;
        // A month is a twelfth of a year, so its hours are judged like a twelfth of a year's.
        var yearlyHours = month is null ? hours : hours * 12;

        slides.Add(new WrappedSlide("intro", monthName is null ? "Aurelia Wrapped" : $"{monthName} Wrapped",
            yearlyHours < 10 ? $"{(monthName ?? Text(year))}. You pressed play. Sometimes." : $"{(monthName ?? Text(year))}. You pressed play. A lot.",
            null, null, null, lines.Pick("intro", WrappedLines.Intro, WrappedLines.IntroGentle), "night"));

        // Hours, with something to compare them with.
        var days = totalSeconds / 86_400.0;
        var flights = (int)Math.Floor(hours / 9);
        var hoursDetail = days >= 1
            ? $"That's {Rounded(days)} days straight." + (flights >= 2 ? $" Or {flights} flights to New York, minus the legroom." : "")
            : hours >= 2 ? $"That's {(int)Math.Floor(hours / 1.5)} films' worth. Or one very long nap." : $"{totalSeconds / 60} minutes in total.";
        slides.Add(hours >= 1
            ? new WrappedSlide("hours", "Time well spent?", "You watched for", Text((int)Math.Floor(hours)), (int)Math.Floor(hours) == 1 ? "hour" : "hours",
                hoursDetail, lines.Pick("hours", HoursTier(yearlyHours, gentle: false), HoursTier(yearlyHours, gentle: true)), "ember")
            : new WrappedSlide("hours", "Time well spent?", "You watched for", Text((int)Math.Max(1, totalSeconds / 60)), "minutes",
                null, lines.Pick("hours", WrappedLines.HoursTiny, WrappedLines.HoursGentle), "ember"));

        // The series with the most episodes.
        var series = events.Where(e => e.MediaItem.Kind == MediaKind.Episode && e.MediaItem.Parent is not null)
            .GroupBy(e => e.MediaItem.ParentId!.Value)
            .Select(group => (Series: group.First().MediaItem.Parent!, Episodes: group.Select(e => e.MediaItemId).Distinct().Count(),
                Seconds: group.Sum(e => e.SecondsWatched)))
            .OrderByDescending(entry => entry.Episodes).ThenByDescending(entry => entry.Seconds)
            .FirstOrDefault();
        if (series.Series is not null)
        {
            var summary = MetadataPresentation.ToSummary(series.Series);
            slides.Add(new WrappedSlide("top-series", $"Your series of the {period}", summary.Title, Text(series.Episodes),
                series.Episodes == 1 ? "episode" : "episodes", $"{Rounded(series.Seconds / 3600.0)} hours together.",
                lines.Pick("top-series", WrappedLines.TopSeries, WrappedLines.TopSeriesGentle), "violet",
                series.Series.Id, MetadataPresentation.CardPoster(series.Series, summary)));
        }

        // The film watched most often to the end, or else the one watched longest.
        var movies = events.Where(e => e.MediaItem.Kind == MediaKind.Movie)
            .GroupBy(e => e.MediaItemId)
            .Select(group => (Movie: group.First().MediaItem, Times: group.Count(e => e.IsCompleted), Seconds: group.Sum(e => e.SecondsWatched)))
            .OrderByDescending(entry => entry.Times).ThenByDescending(entry => entry.Seconds)
            .FirstOrDefault();
        if (movies.Movie is not null)
        {
            var summary = MetadataPresentation.ToSummary(movies.Movie);
            slides.Add(movies.Times >= 2
                ? new WrappedSlide("top-movie", "On repeat", summary.Title, Text(movies.Times), "times",
                    "Start to finish. Every time.", lines.Pick("top-movie", WrappedLines.Rewatch, WrappedLines.RewatchGentle), "gold",
                    movies.Movie.Id, MetadataPresentation.CardPoster(movies.Movie, summary))
                : new WrappedSlide("top-movie", $"Your movie of the {period}", summary.Title, null, null,
                    summary.Year is { } released ? $"From {Text(released)}." : null,
                    lines.Pick("top-movie", WrappedLines.TopMovie, WrappedLines.TopMovieGentle), "gold",
                    movies.Movie.Id, MetadataPresentation.CardPoster(movies.Movie, summary)));
        }

        // Favorite genre.
        var genres = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (var watched in events)
            foreach (var genre in Genres(watched.MediaItem).Where(genre => !string.IsNullOrWhiteSpace(genre)))
                genres[genre.Trim()] = genres.GetValueOrDefault(genre.Trim()) + watched.SecondsWatched;
        var topGenre = genres.OrderByDescending(entry => entry.Value).ThenBy(entry => entry.Key, StringComparer.OrdinalIgnoreCase)
            .Select(entry => (Name: entry.Key, Seconds: entry.Value)).FirstOrDefault();
        if (topGenre.Name is not null)
        {
            var genreHours = Math.Max(1, (int)Math.Round(topGenre.Seconds / 3600.0));
            slides.Add(new WrappedSlide("genre", "Your genre", topGenre.Name, Text(genreHours), genreHours == 1 ? "hour" : "hours",
                $"{(int)Math.Round(100.0 * topGenre.Seconds / Math.Max(1, totalSeconds))}% of everything you watched.",
                lines.Pick("genre", WrappedLines.Genre, WrappedLines.GenreGentle), "rose"));
        }

        // The latest press of play after 23:00, or else the earliest in the morning.
        var starts = events.Select(e => (Event: e, Start: Local(e.Timestamp.AddSeconds(-e.SecondsWatched)))).ToList();
        var late = starts.Where(entry => entry.Start.Hour is >= 23 or < 5)
            .OrderByDescending(entry => (entry.Start.Hour + 1) % 24 * 60 + entry.Start.Minute).FirstOrDefault();
        if (late.Event is not null)
        {
            slides.Add(new WrappedSlide("night-owl", "Night owl", "Your latest press of play", late.Start.ToString("HH:mm", CultureInfo.InvariantCulture), null,
                $"{DisplayTitle(late.Event.MediaItem)}, {When(late.Start)}.",
                lines.Pick("night-owl", WrappedLines.NightOwl, WrappedLines.NightOwlGentle), "ocean"));
        }
        else
        {
            var early = starts.Where(entry => entry.Start.Hour is >= 5 and < 9)
                .OrderBy(entry => entry.Start.Hour * 60 + entry.Start.Minute).FirstOrDefault();
            if (early.Event is not null)
                slides.Add(new WrappedSlide("early-bird", "Early bird", "Your earliest press of play", early.Start.ToString("HH:mm", CultureInfo.InvariantCulture), null,
                    $"{DisplayTitle(early.Event.MediaItem)}, {When(early.Start)}.",
                    lines.Pick("early-bird", WrappedLines.EarlyBird, WrappedLines.EarlyBirdGentle), "ocean"));
        }

        // The day with the most episodes.
        var binge = events.Where(e => e.MediaItem.Kind == MediaKind.Episode)
            .GroupBy(e => Local(e.Timestamp).Date)
            .Select(group => (Day: group.Key, Episodes: group.Select(e => e.MediaItemId).Distinct().Count(),
                Show: group.GroupBy(e => DisplayTitle(e.MediaItem)).OrderByDescending(show => show.Count()).First().Key))
            .OrderByDescending(entry => entry.Episodes).ThenBy(entry => entry.Day)
            .FirstOrDefault();
        if (binge.Episodes >= 3)
        {
            slides.Add(new WrappedSlide("binge", "Biggest binge", "episodes in one day", Text(binge.Episodes), null,
                $"{binge.Show}, on {binge.Day.ToString("d MMMM", CultureInfo.InvariantCulture)}.",
                lines.Pick("binge", WrappedLines.Binge, WrappedLines.BingeGentle), "lime"));
        }

        // The longest run of days, with the busiest month of a year or the favorite day of a month.
        var weekday = events.GroupBy(e => Local(e.Timestamp).DayOfWeek)
            .Select(group => (Day: group.Key, Seconds: group.Sum(e => e.SecondsWatched)))
            .OrderByDescending(entry => entry.Seconds).ThenBy(entry => entry.Day).First();
        var (_, longest) = CalculateStreaks(events.Select(e => Local(e.Timestamp).Date).Distinct().OrderBy(day => day).ToList(), last.AddDays(1));
        if (longest >= 2)
        {
            if (month is null)
            {
                var busiest = events.GroupBy(e => Local(e.Timestamp).Month)
                    .Select(group => (Month: group.Key, Seconds: group.Sum(e => e.SecondsWatched)))
                    .OrderByDescending(entry => entry.Seconds).ThenBy(entry => entry.Month).First();
                var busiestName = CultureInfo.InvariantCulture.DateTimeFormat.GetMonthName(busiest.Month);
                slides.Add(new WrappedSlide("rhythm", "Your rhythm", $"{busiestName} was your month", Text(longest), "days in a row",
                    $"{Rounded(busiest.Seconds / 3600.0)} hours in {busiestName}. Favorite day: {weekday.Day}s.",
                    lines.Pick("rhythm", WrappedLines.Rhythm, WrappedLines.RhythmGentle), "ember"));
            }
            else
            {
                slides.Add(new WrappedSlide("rhythm", "Your rhythm", $"{weekday.Day}s were your thing", Text(longest), "days in a row",
                    $"{Rounded(weekday.Seconds / 3600.0)} hours on {weekday.Day}s.",
                    lines.Pick("rhythm", WrappedLines.Rhythm, WrappedLines.RhythmGentle), "ember"));
            }
        }

        // Everything on one card.
        var posters = events
            .Select(e => e.MediaItem.Kind == MediaKind.Episode && e.MediaItem.Parent is { } parent ? parent : e.MediaItem)
            .GroupBy(item => item.Id)
            .Select(group => (Item: group.First(), Seconds: events.Where(e => e.MediaItemId == group.Key || e.MediaItem.ParentId == group.Key).Sum(e => e.SecondsWatched)))
            .OrderByDescending(entry => entry.Seconds)
            .Select(entry => MetadataPresentation.CardPoster(entry.Item, MetadataPresentation.ToSummary(entry.Item)))
            .OfType<ArtworkSummary>()
            .Take(4)
            .ToList();
        var facts = new List<WrappedFact> { new("Hours", Rounded(hours)) };
        if (series.Series is not null) facts.Add(new("Top series", MetadataPresentation.ToSummary(series.Series).Title));
        if (movies.Movie is not null) facts.Add(new("Top movie", MetadataPresentation.ToSummary(movies.Movie).Title));
        if (topGenre.Name is not null) facts.Add(new("Genre", topGenre.Name));
        if (late.Event is not null) facts.Add(new("Latest play", late.Start.ToString("HH:mm", CultureInfo.InvariantCulture)));
        slides.Add(new WrappedSlide("summary", $"{title} in Aurelia", name, null, null, null,
            lines.Pick("summary", WrappedLines.Summary, WrappedLines.SummaryGentle), "night", Posters: posters, Facts: facts));

        return new YearWrapped(year, name, slides, month);

        // "on a Tuesday in March" for a year; a month names the day itself.
        string When(DateTimeOffset moment) => month is null
            ? $"on a {moment.DayOfWeek} in {moment.ToString("MMMM", CultureInfo.InvariantCulture)}"
            : $"on {moment.DayOfWeek}, {moment.ToString("d MMMM", CultureInfo.InvariantCulture)}";
    }

    /// <param name="hours">Hours as for a whole year; a month's are multiplied by twelve first.</param>
    private static string[] HoursTier(double hours, bool gentle) =>
        gentle ? WrappedLines.HoursGentle
        : hours < 10 ? WrappedLines.HoursTiny
        : hours < 60 ? WrappedLines.HoursSome
        : hours < 250 ? WrappedLines.HoursLots
        : WrappedLines.HoursHuge;

    private static string Text(int value) => value.ToString(CultureInfo.InvariantCulture);

    private static string Rounded(double value) =>
        value >= 10 ? Math.Round(value).ToString(CultureInfo.InvariantCulture) : Math.Round(value, 1).ToString("0.#", CultureInfo.InvariantCulture);
}

/// <summary>
/// Picks one line per slide, the same every time for one profile and period (a year, or
/// year × 100 + month). "{period}" in a line becomes "year" or "month".
/// </summary>
internal sealed record WrappedLines(Guid UserId, int Period, string PeriodName, bool Gentle)
{
    public string Pick(string slide, IReadOnlyList<string> cheeky, IReadOnlyList<string> gentle)
    {
        var lines = Gentle ? gentle : cheeky;
        // A fixed FNV-1a hash: string.GetHashCode changes with every start of the server.
        var hash = 2166136261u;
        foreach (var value in UserId.ToByteArray().Concat(BitConverter.GetBytes(Period)).Concat(System.Text.Encoding.UTF8.GetBytes(slide)))
            hash = (hash ^ value) * 16777619u;
        return lines[(int)(hash % (uint)lines.Count)].Replace("{period}", PeriodName, StringComparison.Ordinal);
    }

    public static readonly string[] Empty =
    [
        "A whole {period} and not one minute. The server is hurt. Genuinely.",
        "Zero minutes. Either you have a life, or another streaming service. We'll find out which.",
        "Nothing. Are you okay? Blink twice.",
    ];

    public static readonly string[] EmptyGentle = ["Watch something and come back. Your {period} is waiting!"];

    public static readonly string[] Intro =
    [
        "We kept receipts. So many receipts.",
        "Sit down. Oh wait, you already are. That's sort of the problem.",
        "Everything you watched. Yes, that one too.",
        "Your couch asked us to do this. It needs to talk.",
        "Brace yourself. The numbers are not flattering.",
    ];

    public static readonly string[] IntroGentle = ["Ready? Here comes your {period}!", "Let's look at your {period} together!"];

    public static readonly string[] HoursTiny =
    [
        "Touching grass, are we? Disgusting.",
        "That's not watching, that's window shopping.",
        "Your couch has forgotten your face.",
        "Did you lose the remote? Blink twice.",
    ];

    public static readonly string[] HoursSome =
    [
        "Enough to have opinions. Not enough to be right about them.",
        "A healthy amount. We hate it.",
        "Average. Gloriously, aggressively average.",
    ];

    public static readonly string[] HoursLots =
    [
        "Your couch has filed for a restraining order.",
        "Vitamin D called. Straight to voicemail.",
        "That's a part-time job. Unpaid. Terrible benefits. You love it.",
        "Somewhere, a gym membership is crying.",
    ];

    public static readonly string[] HoursHuge =
    [
        "Seek help. After the next episode.",
        "At this point the TV is watching you.",
        "Your remote has calluses. So does your soul.",
        "The server needs a holiday. Because of you. Personally.",
    ];

    public static readonly string[] HoursGentle =
    [
        "That's a lot of stories!",
        "Wow, look at all those hours of fun!",
    ];

    public static readonly string[] TopSeries =
    [
        "That's not a show anymore, that's a relationship. A codependent one.",
        "You spent more time with them than with your family. Your family noticed.",
        "The writers thank you. Your sleep schedule doesn't.",
        "If this show were a person, you'd owe it rent.",
    ];

    public static readonly string[] TopSeriesGentle = ["Your favorite! Great choice.", "You really love this one!"];

    public static readonly string[] Rewatch =
    [
        "We're not judging. (We are. Heavily.)",
        "You can do all the voices now. Please don't.",
        "Comfort movie or cry for help? Yes.",
        "The actors have seen it fewer times than you.",
    ];

    public static readonly string[] RewatchGentle = ["Some movies are just that good!", "Again! Again! Again!"];

    public static readonly string[] TopMovie =
    [
        "Out of everything in the library, this. Interesting. Very interesting.",
        "Bold choice. Wrong, but bold.",
        "Good taste. Or at least consistent taste. Mostly.",
    ];

    public static readonly string[] TopMovieGentle = ["What a movie!", "Great pick!"];

    public static readonly string[] Genre =
    [
        "Not a phase, apparently.",
        "Your therapist would like a word. Several, actually.",
        "This explains a lot. Like, a lot a lot.",
        "We'd say we're surprised. We're not.",
    ];

    public static readonly string[] GenreGentle = ["You know what you like!", "That's your favorite kind!"];

    public static readonly string[] NightOwl =
    [
        "Bold. Work was in a few hours.",
        "Nothing good happens after 2 am. You proved it.",
        "Your sleep schedule filed a complaint. We forwarded it to you.",
        "Even the server was yawning.",
    ];

    public static readonly string[] NightOwlGentle = ["Shh, it's past bedtime!", "Staying up late? Sneaky!"];

    public static readonly string[] EarlyBird =
    [
        "Who hurt you?",
        "Before coffee? You're a menace to society.",
        "The sun wasn't even sure yet. You were.",
    ];

    public static readonly string[] EarlyBirdGentle = ["Up with the sun!", "Good morning, early bird!"];

    public static readonly string[] Binge =
    [
        "Sick day or life choices? Don't answer that.",
        "The \"Are you still watching?\" screen gave up on you.",
        "You didn't watch a show that day. You moved in and changed the locks.",
        "Your bladder deserves a medal.",
    ];

    public static readonly string[] BingeGentle = ["A big movie day!", "What a marathon!"];

    public static readonly string[] Rhythm =
    [
        "Consistency. Aimed at exactly the wrong thing.",
        "If only you'd spent those days learning Spanish. Or anything.",
        "Your gym would kill for this kind of commitment.",
    ];

    public static readonly string[] RhythmGentle = ["You kept it up! Nice!", "Day after day. Well done!"];

    public static readonly string[] Summary =
    [
        "See you next {period}. Same couch, obviously.",
        "Screenshot it. Send it to your friends. Let them judge you.",
        "That was your {period}. No refunds, no take-backs.",
        "Don't worry, we won't tell anyone. (We might.)",
    ];

    public static readonly string[] SummaryGentle = ["What a {period}! See you next time!", "Thanks for watching with Aurelia!"];
}
