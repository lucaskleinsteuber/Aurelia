using System.Text.Json.Nodes;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class AudioProcessingTests
{
    [Fact]
    public void LegacyNightModeMigratesAndNewChoicesSurviveRoundTrip()
    {
        var store = new MemorySettingsStore();
        store.Write(PlaybackPreferences.Key, new JsonObject { ["nightMode"] = true, ["defaultRate"] = 1.25 });
        var migrated = PlaybackPreferences.Load(store);
        Assert.Equal(VolumeLeveling.Standard, migrated.EffectiveLeveling);
        Assert.Equal(DialogueBoost.Off, migrated.DialogueBoost);
        Assert.Equal(1.25, migrated.DefaultRate);
        var changed = migrated with { VolumeLeveling = VolumeLeveling.Sleep, DialogueBoost = DialogueBoost.Strong };
        changed.Save(store);
        Assert.Equal(changed.Normalized(), PlaybackPreferences.Load(store));
        store.Write(PlaybackPreferences.Key, new JsonObject { ["nightMode"] = true, ["volumeLeveling"] = 0 });
        Assert.Equal(VolumeLeveling.Off, PlaybackPreferences.Load(store).EffectiveLeveling);
        store.Write(PlaybackPreferences.Key, new JsonObject { ["nightMode"] = false });
        Assert.Equal(VolumeLeveling.Off, PlaybackPreferences.Load(store).EffectiveLeveling);
    }

    [Fact]
    public void PresetsMapActualFrequenciesAndRetainHeadroom()
    {
        foreach (var mode in Enum.GetValues<DialogueBoost>())
        {
            var processing = new AudioProcessing(mode);
            foreach (float hz in new float[] { 60, 170, 310, 600, 1000, 1500, 2500, 3000, 6000, 12000, 16000 })
                Assert.True(processing.Gain(hz) + processing.Preamp <= 0.001);
            Assert.Equal(0, processing.Gain(float.NaN));
        }
        Assert.Equal(2, new AudioProcessing(DialogueBoost.Standard).Gain(1000));
        Assert.Equal(5, new AudioProcessing(DialogueBoost.Strong).Gain(3000));
        Assert.Equal(-6, new AudioProcessing(DialogueBoost.Strong).Gain(60));
        Assert.InRange(new AudioProcessing(DialogueBoost.Standard).Gain(2000), 2.01f, 2.99f);
    }

    [Fact]
    public void LevelingAndDialogueRemainIndependentInEveryCombination()
    {
        foreach (var dialogue in Enum.GetValues<DialogueBoost>())
            foreach (var leveling in Enum.GetValues<VolumeLeveling>())
            {
                var processing = new AudioProcessing(dialogue, leveling);
                Assert.Equal(leveling != VolumeLeveling.Off, processing.Filters.Contains("compressor"));
                Assert.Equal(dialogue != DialogueBoost.Off, processing.Filters.Contains("equalizer"));
            }
        var sleep = new AudioProcessing(Leveling: VolumeLeveling.Sleep).Options;
        Assert.Contains("--compressor-threshold=-30", sleep);
        Assert.Contains("--compressor-ratio=12", sleep);
        Assert.Contains("--compressor-attack=1.5", sleep);
        Assert.Contains("--compressor-release=650", sleep);
        Assert.Contains("--compressor-knee=6", sleep);
        Assert.Contains("--compressor-rms-peak=1", sleep);
        Assert.Contains("--compressor-makeup-gain=16", sleep);
    }
}
