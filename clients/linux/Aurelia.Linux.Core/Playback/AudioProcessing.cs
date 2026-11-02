namespace Aurelia.Linux.Core.Playback;

public enum AudioChangeResult { Applied, ReloadRequired, Unavailable }

public enum DialogueBoost { Off, Standard, Strong }
public enum VolumeLeveling { Off, Standard, Sleep }

/// <summary>Local speech EQ and dynamics; curves match the independent Apple clients.</summary>
public sealed record AudioProcessing(DialogueBoost Dialogue = DialogueBoost.Off, VolumeLeveling Leveling = VolumeLeveling.Off)
{
    public string[] Filters => [.. (Leveling == VolumeLeveling.Off ? Array.Empty<string>() : ["compressor"]),
        .. (Dialogue == DialogueBoost.Off ? Array.Empty<string>() : ["equalizer"])];
    public float Preamp => Dialogue == DialogueBoost.Strong ? -5 : Dialogue == DialogueBoost.Standard ? -3 : 0;
    public string[] Options => Leveling switch
    {
        VolumeLeveling.Standard => ["--audio-filter=compressor", "--compressor-rms-peak=0.2", "--compressor-attack=15", "--compressor-release=300",
            "--compressor-threshold=-24", "--compressor-ratio=4", "--compressor-knee=6", "--compressor-makeup-gain=12"],
        VolumeLeveling.Sleep => ["--audio-filter=compressor", "--compressor-rms-peak=1", "--compressor-attack=1.5", "--compressor-release=650",
            "--compressor-threshold=-30", "--compressor-ratio=12", "--compressor-knee=6", "--compressor-makeup-gain=16"],
        _ => [],
    };

    public float Gain(float frequency)
    {
        if (Dialogue == DialogueBoost.Off || !float.IsFinite(frequency) || frequency <= 0) return 0;
        float[] frequencies = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000];
        float[] gains = Dialogue == DialogueBoost.Standard ? [-3, -2, -1, 0, 2, 3, 1, 0, -1, -2] : [-6, -4, -2, 0, 3, 5, 2, 0, -2, -3];
        if (frequency <= frequencies[0]) return gains[0];
        for (var index = 1; index < frequencies.Length; index++)
        {
            if (frequency > frequencies[index]) continue;
            var fraction = MathF.Log(frequency / frequencies[index - 1]) / MathF.Log(frequencies[index] / frequencies[index - 1]);
            return gains[index - 1] + fraction * (gains[index] - gains[index - 1]);
        }
        return gains[^1];
    }
}
