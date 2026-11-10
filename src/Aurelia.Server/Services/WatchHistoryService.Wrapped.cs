using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Wrapped: the year in review as slides with cheeky lines. Only slides with something to say
/// are shown. The lines are picked from fixed lists by the profile and the year, so they stay the
/// same every time the profile opens its year. A children's profile (one with an age limit) gets
/// the friendly lines.
/// </summary>
public sealed partial class WatchHistoryService
{
    public async Task<YearWrapped> GetWrappedAsync(Guid userId, int year, CancellationToken cancellationToken)
    {
        if (year is < 2000 or > 9998)
            throw new MetadataException("invalid_year", "Choose a year between 2000 and 9998.", StatusCodes.Status400BadRequest);
        var person = await database.Users.AsNoTracking().Where(user => user.Id == userId)
            .Select(user => new { Name = user.DisplayName ?? user.Username, user.AgeLimit })
            .FirstOrDefaultAsync(cancellationToken);
        var name = person?.Name ?? "You";
        var lines = new WrappedLines(userId, year, Gentle: person?.AgeLimit is not null);

        var zone = clock.LocalTimeZone;
        var start = new DateTimeOffset(new DateTime(year, 1, 1), zone.GetUtcOffset(new DateTime(year, 1, 1)));
        var end = new DateTimeOffset(new DateTime(year + 1, 1, 1), zone.GetUtcOffset(new DateTime(year + 1, 1, 1)));
        var events = await WatchedAsync(database.WatchEvents.AsNoTracking()
            .Where(e => e.UserId == userId && e.Timestamp >= start && e.Timestamp < end), artwork: true, cancellationToken);
        events = events.Where(e => e.SecondsWatched > 0).ToList();

        if (events.Count == 0)
        {
            return new YearWrapped(year, name,
            [
                new WrappedSlide("empty", $"{year} in Aurelia", "Nothing here yet.", null, null, null,
                    lines.Pick("empty", WrappedLines.Empty, WrappedLines.EmptyGentle).Replace("{year}", Text(year), StringComparison.Ordinal), "night"),
            ]);
        }

        var slides = new List<WrappedSlide>();
        var totalSeconds = events.Sum(e => e.SecondsWatched);
        var hours = totalSeconds / 3600.0;

        slides.Add(new WrappedSlide("intro", "Aurelia Wrapped",
            hours < 10 ? $"{year}. You pressed play. Sometimes." : $"{year}. You pressed play. A lot.",
            null, null, null, lines.Pick("intro", WrappedLines.Intro, WrappedLines.IntroGentle), "night"));

        // Hours, with something to compare them with.
        var days = totalSeconds / 86_400.0;
        var flights = (int)Math.Floor(hours / 9);
        var hoursDetail = days >= 1
            ? $"That's {Rounded(days)} days straight." + (flights >= 2 ? $" Or {flights} flights to New York, minus the legroom." : "")
            : $"{totalSeconds / 60} minutes in total.";
        slides.Add(hours >= 1
            ? new WrappedSlide("hours", "Time well spent?", "You watched for", Text((int)Math.Floor(hours)), (int)Math.Floor(hours) == 1 ? "hour" : "hours",
                hoursDetail, lines.Pick("hours", HoursTier(hours, gentle: false), HoursTier(hours, gentle: true)), "ember")
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
            slides.Add(new WrappedSlide("top-series", "Your series of the year", summary.Title, Text(series.Episodes),
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
                : new WrappedSlide("top-movie", "Your movie of the year", summary.Title, null, null,
                    summary.Year is { } released ? $"From {Text(released)}." : null,
                    lines.Pick("top-movie", WrappedLines.TopMovie, WrappedLines.TopMovieGentle), "gold",
                    movies.Movie.Id, MetadataPresentation.CardPoster(movies.Movie, summary)));
        }

        // Favorite genre, and the pet that goes with it.
        var genres = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (var watched in events)
            foreach (var genre in Genres(watched.MediaItem).Where(genre => !string.IsNullOrWhiteSpace(genre)))
                genres[genre.Trim()] = genres.GetValueOrDefault(genre.Trim()) + watched.SecondsWatched;
        var topGenre = genres.OrderByDescending(entry => entry.Value).ThenBy(entry => entry.Key, StringComparer.OrdinalIgnoreCase)
            .Select(entry => (Name: entry.Key, Seconds: entry.Value)).FirstOrDefault();
        var pet = WrappedPets.For(topGenre.Name);
        if (topGenre.Name is not null)
        {
            slides.Add(new WrappedSlide("genre", "Your genre", topGenre.Name, Text(Math.Max(1, (int)Math.Round(topGenre.Seconds / 3600.0))),
                Math.Round(topGenre.Seconds / 3600.0) <= 1 ? "hour" : "hours", null,
                lines.Pick("genre", WrappedLines.Genre, WrappedLines.GenreGentle), "rose"));
        }
        slides.Add(new WrappedSlide("pet", "Your Aurelia pet", pet.Name, null, null, lines.Gentle ? pet.Gentle : pet.Line,
            (topGenre.Name is null ? lines.Pick("pet", WrappedLines.PetNoGenre, WrappedLines.PetGentle)
                : lines.Pick("pet", WrappedLines.Pet, WrappedLines.PetGentle)).Replace("{genre}", topGenre.Name ?? "", StringComparison.Ordinal),
            "mint"));

        // The latest press of play after 23:00, or else the earliest in the morning.
        var starts = events.Select(e => (Event: e, Start: Local(e.Timestamp.AddSeconds(-e.SecondsWatched)))).ToList();
        var late = starts.Where(entry => entry.Start.Hour is >= 23 or < 5)
            .OrderByDescending(entry => (entry.Start.Hour + 1) % 24 * 60 + entry.Start.Minute).FirstOrDefault();
        if (late.Event is not null)
        {
            slides.Add(new WrappedSlide("night-owl", "Night owl", "Your latest press of play", late.Start.ToString("HH:mm", CultureInfo.InvariantCulture), null,
                $"{DisplayTitle(late.Event.MediaItem)}, on a {late.Start.DayOfWeek} in {late.Start.ToString("MMMM", CultureInfo.InvariantCulture)}.",
                lines.Pick("night-owl", WrappedLines.NightOwl, WrappedLines.NightOwlGentle), "ocean"));
        }
        else
        {
            var early = starts.Where(entry => entry.Start.Hour is >= 5 and < 9)
                .OrderBy(entry => entry.Start.Hour * 60 + entry.Start.Minute).FirstOrDefault();
            if (early.Event is not null)
                slides.Add(new WrappedSlide("early-bird", "Early bird", "Your earliest press of play", early.Start.ToString("HH:mm", CultureInfo.InvariantCulture), null,
                    $"{DisplayTitle(early.Event.MediaItem)}, on a {early.Start.DayOfWeek} in {early.Start.ToString("MMMM", CultureInfo.InvariantCulture)}.",
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

        // The busiest month and the longest run of days.
        var month = events.GroupBy(e => Local(e.Timestamp).Month)
            .Select(group => (Month: group.Key, Seconds: group.Sum(e => e.SecondsWatched)))
            .OrderByDescending(entry => entry.Seconds).ThenBy(entry => entry.Month).First();
        var monthName = CultureInfo.InvariantCulture.DateTimeFormat.GetMonthName(month.Month);
        var weekday = events.GroupBy(e => Local(e.Timestamp).DayOfWeek)
            .OrderByDescending(group => group.Sum(e => e.SecondsWatched)).ThenBy(group => group.Key).First().Key;
        var (_, longest) = CalculateStreaks(events.Select(e => Local(e.Timestamp).Date).Distinct().OrderBy(day => day).ToList(), new DateTime(year + 1, 1, 2));
        if (longest >= 2)
        {
            slides.Add(new WrappedSlide("rhythm", "Your rhythm", $"{monthName} was your month", Text(longest), "days in a row",
                $"{Rounded(month.Seconds / 3600.0)} hours in {monthName}. Favorite day: {weekday}s.",
                lines.Pick("rhythm", WrappedLines.Rhythm, WrappedLines.RhythmGentle), "ember"));
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
        var facts = new List<WrappedFact> { new("Hours", Text((int)Math.Round(hours))) };
        if (series.Series is not null) facts.Add(new("Top series", MetadataPresentation.ToSummary(series.Series).Title));
        if (movies.Movie is not null) facts.Add(new("Top movie", MetadataPresentation.ToSummary(movies.Movie).Title));
        if (topGenre.Name is not null) facts.Add(new("Genre", topGenre.Name));
        facts.Add(new("Pet", pet.Name));
        slides.Add(new WrappedSlide("summary", $"{year} in Aurelia", name, null, null, null,
            lines.Pick("summary", WrappedLines.Summary, WrappedLines.SummaryGentle), "night", Posters: posters, Facts: facts));

        return new YearWrapped(year, name, slides);
    }

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

/// <summary>Picks one line per slide, the same every time for one profile and year.</summary>
internal sealed record WrappedLines(Guid UserId, int Year, bool Gentle)
{
    public string Pick(string slide, IReadOnlyList<string> cheeky, IReadOnlyList<string> gentle)
    {
        var lines = Gentle ? gentle : cheeky;
        // A fixed FNV-1a hash: string.GetHashCode changes with every start of the server.
        var hash = 2166136261u;
        foreach (var value in UserId.ToByteArray().Concat(BitConverter.GetBytes(Year)).Concat(System.Text.Encoding.UTF8.GetBytes(slide)))
            hash = (hash ^ value) * 16777619u;
        return lines[(int)(hash % (uint)lines.Count)];
    }

    public static readonly string[] Empty =
    [
        "Your {year} is a blank page. Suspiciously clean.",
        "Zero minutes in {year}. Either you have a life, or another streaming service. We'll find out.",
    ];

    public static readonly string[] EmptyGentle = ["Watch something and come back. Your year is waiting!"];

    public static readonly string[] Intro =
    [
        "We kept receipts.",
        "Sit down. This might sting.",
        "Let's see what you've been doing on that couch.",
        "Everything you watched. Yes, everything.",
    ];

    public static readonly string[] IntroGentle = ["Ready? Here comes your year!", "Let's look at your year together!"];

    public static readonly string[] HoursTiny =
    [
        "Touching grass, are we?",
        "That's less than one season of anything. Impressive restraint, or a broken TV.",
        "You call that a year? Your couch barely knows you.",
    ];

    public static readonly string[] HoursSome =
    [
        "A healthy amount. Suspiciously healthy.",
        "Enough to have opinions. Not enough to be insufferable about them.",
        "Your couch knows your shape now. Not your best side.",
    ];

    public static readonly string[] HoursLots =
    [
        "Your couch has filed for a name change.",
        "Vitamin D called. It misses you.",
        "That's a part-time job. Unpaid. With snacks.",
    ];

    public static readonly string[] HoursHuge =
    [
        "Seek help. After the next episode.",
        "At this point the TV is watching you.",
        "Your remote has calluses. So do you.",
    ];

    public static readonly string[] HoursGentle =
    [
        "That's a lot of stories!",
        "Wow, look at all those hours of fun!",
    ];

    public static readonly string[] TopSeries =
    [
        "That's not a show anymore, that's a relationship.",
        "You spent more time with them than with your family. They know.",
        "Somewhere a writer is very proud of you. And a little worried.",
        "\"Just one more episode.\" Sure.",
    ];

    public static readonly string[] TopSeriesGentle = ["Your favorite! Great choice.", "You really love this one!"];

    public static readonly string[] Rewatch =
    [
        "We're not judging. (We are.)",
        "At this point you could do the voices. You do do the voices, don't you?",
        "Comfort movie or a cry for help? Yes.",
    ];

    public static readonly string[] RewatchGentle = ["Some movies are just that good!", "Again! Again! Again!"];

    public static readonly string[] TopMovie =
    [
        "Good taste. Or at least consistent taste.",
        "Out of everything in the library, you picked this one. Interesting.",
        "Bold choice. We'll allow it.",
    ];

    public static readonly string[] TopMovieGentle = ["What a movie!", "Great pick!"];

    public static readonly string[] Genre =
    [
        "Not a phase, apparently.",
        "Your therapist would like a word.",
        "This explains a lot, honestly.",
    ];

    public static readonly string[] GenreGentle = ["You know what you like!", "That's your favorite kind!"];

    public static readonly string[] Pet =
    [
        "Based on all that {genre}. This is science.",
        "Calculated from your {genre} habit. No refunds.",
        "This is legally binding. We checked.",
    ];

    public static readonly string[] PetNoGenre = ["Your library has no genres, so you get the default. Cats don't care."];

    public static readonly string[] PetGentle = ["A perfect match for you!", "You two would be best friends!"];

    public static readonly string[] NightOwl =
    [
        "Bold. Work was in a few hours.",
        "Nothing good happens after 2 am. Except this, apparently.",
        "Your sleep schedule called. It's crying.",
    ];

    public static readonly string[] NightOwlGentle = ["Shh, it's past bedtime!", "Staying up late? Sneaky!"];

    public static readonly string[] EarlyBird =
    [
        "Who hurt you?",
        "Before coffee? You're a menace.",
        "The sun wasn't even sure yet.",
    ];

    public static readonly string[] EarlyBirdGentle = ["Up with the sun!", "Good morning, early bird!"];

    public static readonly string[] Binge =
    [
        "Sick day or life choices?",
        "The \"Are you still watching?\" screen gave up on you.",
        "You didn't watch a show that day. You moved in.",
    ];

    public static readonly string[] BingeGentle = ["A big movie day!", "What a marathon!"];

    public static readonly string[] Rhythm =
    [
        "Consistency. Your gym would be jealous.",
        "Discipline. Just aimed at the wrong thing.",
        "If only you'd spent those days learning Spanish.",
    ];

    public static readonly string[] RhythmGentle = ["You kept it up! Nice!", "Day after day. Well done!"];

    public static readonly string[] Summary =
    [
        "See you next year. Same couch?",
        "Screenshot it. Show your friends. Let them judge.",
        "That was your year. No take-backs.",
    ];

    public static readonly string[] SummaryGentle = ["What a year! See you next time!", "Thanks for watching with Aurelia!"];
}

/// <summary>The pet that matches a genre. Genre names come from the metadata, in English or German.</summary>
internal static class WrappedPets
{
    public sealed record PetMatch(string Name, string Line, string Gentle);

    private static readonly (string[] Keys, PetMatch Pet)[] Pets =
    [
        (["horror"], new("A black cat", "It stares at empty corners at 3 am. You two will get along.", "It's a bit spooky, but very cuddly.")),
        (["science", "sci-fi"], new("A robot vacuum", "Technically a pet. Bumps into walls with total confidence.", "It beeps and boops all day long.")),
        (["comed", "komöd"], new("A golden retriever", "Laughs at everything, including you. Mostly you.", "Always happy and always ready to play.")),
        (["docu", "dokument"], new("A tortoise", "Slow, wise, and has opinions about deep-sea fish.", "Slow and steady, and very wise.")),
        (["romance", "liebe"], new("Two lovebirds", "Disgustingly cute. You know what you did.", "Two best friends who never let go.")),
        (["crime", "krimi"], new("A cat with a criminal record", "Stole a sausage in 2024. Never caught.", "A clever cat who solves every mystery.")),
        (["thriller"], new("A suspicious parrot", "Repeats everything. Trusts no one.", "A chatty parrot with lots of secrets.")),
        (["anim"], new("A hamster", "Runs all night, gets nowhere, very happy about it.", "Tiny, fluffy, and always running.")),
        (["action"], new("A pit bull in sunglasses", "Jumps off the sofa in slow motion. Every time.", "Brave and strong, and loves big jumps.")),
        (["adventure", "abenteuer"], new("A mountain goat", "Climbs things it shouldn't. Like you, onto the shed that one time.", "Climbs every hill it can find.")),
        (["fantasy"], new("A cat that's secretly a wizard", "Ignores you on purpose. It's planning something.", "A magic cat with a pointy hat.")),
        (["famil", "kids", "kinder"], new("A labrador", "Loves everyone. Eats socks.", "Loves everyone, and especially you.")),
        (["mystery"], new("An owl", "Has seen things. Won't say.", "Wise, and knows every answer.")),
        (["histor"], new("A very old parrot", "Remembers the 1800s and won't stop talking about them.", "Knows all the old stories.")),
        (["war", "krieg"], new("A bulldog", "Stubborn, loyal, snores like artillery.", "Loyal, strong, and a little grumpy.")),
        (["western"], new("A horse, obviously", "It needs a stable. You need a hobby.", "Gallops fast and loves apples.")),
        (["music", "musik"], new("A canary", "Sings in the shower. So do you, badly.", "Sings the prettiest songs.")),
        (["reality"], new("A goldfish", "Three-second memory. Perfect for reality TV.", "Swims round and round, happy as can be.")),
        (["drama"], new("A cat", "Knocks your glass off the table, looks you in the eye, feels nothing. Just like your favorite shows.", "Curls up with you for every story.")),
    ];

    private static readonly PetMatch Default = new("A cat", "Everyone gets a cat. Cats don't care what you watch.", "A cozy cat to watch with.");

    public static PetMatch For(string? genre)
    {
        if (string.IsNullOrWhiteSpace(genre)) return Default;
        var text = genre.ToLowerInvariant();
        foreach (var (keys, pet) in Pets)
            if (keys.Any(key => text.Contains(key, StringComparison.Ordinal))) return pet;
        return Default;
    }
}
