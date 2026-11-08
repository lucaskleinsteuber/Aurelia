using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>Watch Together with invented profiles, devices and titles; nothing is played.</summary>
public sealed class WatchTogetherTests
{
    private static readonly Guid Film = Guid.Parse("00000000-0000-4000-8000-0000000000f1");
    private static readonly Guid NextEpisode = Guid.Parse("00000000-0000-4000-8000-0000000000f2");
    private static readonly Guid Living = Guid.NewGuid();
    private static readonly Guid Kitchen = Guid.NewGuid();

    [Fact]
    public void ThePositionRunsOnWhilePlayingAndStopsWhilePaused()
    {
        var clock = new Clock();
        var service = new WatchTogetherService(clock);
        var party = service.Create(Living, "Lucas", "Living Room TV", Film, "Invented Film", 60_000, playing: true);
        Assert.True(party.Members.Single().IsYou);
        Assert.True(party.Members.Single().IsHost);
        clock.Advance(TimeSpan.FromSeconds(10));
        var paused = service.Command(party.Id, Living, new WatchPartyCommandRequest("pause"));
        Assert.False(paused.IsPlaying);
        Assert.Equal(70_000, paused.PositionMilliseconds);
        clock.Advance(TimeSpan.FromSeconds(30));
        var seeked = service.Command(party.Id, Living, new WatchPartyCommandRequest("seek", 5_000));
        Assert.Equal(5_000, seeked.PositionMilliseconds);
        Assert.True(seeked.Revision > paused.Revision);
        Assert.Equal("seek", seeked.LastAction);
        Assert.Equal("Lucas", seeked.LastActionBy);
        Assert.Throws<PlaybackException>(() => service.Command(party.Id, Living, new WatchPartyCommandRequest("dance")));
    }

    [Fact]
    public async Task ANewMemberHoldsEveryoneAtTheSamePictureUntilItIsReady()
    {
        var clock = new Clock();
        var service = new WatchTogetherService(clock);
        var party = service.Create(Living, "Lucas", "Living Room TV", Film, "Invented Film", 0, playing: true);
        clock.Advance(TimeSpan.FromSeconds(20));
        var joined = service.Join(party.Id, Kitchen, "Mia", "Kitchen Laptop", _ => true);
        Assert.True(joined.IsWaiting);
        Assert.Equal(20_000, joined.PositionMilliseconds);
        Assert.True(joined.Members.Single(member => member.IsYou).IsBuffering);
        Assert.Equal("Lucas", service.List(_ => true, Film).Single().HostName);

        clock.Advance(TimeSpan.FromSeconds(5));
        var stillWaiting = await service.WaitAsync(party.Id, Living, null, 0, default);
        Assert.Equal(20_000, stillWaiting.PositionMilliseconds);
        var ready = service.Command(party.Id, Kitchen, new WatchPartyCommandRequest("ready"));
        Assert.False(ready.IsWaiting);
        Assert.Equal(20_000, ready.PositionMilliseconds);
        Assert.Equal(clock.GetUtcNow(), ready.UpdatedAt);

        // A device that never gets ready holds the others for at most half a minute.
        service.Command(party.Id, Kitchen, new WatchPartyCommandRequest("buffering"));
        clock.Advance(WatchTogetherService.BufferingLimit + TimeSpan.FromSeconds(1));
        var released = service.Command(party.Id, Living, new WatchPartyCommandRequest("seek", 30_000));
        Assert.False(released.IsWaiting);
    }

    [Fact]
    public async Task QuietMembersLeaveAndTheLastOneEndsTheParty()
    {
        var clock = new Clock();
        var service = new WatchTogetherService(clock);
        var party = service.Create(Living, "Lucas", null, Film, "Invented Film", 0, playing: false);
        service.Join(party.Id, Kitchen, "Mia", "Kitchen Laptop", _ => true);
        service.Command(party.Id, Kitchen, new WatchPartyCommandRequest("ready"));
        Assert.Throws<PlaybackException>(() => service.Join(party.Id, Guid.NewGuid(), "Hidden", null, _ => false));

        clock.Advance(TimeSpan.FromSeconds(30));
        await service.WaitAsync(party.Id, Kitchen, null, 0, default);
        clock.Advance(TimeSpan.FromSeconds(15));
        var alone = await service.WaitAsync(party.Id, Kitchen, null, 0, default);
        var member = Assert.Single(alone.Members);
        Assert.Equal("Mia", member.Name);
        Assert.True(member.IsHost);

        // Starting another party leaves this one, which then ends.
        service.Create(Kitchen, "Mia", null, NextEpisode, "Invented Show · S1 E2", 0, playing: true);
        Assert.Null(service.MediaOf(party.Id));
        Assert.Single(service.List(_ => true, null));
    }

    [Fact]
    public async Task ALongPollAnswersAsSoonAsSomeoneActs()
    {
        var clock = new Clock();
        var service = new WatchTogetherService(clock);
        var party = service.Create(Living, "Lucas", null, Film, "Invented Film", 0, playing: true);
        service.Join(party.Id, Kitchen, "Mia", null, _ => true);
        var current = service.Command(party.Id, Kitchen, new WatchPartyCommandRequest("ready"));
        var waiting = service.WaitAsync(party.Id, Kitchen, current.Revision, 20_000, default);
        Assert.False(waiting.IsCompleted);
        service.Command(party.Id, Living, new WatchPartyCommandRequest("pause"));
        var changed = await waiting.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(changed.IsPlaying);
        Assert.Equal("pause", changed.LastAction);
    }

    [Fact]
    public void ChangingTheTitleStartsEveryoneTogether()
    {
        var clock = new Clock();
        var service = new WatchTogetherService(clock);
        var party = service.Create(Living, "Lucas", null, Film, "Invented Film", 0, playing: true);
        service.Join(party.Id, Kitchen, "Mia", null, _ => true);
        service.Command(party.Id, Kitchen, new WatchPartyCommandRequest("ready"));
        var changed = service.Command(party.Id, Living, new WatchPartyCommandRequest("change", null, NextEpisode), "Invented Show · S1 E2");
        Assert.Equal(NextEpisode, changed.MediaId);
        Assert.Equal(0, changed.PositionMilliseconds);
        Assert.True(changed.IsWaiting);
        Assert.All(changed.Members, member => Assert.True(member.IsBuffering));
        service.Command(party.Id, Living, new WatchPartyCommandRequest("ready"));
        Assert.False(service.Command(party.Id, Kitchen, new WatchPartyCommandRequest("ready")).IsWaiting);
        Assert.Throws<PlaybackException>(() => service.Command(party.Id, Living, new WatchPartyCommandRequest("change")));
    }

    [Fact]
    public async Task TwoDevicesShareAPartyThroughTheApi()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var mediaId = await AddMovieAsync(factory);
        using var login = await ApiTestClient.LoginAsync(client, new LoginRequest("lucas", "correct horse battery staple", "Invented Kitchen Laptop"));
        var kitchen = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);

        WatchPartyState party;
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/watch-together", owner.Token,
                   new CreateWatchPartyRequest(mediaId, 42_000, true, "Invented Living Room")))
        using (var response = await ApiTestClient.SendAsync(client, request))
        {
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            party = await ApiTestClient.ReadAsync<WatchPartyState>(response);
        }
        Assert.Equal("Invented Film", party.Title);
        Assert.Equal("lucas", party.Members.Single().Name);

        using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/watch-together?mediaId={mediaId}", kitchen.Token))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal(party.Id, Assert.Single(await ApiTestClient.ReadAsync<List<WatchPartySummary>>(response)).Id);

        // Not a member yet: the party's state stays private.
        using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/watch-together/{party.Id}", kitchen.Token))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);

        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/watch-together/{party.Id}/join", kitchen.Token, new JoinWatchPartyRequest("Invented Kitchen Laptop")))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal(2, (await ApiTestClient.ReadAsync<WatchPartyState>(response)).Members.Count);
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/watch-together/{party.Id}/commands", kitchen.Token, new WatchPartyCommandRequest("ready")))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.False((await ApiTestClient.ReadAsync<WatchPartyState>(response)).IsWaiting);
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/watch-together/{party.Id}/commands", kitchen.Token, new WatchPartyCommandRequest("pause", 50_000)))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/watch-together/{party.Id}?after={party.Revision}&waitMs=1000", owner.Token))
        using (var response = await ApiTestClient.SendAsync(client, request))
        {
            var seen = await ApiTestClient.ReadAsync<WatchPartyState>(response);
            Assert.False(seen.IsPlaying);
            Assert.Equal(50_000, seen.PositionMilliseconds);
            Assert.Equal("lucas", seen.LastActionBy);
        }

        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/watch-together/{party.Id}/commands", owner.Token,
                   new WatchPartyCommandRequest("change", 0, Guid.NewGuid())))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);

        foreach (var token in new[] { kitchen.Token, owner.Token })
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/watch-together/{party.Id}/members/me", token);
            using var response = await ApiTestClient.SendAsync(client, request);
            Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        }
        using (var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/watch-together", owner.Token))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Empty(await ApiTestClient.ReadAsync<List<WatchPartySummary>>(response));
    }

    [Fact]
    public async Task AMemberNeverLearnsATitleItsProfileCannotOpen()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var shared = await AddMovieAsync(factory);
        var hidden = await AddMovieAsync(factory, "Invented Hidden Film");
        using (var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                   new CreateUserRequest("invented-child", "another correct horse password", UserRole.User, ApiTestClient.TestPin,
                       AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: [shared])))
        using (var created = await ApiTestClient.SendAsync(client, create))
            created.EnsureSuccessStatusCode();
        using var login = await ApiTestClient.LoginAsync(client, new LoginRequest("invented-child", "another correct horse password", "Invented Tablet"));
        var child = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);

        WatchPartyState party;
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/watch-together", owner.Token,
                   new CreateWatchPartyRequest(shared, 0, true, "Invented Living Room")))
        using (var response = await ApiTestClient.SendAsync(client, request))
            party = await ApiTestClient.ReadAsync<WatchPartyState>(response);
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/watch-together/{party.Id}/join", child.Token, new JoinWatchPartyRequest("Invented Tablet")))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        // The owner moves the party to a title the child's profile may not open.
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/watch-together/{party.Id}/commands", owner.Token,
                   new WatchPartyCommandRequest("change", 0, hidden)))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Equal("Invented Hidden Film", (await ApiTestClient.ReadAsync<WatchPartyState>(response)).Title);

        using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/watch-together/{party.Id}", child.Token))
        using (var response = await ApiTestClient.SendAsync(client, request))
        {
            Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
            var body = await response.Content.ReadAsStringAsync();
            Assert.Contains("party_title_unavailable", body, StringComparison.Ordinal);
            Assert.DoesNotContain("Hidden", body, StringComparison.Ordinal);
            Assert.DoesNotContain(hidden.ToString(), body, StringComparison.OrdinalIgnoreCase);
        }
        // The child left the party, so later commands see no membership and no title either.
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/watch-together/{party.Id}/commands", child.Token, new WatchPartyCommandRequest("ready")))
        using (var response = await ApiTestClient.SendAsync(client, request))
        {
            Assert.NotEqual(HttpStatusCode.OK, response.StatusCode);
            Assert.DoesNotContain("Hidden", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        }
        using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/watch-together/{party.Id}", owner.Token))
        using (var response = await ApiTestClient.SendAsync(client, request))
            Assert.Single((await ApiTestClient.ReadAsync<WatchPartyState>(response)).Members);
    }

    [Fact]
    public void WaitingForThePartyDoesNotKeepTheServerAwake()
    {
        var context = new Microsoft.AspNetCore.Http.DefaultHttpContext();
        context.User = new System.Security.Claims.ClaimsPrincipal(new System.Security.Claims.ClaimsIdentity([new System.Security.Claims.Claim("sub", "x")], "Test"));
        context.Request.Method = "GET";
        context.Request.Path = $"/api/v1/watch-together/{Guid.NewGuid()}";
        context.Request.QueryString = new Microsoft.AspNetCore.Http.QueryString("?after=3&waitMs=20000");
        Assert.False(ServerUseClock.CountsAsUse(context));
        context.Request.Method = "POST";
        context.Request.QueryString = default;
        Assert.True(ServerUseClock.CountsAsUse(context));
    }

    private static async Task<Guid> AddMovieAsync(AureliaServerFactory factory, string title = "Invented Film")
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var root = Path.Combine(factory.DataDirectory, "Invented Party Library " + title);
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Invented",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = DateTimeOffset.UtcNow,
            MonitoringEnabled = false,
        };
        var path = Path.Combine(root, title + ".mkv");
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = title,
            Category = string.Empty,
            Extension = ".mkv",
            FileSize = 1,
            FileModifiedAt = DateTimeOffset.UtcNow,
            Availability = MediaAvailability.Available,
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
        };
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        return media.Id;
    }

    private sealed class Clock : TimeProvider
    {
        private DateTimeOffset now = new(2026, 11, 7, 20, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan by) => now += by;
    }
}
