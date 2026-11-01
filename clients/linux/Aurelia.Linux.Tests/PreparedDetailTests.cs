using System.Text.Json;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Library;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class PreparedDetailTests
{
    [AvaloniaFact]
    public void FocusingATitlePreparesItsMetadataWithoutOpeningAVideoStream()
    {
        var server = FakeLibrary.Create(pictures: false);
        var main = FakeLibrary.ShowLibrary(server);
        var store = main.Session.Library!;
        var item = store.Catalog.Single(i => i.Id == FakeLibrary.SeriesId);
        var context = new LibraryContext(store, main.Shell!);
        var card = MediaCards.Poster(context, item, 160);
        var window = new Window { Width = 400, Height = 500, Content = card };
        window.Show();
        Assert.True(card.Focus());
        FakeLibrary.Pump(() => store.PreparedDetail(item.Id) is not null);
        Assert.NotNull(store.PreparedDetail(item.Id));
        Assert.NotNull(new DetailPage(context, item).Detail);
        Assert.Contains($"GET /api/v1/catalog/items/{item.Id}", server.Requests);
        Assert.Contains($"GET /api/v1/media/{item.Id}/playback-plan", server.Requests);
        Assert.DoesNotContain(server.Requests, request => request.StartsWith("POST ", StringComparison.Ordinal));
        Assert.DoesNotContain(server.Requests, request => request.Contains("/streams/", StringComparison.Ordinal));
        window.Close();
        main.Session.Rest();
        main.Close();
    }

    [AvaloniaFact]
    public void LeavingATitleBeforeTheDelayCancelsPreparation()
    {
        var server = FakeLibrary.Create(pictures: false);
        var main = FakeLibrary.ShowLibrary(server);
        var store = main.Session.Library!;
        var item = store.Catalog.Single(i => i.Id == FakeLibrary.SeriesId);
        var card = MediaCards.Poster(new LibraryContext(store, main.Shell!), item, 160);
        var other = new Button { Content = "Other control" };
        var window = new Window { Width = 400, Height = 500, Content = new StackPanel { Children = { card, other } } };
        window.Show();
        Assert.True(card.Focus());
        Assert.True(other.Focus());
        FakeLibrary.Pump(() => false, rounds: 50);
        Assert.DoesNotContain($"GET /api/v1/catalog/items/{item.Id}", server.Requests);
        Assert.Null(store.PreparedDetail(item.Id));
        window.Close();
        main.Session.Rest();
        main.Close();
    }

    [AvaloniaFact]
    public async Task PreparationIsBoundedReusedAndInvalidatedWhenTheCatalogChanges()
    {
        var server = FakeLibrary.Create(pictures: false);
        var main = FakeLibrary.ShowLibrary(server);
        var store = main.Session.Library!;
        var cancellation = TestContext.Current.CancellationToken;
        var original = await store.Client.DetailAsync(FakeLibrary.SeriesId, cancellation);
        var plan = await store.Client.PlaybackPlanAsync(FakeLibrary.SeriesId, cancellation);
        var ids = new List<Guid>();
        for (var index = 0; index < 14; index++)
        {
            var id = Guid.NewGuid();
            ids.Add(id);
            var item = original.Item with { Id = id, Title = "Synthetic title " + index };
            server.Answer("GET", $"/api/v1/catalog/items/{id}", JsonSerializer.Serialize(original with { Item = item }, AureliaJson.Options))
                .Answer("GET", $"/api/v1/media/{id}/playback-plan", JsonSerializer.Serialize(plan with { Target = item }, AureliaJson.Options));
            await store.PrepareDetailAsync(item, cancellation);
            await store.PrepareDetailAsync(item, cancellation);
            Assert.Equal(1, server.Requests.Count(request => request == $"GET /api/v1/catalog/items/{id}"));
        }
        Assert.Null(store.PreparedDetail(ids[0]));
        Assert.NotNull(store.PreparedDetail(ids[^1]));
        Assert.Equal(12, ids.Count(id => store.PreparedDetail(id) is not null));
        await store.RefreshAsync();
        Assert.Null(store.PreparedDetail(ids[^1]));
        main.Session.Rest();
        main.Close();
    }
}
