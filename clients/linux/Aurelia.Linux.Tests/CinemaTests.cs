using Aurelia.Contracts;
using Aurelia.Linux.Core.Playback;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class CinemaTests
{
    private static CatalogItemSummary Item(Guid id, MediaKind kind, Guid? parent = null) =>
        FakeLibrary.Item(id, kind, "Synthetic", 2024, [], parent: parent);

    [Fact]
    public void OnlyFilmsWithCinemaModeAndATrailerServerGetAPreShow()
    {
        var on = new PlaybackPreferences(CinemaMode: true);
        Assert.True(CinemaPlan.Wanted(on, MediaKind.Movie, serverListsTrailers: true, watchingTogether: false));
        Assert.False(CinemaPlan.Wanted(new PlaybackPreferences(), MediaKind.Movie, true, false));
        Assert.False(CinemaPlan.Wanted(on, MediaKind.Episode, true, false));
        Assert.False(CinemaPlan.Wanted(on, MediaKind.Movie, false, false));
        Assert.False(CinemaPlan.Wanted(on, MediaKind.Movie, true, true));
        Assert.False(CinemaPlan.Wanted(on with { CinemaAds = false, CinemaTrailers = 0 }, MediaKind.Movie, true, false));
    }

    [Fact]
    public void AFilmPickedUpInTheMiddleGetsNoPreShow()
    {
        var preferences = new PlaybackPreferences(CinemaMode: true);
        var midway = new PlaybackProgressResponse(Guid.NewGuid(), 600_000, 6_000_000, false, null, null, 1);
        Assert.False(CinemaPlan.StartsAtBeginning(resume: true, startAt: null, midway, preferences));
        Assert.True(CinemaPlan.StartsAtBeginning(resume: false, startAt: null, midway, preferences));
        Assert.True(CinemaPlan.StartsAtBeginning(resume: true, startAt: 0, midway, preferences));
        Assert.False(CinemaPlan.StartsAtBeginning(resume: true, startAt: 60_000, midway, preferences));
        Assert.True(CinemaPlan.StartsAtBeginning(resume: true, startAt: null, midway with { IsCompleted = true }, preferences));
        Assert.True(CinemaPlan.StartsAtBeginning(resume: true, startAt: null, midway, preferences with { ResumeThresholdSeconds = 1200 }));
    }

    [Fact]
    public void ActsLeaveOutTheFilmsOwnTrailerAndEndWithTheCurtain()
    {
        var film = Guid.NewGuid();
        var other = Guid.NewGuid();
        var own = new CinemaTrailer(Item(Guid.NewGuid(), MediaKind.Trailer, film), Item(film, MediaKind.Movie));
        var foreign = new CinemaTrailer(Item(Guid.NewGuid(), MediaKind.Trailer, other), Item(other, MediaKind.Movie));
        var acts = CinemaPlan.Acts(CinemaAd.Popcorn, [own, foreign], film, "Film");
        Assert.Equal(3, acts.Count);
        Assert.Equal(new CinemaAct.Ad(CinemaAd.Popcorn), acts[0]);
        Assert.Equal(new CinemaAct.Trailer(foreign), acts[1]);
        Assert.Equal(new CinemaAct.Feature("Film"), acts[2]);
        Assert.Empty(CinemaPlan.Acts(null, [own], film, "Film"));
        Assert.Equal(CinemaAd.IceCream, CinemaPlan.NextAd(null));
        Assert.Equal(CinemaAd.Popcorn, CinemaPlan.NextAd(CinemaAd.IceCream));
        Assert.Equal(CinemaAd.IceCream, CinemaPlan.NextAd(CinemaAd.Phones));
    }

    [Fact]
    public void AdScriptsRunAtTheMacsPaceAndTrailerCountsStayInRange()
    {
        foreach (var ad in Enum.GetValues<CinemaAd>())
        {
            var script = CinemaPlan.Script(ad);
            Assert.NotEmpty(script);
            Assert.All(script, beat => Assert.True(beat.From < beat.Until && beat.Until <= 16 * CinemaPlan.Pace));
        }
        Assert.Equal(3, new PlaybackPreferences(CinemaTrailers: 9).Normalized().CinemaTrailers);
        Assert.Equal(0, new PlaybackPreferences(CinemaTrailers: -2).Normalized().CinemaTrailers);
    }
}
