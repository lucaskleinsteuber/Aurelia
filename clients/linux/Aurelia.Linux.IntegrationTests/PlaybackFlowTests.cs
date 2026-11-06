using System.Net.Http.Headers;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.IntegrationTests;

/// <summary>
/// The player's server side against the real server and the synthetic one-byte library: tickets,
/// the relay, progress, scene notes, subtitles and Play On. Nothing is decoded or played.
/// </summary>
public sealed class PlaybackFlowTests : IDisposable
{
    private readonly RealServer server = new();
    private readonly AureliaApi api;

    public PlaybackFlowTests() => api = new AureliaApi(server.Transport);

    public void Dispose()
    {
        api.Dispose();
        server.Dispose();
    }

    private async Task<(PlaybackClient Client, LibraryStore Store)> OpenAsync()
    {
        var (device, opened) = await server.SeedLibraryAsync();
        var inspected = await api.InspectAsync(RealServer.Address, TestContext.Current.CancellationToken);
        var stored = new StoredServer(inspected.Info.ServerId, inspected.Info.Name, inspected.Address, inspected.Fingerprint,
            device.Token, device.SessionId, device.ExpiresAt, device.User);
        var library = new LibraryClient(api, stored, new ProfileSession(opened.User, opened.SessionId, opened.Token, opened.ExpiresAt), inspected.Info.Capabilities ?? []);
        var store = new LibraryStore(library, new ArtworkCache(null), new GeneralPreferences(new MemorySettingsStore()), _ => { });
        await store.RefreshAsync();
        return (new PlaybackClient(api, library), store);
    }

    [Fact]
    public async Task StreamsThroughTheRelayWithoutTheTokenReachingTheDecoder()
    {
        var (client, store) = await OpenAsync();
        var movie = store.Catalog.First(item => item.Kind == MediaKind.Movie);
        var ticket = await client.StartAsync(movie.Id, TestContext.Current.CancellationToken);
        Assert.StartsWith("/api/v1/streams/", ticket.StreamPath, StringComparison.Ordinal);
        Assert.True(ticket.ExpiresAt > DateTimeOffset.UtcNow);

        await using var relay = new LoopbackStreamRelay(client.StreamConnection, client.StreamToken, client.StreamUri(ticket));
        var local = relay.Start();
        Assert.Equal("127.0.0.1", local.Host);
        Assert.DoesNotContain(client.StreamToken, local.ToString(), StringComparison.Ordinal);

        using var decoder = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, local);
        request.Headers.Range = new RangeHeaderValue(0, 0);
        using var response = await decoder.SendAsync(request, TestContext.Current.CancellationToken);
        Assert.True(response.IsSuccessStatusCode, $"Relay answered {(int)response.StatusCode}");
        Assert.Single(await response.Content.ReadAsByteArrayAsync(TestContext.Current.CancellationToken));

        using var wrongPath = await decoder.GetAsync(new Uri(local, "/stream/not-the-secret"), TestContext.Current.CancellationToken);
        Assert.Equal(400, (int)wrongPath.StatusCode);

        var subtitles = await client.SubtitlesAsync(ticket, TestContext.Current.CancellationToken);
        Assert.True(Assert.Single(subtitles).IsSidecar);
        await client.RevokeAsync(ticket.Id, TestContext.Current.CancellationToken);
    }

    [Fact]
    public async Task SavesProgressWithRevisionsAndReportsAConflict()
    {
        var (client, store) = await OpenAsync();
        var movie = store.Catalog.First(item => item.Kind == MediaKind.Movie);
        var ticket = await client.StartAsync(movie.Id, TestContext.Current.CancellationToken);
        var outbox = new ProgressOutbox(null);
        var profile = client.Library.Profile.User.Id;
        var first = new PendingProgress(client.Library.Server.ServerId, profile, movie.Id, 120_000, 3_600_000, false, ticket.Progress.Revision, Guid.NewGuid());
        var (result, saved) = await outbox.SaveAsync(client, first, TestContext.Current.CancellationToken);
        Assert.Equal(ProgressResult.Saved, result);
        Assert.True(saved!.Revision > ticket.Progress.Revision);
        Assert.Equal(120_000, (await client.ProgressAsync(movie.Id, TestContext.Current.CancellationToken)).PositionMilliseconds);

        // A save that builds on an old revision means another device moved on.
        var stale = first with { PositionMilliseconds = 60_000, ClientMutationId = Guid.NewGuid() };
        var (conflict, _) = await outbox.SaveAsync(client, stale, TestContext.Current.CancellationToken);
        Assert.Equal(ProgressResult.Conflict, conflict);
        Assert.Empty(outbox.Pending);

        // Someone watching here has the later position: it is sent again on the server's revision.
        var watching = first with { PositionMilliseconds = 1_200_000, ClientMutationId = Guid.NewGuid(), RecordedAt = DateTimeOffset.UtcNow };
        var (rebased, rebasedSaved) = await outbox.SaveAsync(client, watching, TestContext.Current.CancellationToken);
        Assert.Equal(ProgressResult.Saved, rebased);
        Assert.Equal(1_200_000, (await client.ProgressAsync(movie.Id, TestContext.Current.CancellationToken)).PositionMilliseconds);
        Assert.Empty(outbox.Pending);
        // A sample taken before another device's later save does not overwrite it.
        var older = first with { PositionMilliseconds = 30_000, ClientMutationId = Guid.NewGuid(), RecordedAt = DateTimeOffset.UtcNow.AddHours(-1) };
        Assert.Equal(ProgressResult.Conflict, (await outbox.SaveAsync(client, older, TestContext.Current.CancellationToken)).Result);
        Assert.Equal(1_200_000, (await client.ProgressAsync(movie.Id, TestContext.Current.CancellationToken)).PositionMilliseconds);

        var finished = first with { PositionMilliseconds = 3_600_000, IsFinished = true, ExpectedRevision = rebasedSaved!.Revision, ClientMutationId = Guid.NewGuid() };
        Assert.Equal(ProgressResult.Saved, (await outbox.SaveAsync(client, finished, TestContext.Current.CancellationToken)).Result);
        Assert.True((await client.ProgressAsync(movie.Id, TestContext.Current.CancellationToken)).IsCompleted);
    }

    [Fact]
    public async Task KeepsSceneNotes()
    {
        var (client, store) = await OpenAsync();
        var movie = store.Catalog.First(item => item.Kind == MediaKind.Movie);
        Assert.Empty(await client.NotesAsync(movie.Id, TestContext.Current.CancellationToken));
        var id = Guid.NewGuid();
        var note = await client.SaveNoteAsync(movie.Id, id, new SaveSceneNoteRequest(42_000, null, "The door opens.", 0), TestContext.Current.CancellationToken);
        Assert.Equal(id, note.Id);
        var listed = Assert.Single(await client.NotesAsync(movie.Id, TestContext.Current.CancellationToken));
        Assert.Equal("The door opens.", listed.Text);
        await client.DeleteNoteAsync(movie.Id, id, listed.Revision, TestContext.Current.CancellationToken);
        Assert.Empty(await client.NotesAsync(movie.Id, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task PlayOnSendsAPlayCommandToAnotherPlayer()
    {
        var (client, store) = await OpenAsync();
        var movie = store.Catalog.First(item => item.Kind == MediaKind.Movie);
        await client.HeartbeatAsync(new PlayerHeartbeatRequest("living-room-tv", "Living Room TV", "tvos", false), TestContext.Current.CancellationToken);
        var settings = new MemorySettingsStore();
        var remote = new RemotePlayback(client, settings, TimeProvider.System);
        var players = await remote.PlayersAsync();
        var tv = Assert.Single(players, p => p.DeviceId == "living-room-tv");
        await remote.PlayAsync(tv, movie);
        var commands = await client.CommandsAsync("living-room-tv", TestContext.Current.CancellationToken);
        var play = Assert.Single(commands);
        Assert.Equal("play", play.Action);
        Assert.Equal(movie.Id, play.MediaId);
        remote.Stop();
    }
}
