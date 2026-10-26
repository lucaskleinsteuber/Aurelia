using Xunit;
using Xunit.Abstractions;

[assembly: TestCollectionOrderer("Aurelia.Server.Tests.MeasuredCollectionOrderer", "Aurelia.Server.Tests")]

namespace Aurelia.Server.Tests;

/// <summary>
/// Start expensive independent collections first so they do not become a late serial tail.
/// These approximate seconds come from a complete synthetic-data run before the fixture changes.
/// This changes only start order: the runner retains its parallelism and nonparallel collections.
/// </summary>
public sealed class MeasuredCollectionOrderer : ITestCollectionOrderer
{
    private static readonly IReadOnlyDictionary<string, double> Seconds = new Dictionary<string, double>(StringComparer.Ordinal)
    {
        [nameof(RestoreActivationTests)] = 49.8,
        [nameof(ImportPlanningApiTests)] = 39.2,
        [nameof(LibraryStateTests)] = 38.8,
        [nameof(MediaLibraryApiTests)] = 36.3,
        [nameof(PlaybackStreamingTests)] = 34.7,
        [nameof(DeviceAuthorizationTests)] = 33.3,
        [nameof(MetadataJobPersistenceTests)] = 31.4,
        [nameof(MediaEditingTests)] = 28.2,
        [nameof(ProfileDeletionTests)] = 21.9,
        [nameof(ProfileEditingTests)] = 21.3,
        [nameof(PlaybackProgressTests)] = 21.1,
        [nameof(ServerAccessFoundationTests)] = 20.5,
        [nameof(ArtworkVariantTests)] = 19.7,
        [nameof(ManagementGrantTests)] = 19.1,
        [nameof(MigrationUpgradeTests)] = 16,
        [nameof(MetadataPresentationTests)] = 15.8,
        [nameof(ProfileAndSceneNoteTests)] = 14.1,
        [nameof(SyncHistoryTests)] = 12.6,
        [nameof(ServerBackupSecurityTests)] = 12.2,
        [nameof(ServerFoundationTests)] = 11.6,
        [nameof(PresentationApiTests)] = 10.3,
        [nameof(ImportStructureAcceptanceTests)] = 10.1,
        [nameof(ServerReadinessTests)] = 9.4,
        [nameof(StorageReliabilityTests)] = 9,
        [nameof(WebAppTests)] = 8.8,
    };

    public IEnumerable<ITestCollection> OrderTestCollections(IEnumerable<ITestCollection> testCollections) =>
        testCollections.OrderByDescending(collection => Seconds.FirstOrDefault(item =>
                collection.DisplayName.EndsWith("." + item.Key, StringComparison.Ordinal)).Value)
            .ThenBy(collection => collection.DisplayName, StringComparer.Ordinal);
}
