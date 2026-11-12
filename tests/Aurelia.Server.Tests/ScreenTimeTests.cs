using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>Bedtime, daily limit and today's exceptions of children's profiles (docs/SCREEN_TIME.md).</summary>
public sealed class ScreenTimeTests
{
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;
    private static readonly ScreenTimeRules Rules = new(true, ScreenTimeLockScope.PlaybackOnly, ScreenTimeEnding.FinishTitle, 30,
        new("19:30", "07:00", null), new("20:30", "08:00", null));

    // Tuesday 9.11.2027 is a school night, Friday 12.11.2027 the weekend. The days lie ahead so that tickets, which
    // the playback service stamps with the real time, were created before the test clock's bedtime.
    private static DateTimeOffset At(int day, int hour, int minute) => new(2027, 11, day, hour, minute, 0, TimeSpan.Zero);

    private static ScreenTimeStatus Evaluate(ScreenTimeRules rules, DateTimeOffset now, ScreenTimeService.DayState? day = null) =>
        ScreenTimeService.Evaluate(rules, day ?? new(), ScreenTimeService.DayOf(rules, now, Utc), now, Utc);

    [Fact]
    public void BedtimeClosesUntilTheNextWakeTime()
    {
        var open = Evaluate(Rules, At(9, 19, 0));
        Assert.Equal(ScreenTimeState.Open, open.State);
        Assert.Equal(At(9, 19, 30), open.ClosesAt);
        Assert.Equal(At(9, 20, 0), open.TitleEndsBy);

        var last = Evaluate(Rules, At(9, 19, 27));
        Assert.Equal(ScreenTimeState.LastTitle, last.State);
        Assert.Equal(ScreenTimeReason.Bedtime, last.Reason);

        var closed = Evaluate(Rules, At(9, 19, 31));
        Assert.Equal(ScreenTimeState.Closed, closed.State);
        Assert.Equal(ScreenTimeReason.Bedtime, closed.Reason);
        Assert.Equal(At(10, 7, 0), closed.OpensAt);
        Assert.Equal(At(9, 20, 0), closed.TitleEndsBy);

        // The early morning still belongs to the night before; the wake time opens it.
        Assert.Equal(new DateOnly(2027, 11, 9), ScreenTimeService.DayOf(Rules, At(10, 6, 30), Utc));
        Assert.Equal(ScreenTimeState.Closed, Evaluate(Rules, At(10, 6, 30)).State);
        Assert.Equal(ScreenTimeState.Open, Evaluate(Rules, At(10, 7, 1)).State);
    }

    [Fact]
    public void FridayAndSaturdayUseTheWeekendRules()
    {
        Assert.Equal(ScreenTimeState.Open, Evaluate(Rules, At(12, 20, 0)).State);
        Assert.Equal(ScreenTimeState.Closed, Evaluate(Rules, At(12, 20, 31)).State);
        Assert.Equal(At(13, 8, 0), Evaluate(Rules, At(12, 20, 31)).OpensAt);
        // Saturday morning before 08:00 is still Friday night.
        Assert.Equal(ScreenTimeState.Closed, Evaluate(Rules, At(13, 7, 30)).State);
    }

    [Fact]
    public void DailyLimitAndTodaysExceptions()
    {
        var limited = Rules with { SchoolNight = new(null, "07:00", 60) };
        var used = new ScreenTimeService.DayState(WatchedSeconds: 3600, LimitReachedAt: At(9, 16, 0));
        var closed = Evaluate(limited, At(9, 17, 0), used);
        Assert.Equal(ScreenTimeState.Closed, closed.State);
        Assert.Equal(ScreenTimeReason.Limit, closed.Reason);
        Assert.Equal(At(9, 16, 0), closed.ClosesAt);

        var more = Evaluate(limited, At(9, 17, 0), used with { ExtraMinutes = 30, LimitReachedAt = null });
        Assert.Equal(ScreenTimeState.Open, more.State);
        Assert.Equal(30, more.RemainingMinutes);
        Assert.Equal(At(9, 17, 30), more.ClosesAt);

        Assert.Equal(ScreenTimeState.Open, Evaluate(Rules, At(9, 21, 0), new(BedtimeLifted: true)).State);
        Assert.Equal(At(9, 20, 0), Evaluate(Rules, At(9, 19, 0), new(ExtraMinutes: 30)).ClosesAt);
        Assert.True(Evaluate(Rules, At(9, 21, 0), new(OneMoreTitleGranted: true)).OneMoreTitleAvailable);
        Assert.False(Evaluate(Rules, At(9, 21, 0), new(OneMoreTitleGranted: true, OneMoreTitleUsed: true)).OneMoreTitleAvailable);
    }

    [Fact]
    public void StopNowEndsTheTitleAtBedtime()
    {
        var closed = Evaluate(Rules with { Ending = ScreenTimeEnding.StopNow }, At(9, 19, 40));
        Assert.Equal(At(9, 19, 30), closed.TitleEndsBy);
    }

    [Fact]
    public async Task BedtimeRefusesNewTitlesButLetsTheLastOneFinish()
    {
        var clock = new SettableClock(At(9, 19, 0));
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var (first, second) = await SeedTwoTitlesAsync(factory);
        var child = await CreateChildAsync(client, owner.Token);
        await SetRulesAsync(client, owner.Token, child, Rules);

        // A children's profile cannot change its own screen time.
        var session = await UnlockAsync(client, child);
        using (var self = await SendAsync(client, session, HttpMethod.Put, $"/api/v1/users/{child}/screen-time", new UpdateProfileScreenTimeRequest(Rules with { Enabled = false }, 1)))
            Assert.Equal(HttpStatusCode.Forbidden, self.StatusCode);

        var playing = await PlaybackAsync(client, session, first);
        Assert.Equal(ScreenTimeState.Open, playing.ScreenTime!.State);

        clock.Now = At(9, 19, 40);
        using (var refused = await SendAsync(client, session, HttpMethod.Post, $"/api/v1/media/{second}/playback"))
        {
            Assert.Equal(HttpStatusCode.Forbidden, refused.StatusCode);
            Assert.Contains(ScreenTimeCodes.Bedtime, await refused.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        }
        // The title that started before bedtime streams on and may start again after a lost connection.
        using (var stream = await SendAsync(client, session, HttpMethod.Get, playing.StreamPath))
            Assert.Equal(HttpStatusCode.OK, stream.StatusCode);
        var renewed = await PlaybackAsync(client, session, first);
        Assert.Equal(ScreenTimeState.Closed, renewed.ScreenTime!.State);
        using (var renewedStream = await SendAsync(client, session, HttpMethod.Get, renewed.StreamPath))
            Assert.Equal(HttpStatusCode.OK, renewedStream.StatusCode);

        // After the overtime it ends too.
        clock.Now = At(9, 20, 1);
        using (var late = await SendAsync(client, session, HttpMethod.Get, playing.StreamPath))
            Assert.NotEqual(HttpStatusCode.OK, late.StatusCode);
        using (var lateRenewed = await SendAsync(client, session, HttpMethod.Get, renewed.StreamPath))
            Assert.NotEqual(HttpStatusCode.OK, lateRenewed.StatusCode);

        // "One more episode" allows exactly one more title.
        (await SendAsync(client, owner.Token, HttpMethod.Post, $"/api/v1/users/{child}/screen-time/today", new GrantScreenTimeRequest(OneMoreTitle: true))).EnsureSuccessStatusCode();
        var extra = await PlaybackAsync(client, session, second);
        Assert.NotNull(extra.ScreenTime!.TitleEndsBy);
        using (var again = await SendAsync(client, session, HttpMethod.Post, $"/api/v1/media/{first}/playback"))
            Assert.Equal(HttpStatusCode.Forbidden, again.StatusCode);
        using (var extraStream = await SendAsync(client, session, HttpMethod.Get, extra.StreamPath))
            Assert.Equal(HttpStatusCode.OK, extraStream.StatusCode);

        var own = await ReadAsync<OwnScreenTimeResponse>(await SendAsync(client, session, HttpMethod.Get, "/api/v1/profile/screen-time"));
        Assert.Equal(ScreenTimeState.Closed, own.Status!.State);
        Assert.Equal(At(10, 7, 0), own.Status.OpensAt);

        // Lifting bedtime opens it again for tonight.
        (await SendAsync(client, owner.Token, HttpMethod.Post, $"/api/v1/users/{child}/screen-time/today", new GrantScreenTimeRequest(LiftBedtime: true))).EnsureSuccessStatusCode();
        await PlaybackAsync(client, session, first);
    }

    [Fact]
    public async Task WholeProfileLockClosesTheProfileAtBedtime()
    {
        var clock = new SettableClock(At(9, 19, 0));
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var child = await CreateChildAsync(client, owner.Token);
        await SetRulesAsync(client, owner.Token, child, Rules with { LockScope = ScreenTimeLockScope.WholeProfile });
        var session = await UnlockAsync(client, child);

        clock.Now = At(9, 19, 45);
        var device = (await DeviceAsync(client)).Token;
        var picker = await ReadAsync<ProfilePickerResponse>(await SendAsync(client, device, HttpMethod.Get, "/api/v1/profiles"));
        Assert.Equal(At(10, 7, 0), picker.Profiles.Single(profile => profile.Id == child).ClosedUntil);
        Assert.Null(picker.Profiles.Single(profile => profile.Role == UserRole.Owner).ClosedUntil);
        using (var refused = await SendAsync(client, device, HttpMethod.Post, $"/api/v1/profiles/{child}/unlock", new UnlockProfileRequest(ApiTestClient.TestPin)))
        {
            Assert.Equal(HttpStatusCode.Forbidden, refused.StatusCode);
            Assert.Contains(ScreenTimeCodes.ProfileClosed, await refused.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        }

        // The open session ends because nothing is playing.
        await factory.Services.GetRequiredService<ScreenTimeEnforcer>().EnforceAsync(CancellationToken.None);
        using (var ended = await SendAsync(client, session, HttpMethod.Get, "/api/v1/profile/screen-time"))
            Assert.Equal(HttpStatusCode.Unauthorized, ended.StatusCode);

        // One more title opens the profile for it.
        (await SendAsync(client, owner.Token, HttpMethod.Post, $"/api/v1/users/{child}/screen-time/today", new GrantScreenTimeRequest(OneMoreTitle: true))).EnsureSuccessStatusCode();
        await UnlockAsync(client, child);
    }

    [Fact]
    public async Task WatchedTimeCountsTowardsTheDailyLimit()
    {
        var clock = new SettableClock(At(9, 15, 0));
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var (first, _) = await SeedTwoTitlesAsync(factory);
        var child = await CreateChildAsync(client, owner.Token);
        await SetRulesAsync(client, owner.Token, child, Rules with { SchoolNight = new(null, "07:00", 5) });
        var session = await UnlockAsync(client, child);

        long position = 20_000;
        (await Progress(client, session, first, position)).EnsureSuccessStatusCode();
        // A pause (the position stays) does not count.
        clock.Now = clock.Now.AddMinutes(10);
        (await Progress(client, session, first, position)).EnsureSuccessStatusCode();
        for (var minute = 0; minute < 5; minute++)
        {
            clock.Now = clock.Now.AddSeconds(60);
            position += 60_000;
            (await Progress(client, session, first, position)).EnsureSuccessStatusCode();
        }
        var own = await ReadAsync<OwnScreenTimeResponse>(await SendAsync(client, session, HttpMethod.Get, "/api/v1/profile/screen-time"));
        Assert.Equal(5, own.Status!.WatchedMinutesToday);
        Assert.Equal(ScreenTimeState.Closed, own.Status.State);
        Assert.Equal(ScreenTimeReason.Limit, own.Status.Reason);

        var screenTime = await ReadAsync<ProfileScreenTimeResponse>(await SendAsync(client, owner.Token, HttpMethod.Post,
            $"/api/v1/users/{child}/screen-time/today", new GrantScreenTimeRequest(AddMinutes: 15)));
        Assert.Equal(ScreenTimeState.Open, screenTime.Status!.State);
        Assert.Equal(15, screenTime.Today.ExtraMinutes);
    }

    [Fact]
    public async Task OnlyChildrensProfilesHaveScreenTimeAndRulesAreValidated()
    {
        using var factory = Factory(new SettableClock(At(9, 12, 0)));
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using (var ownerRules = await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{owner.User.Id}/screen-time", new UpdateProfileScreenTimeRequest(Rules, 0)))
            Assert.Equal(HttpStatusCode.BadRequest, ownerRules.StatusCode);
        var child = await CreateChildAsync(client, owner.Token);
        using (var invalid = await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{child}/screen-time",
                   new UpdateProfileScreenTimeRequest(Rules with { SchoolNight = new("25:00", "07:00", null) }, 0)))
            Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        var saved = await SetRulesAsync(client, owner.Token, child, Rules);
        using (var stale = await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{child}/screen-time", new UpdateProfileScreenTimeRequest(Rules, 0)))
            Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        Assert.Equal(1, saved.Revision);
        Assert.Equal(ScreenTimeState.Open, saved.Status!.State);
    }

    // Only screen time follows the test clock; sessions and tickets keep the real time.
    private static AureliaServerFactory Factory(SettableClock clock) => new(configureServices: services =>
    {
        services.RemoveAll<ScreenTimeService>();
        services.AddScoped(provider => new ScreenTimeService(provider.GetRequiredService<AureliaDbContext>(), clock));
    });

    private static async Task<Guid> CreateChildAsync(HttpClient client, string owner)
    {
        using var response = await SendAsync(client, owner, HttpMethod.Post, "/api/v1/users",
            new CreateUserRequest("Robin", null, UserRole.User, ApiTestClient.TestPin, AgeLimit: 6));
        response.EnsureSuccessStatusCode();
        return (await ApiTestClient.ReadAsync<UserSummary>(response)).Id;
    }

    private static async Task<ProfileScreenTimeResponse> SetRulesAsync(HttpClient client, string owner, Guid child, ScreenTimeRules rules)
    {
        var current = await ReadAsync<ProfileScreenTimeResponse>(await SendAsync(client, owner, HttpMethod.Get, $"/api/v1/users/{child}/screen-time"));
        return await ReadAsync<ProfileScreenTimeResponse>(await SendAsync(client, owner, HttpMethod.Put, $"/api/v1/users/{child}/screen-time",
            new UpdateProfileScreenTimeRequest(rules, current.Revision)));
    }

    private static async Task<PlaybackSourceResponse> PlaybackAsync(HttpClient client, string session, Guid media) =>
        await ReadAsync<PlaybackSourceResponse>(await SendAsync(client, session, HttpMethod.Post, $"/api/v1/media/{media}/playback"));

    private static Task<HttpResponseMessage> Progress(HttpClient client, string session, Guid media, long position) =>
        SendAsync(client, session, HttpMethod.Put, $"/api/v1/media/{media}/progress",
            new UpdatePlaybackProgressRequest(position, 3_600_000, false));

    private static async Task<(Guid First, Guid Second)> SeedTwoTitlesAsync(AureliaServerFactory factory)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var root = Path.Combine(factory.DataDirectory, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Synthetic family library",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Automatic,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        database.LibraryRoots.Add(library);
        var ids = new List<Guid>();
        foreach (var title in new[] { "Bright Meadow", "Paper Comet" })
        {
            var path = Path.Combine(root, Guid.NewGuid().ToString("N") + ".mkv");
            await File.WriteAllBytesAsync(path, [1, 2, 3, 4]);
            var media = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                DetectedTitle = title,
                SourcePath = path,
                NormalizedSourcePath = MediaPath.Normalize(path),
                Extension = ".mkv",
                FileSize = 4,
                FileModifiedAt = now,
                Availability = MediaAvailability.Available,
                CreatedAt = now,
                UpdatedAt = now,
            };
            media.Metadata = new MediaMetadata { MediaItemId = media.Id, UpdatedAt = now, ProviderContentRating = "FSK 0", ProviderRuntimeMinutes = 25 };
            database.MediaItems.Add(media);
            ids.Add(media.Id);
        }
        await database.SaveChangesAsync();
        return (ids[0], ids[1]);
    }

    private static async Task<AuthenticationResponse> DeviceAsync(HttpClient client)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/auth/login",
            new LoginRequest("lucas", "correct horse battery staple", "Paired synthetic device"), ApiTestClient.JsonOptions);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(response);
    }

    private static async Task<string> UnlockAsync(HttpClient client, Guid profile)
    {
        var device = (await DeviceAsync(client)).Token;
        using var response = await SendAsync(client, device, HttpMethod.Post, $"/api/v1/profiles/{profile}/unlock", new UnlockProfileRequest(ApiTestClient.TestPin));
        response.EnsureSuccessStatusCode();
        return (await ApiTestClient.ReadAsync<ProfileSessionResponse>(response)).Token;
    }

    private static async Task<HttpResponseMessage> SendAsync(HttpClient client, string token, HttpMethod method, string path, object? body = null)
    {
        using var request = ApiTestClient.Authorized(method, path, token, body);
        return await ApiTestClient.SendAsync(client, request);
    }

    private static async Task<T> ReadAsync<T>(HttpResponseMessage response)
    {
        using (response)
        {
            response.EnsureSuccessStatusCode();
            return await ApiTestClient.ReadAsync<T>(response);
        }
    }

    /// <summary>The server's clock in UTC, at a time the test sets.</summary>
    private sealed class SettableClock(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;
        public override DateTimeOffset GetUtcNow() => Now;
    }
}
