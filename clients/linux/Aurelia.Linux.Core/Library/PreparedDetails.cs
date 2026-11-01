using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Library;

public sealed partial class LibraryStore
{
    private const int PreparedDetailLimit = 12;
    private static readonly TimeSpan PreparedDetailLifetime = TimeSpan.FromSeconds(30);
    private readonly Dictionary<Guid, PreparedTitle> preparedDetails = [];
    private static readonly SemaphoreSlim PreparationSlots = new(2, 2);
    private long detailGeneration;

    private sealed record PreparedTitle(CatalogDetailPresentation Detail, PlaybackPlanResponse? Plan, DateTimeOffset At, long Generation);

    /// <summary>A recent detail for this profile and catalog generation, shown while its fresh request loads.</summary>
    public (CatalogDetailPresentation Detail, PlaybackPlanResponse? Plan)? PreparedDetail(Guid id)
    {
        if (!preparedDetails.TryGetValue(id, out var value)) return null;
        if (value.Generation != detailGeneration || DateTimeOffset.UtcNow - value.At >= PreparedDetailLifetime)
        {
            preparedDetails.Remove(id);
            return null;
        }
        return (value.Detail, value.Plan);
    }

    /// <summary>Only metadata, a playback plan and still artwork: never a playback ticket or video stream.</summary>
    public async Task PrepareDetailAsync(CatalogItemSummary item, CancellationToken cancellation)
    {
        if (item.Kind is not (MediaKind.Movie or MediaKind.Series) || PreparedDetail(item.Id) is not null) return;
        var generation = detailGeneration;
        await PreparationSlots.WaitAsync(cancellation);
        try
        {
            if (PreparedDetail(item.Id) is not null) return;
            var detailTask = Client.DetailAsync(item.Id, cancellation);
            var planTask = Client.Supports("library-state-v1") ? Client.PlaybackPlanAsync(item.Id, cancellation) : Task.FromResult<PlaybackPlanResponse>(null!);
            await Task.WhenAll(detailTask, planTask);
            cancellation.ThrowIfCancellationRequested();
            if (generation != detailGeneration) return;
            var detail = detailTask.Result;
            preparedDetails[item.Id] = new PreparedTitle(detail, planTask.Result, DateTimeOffset.UtcNow, generation);
            while (preparedDetails.Count > PreparedDetailLimit)
                preparedDetails.Remove(preparedDetails.MinBy(entry => entry.Value.At).Key);
            var hero = detail.Metadata.Backdrop ?? detail.Metadata.Still ?? detail.Item.Backdrop;
            if (hero is not null)
            {
                try { await Artwork.GetAsync(Client, hero, 1920, cancellation); }
                catch (AureliaApiException) { }
            }
        }
        catch (AureliaApiException)
        {
            // Speculative metadata never blocks navigation or replaces an explicit page error.
        }
        finally { PreparationSlots.Release(); }
    }

    private void ClearPreparedDetails()
    {
        detailGeneration++;
        preparedDetails.Clear();
    }
}
