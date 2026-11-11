namespace Aurelia.Server.Services.Segments;

/// <summary>
/// A compact acoustic fingerprint (Haitsma–Kalker): one 32-bit value per 11.6 ms that records
/// whether neighbouring frequency bands grow or shrink over time. Identical music produces the
/// same values even when the surrounding scenes differ or the loudness changes. Fingerprints
/// exist only in memory and are never stored.
/// </summary>
public static class AudioFingerprint
{
    public const int SampleRate = 11_025;
    public const int FrameLength = 4_096;
    public const int Hop = 128;
    public const double HopSeconds = (double)Hop / SampleRate;

    /// <summary>Seconds from a value's first sample to the middle of the sound it describes.</summary>
    public const double CenterSeconds = (FrameLength / 2.0 + Hop / 2.0) / SampleRate;

    private const int BandCount = 33;
    private const double LowFrequency = 300;
    private const double HighFrequency = 2_000;
    private const int HopsPerFrame = FrameLength / Hop;

    /// <summary>Mean square below which a frame counts as silence (about −60 dBFS).</summary>
    private const float SilenceEnergy = 1e-6f;

    private static readonly float[] Window = CreateWindow();
    private static readonly int[] Reverse = CreateReverse();
    private static readonly float[] Cosine = CreateTable(Math.Cos);
    private static readonly float[] Sine = CreateTable(Math.Sin);
    private static readonly int[] Edges = CreateEdges();

    /// <param name="Values">One value per hop; 0 marks silence, which never matches anything.</param>
    /// <param name="Energy">Mean square of each hop of 128 samples, for finding quiet moments.</param>
    public sealed record Result(uint[] Values, float[] Energy);

    public static Result Compute(short[] samples)
    {
        ArgumentNullException.ThrowIfNull(samples);
        var hops = samples.Length / Hop;
        var energy = new float[hops];
        for (var hop = 0; hop < hops; hop++)
        {
            double sum = 0;
            var start = hop * Hop;
            for (var index = 0; index < Hop; index++)
            {
                var sample = samples[start + index] / 32768.0;
                sum += sample * sample;
            }
            energy[hop] = (float)(sum / Hop);
        }

        var frameCount = samples.Length >= FrameLength ? (samples.Length - FrameLength) / Hop + 1 : 0;
        if (frameCount < 2) return new Result([], energy);

        var real = new float[FrameLength];
        var imaginary = new float[FrameLength];
        var previous = new float[BandCount];
        var current = new float[BandCount];
        var values = new uint[frameCount - 1];
        var previousSilent = true;
        for (var frame = 0; frame < frameCount; frame++)
        {
            var start = frame * Hop;
            float frameEnergy = 0;
            for (var hop = 0; hop < HopsPerFrame; hop++) frameEnergy += energy[frame + hop];
            var silent = frameEnergy / HopsPerFrame < SilenceEnergy;
            if (!silent)
            {
                for (var index = 0; index < FrameLength; index++)
                {
                    real[Reverse[index]] = samples[start + index] * Window[index];
                }
                Array.Clear(imaginary);
                Transform(real, imaginary);
                for (var band = 0; band < BandCount; band++)
                {
                    float sum = 0;
                    for (var bin = Edges[band]; bin < Edges[band + 1]; bin++)
                    {
                        sum += real[bin] * real[bin] + imaginary[bin] * imaginary[bin];
                    }
                    current[band] = sum;
                }
            }
            if (frame > 0 && !silent && !previousSilent)
            {
                uint value = 0;
                for (var bit = 0; bit < BandCount - 1; bit++)
                {
                    var difference = (current[bit] - current[bit + 1]) - (previous[bit] - previous[bit + 1]);
                    if (difference > 0) value |= 1u << bit;
                }
                // 0 is reserved for silence.
                values[frame - 1] = value == 0 ? 1u : value;
            }
            previousSilent = silent;
            (previous, current) = (current, previous);
        }
        return new Result(values, energy);
    }

    /// <summary>In-place radix-2 transform of bit-reversed input.</summary>
    private static void Transform(float[] real, float[] imaginary)
    {
        for (var size = 2; size <= FrameLength; size <<= 1)
        {
            var half = size >> 1;
            var step = FrameLength / size;
            for (var block = 0; block < FrameLength; block += size)
            {
                for (int index = 0, table = 0; index < half; index++, table += step)
                {
                    var cosine = Cosine[table];
                    var sine = -Sine[table];
                    var low = block + index;
                    var high = low + half;
                    var productReal = real[high] * cosine - imaginary[high] * sine;
                    var productImaginary = real[high] * sine + imaginary[high] * cosine;
                    real[high] = real[low] - productReal;
                    imaginary[high] = imaginary[low] - productImaginary;
                    real[low] += productReal;
                    imaginary[low] += productImaginary;
                }
            }
        }
    }

    private static float[] CreateWindow()
    {
        var window = new float[FrameLength];
        for (var index = 0; index < FrameLength; index++)
        {
            window[index] = (float)((0.5 - 0.5 * Math.Cos(2 * Math.PI * index / FrameLength)) / 32768.0);
        }
        return window;
    }

    private static int[] CreateReverse()
    {
        var bits = int.Log2(FrameLength);
        var reverse = new int[FrameLength];
        for (var index = 0; index < FrameLength; index++)
        {
            var value = 0;
            for (var bit = 0; bit < bits; bit++)
            {
                if ((index & (1 << bit)) != 0) value |= 1 << (bits - 1 - bit);
            }
            reverse[index] = value;
        }
        return reverse;
    }

    private static float[] CreateTable(Func<double, double> function)
    {
        var table = new float[FrameLength / 2];
        for (var index = 0; index < table.Length; index++)
        {
            table[index] = (float)function(2 * Math.PI * index / FrameLength);
        }
        return table;
    }

    private static int[] CreateEdges()
    {
        var edges = new int[BandCount + 1];
        for (var index = 0; index <= BandCount; index++)
        {
            var frequency = LowFrequency * Math.Pow(HighFrequency / LowFrequency, (double)index / BandCount);
            var bin = (int)Math.Round(frequency * FrameLength / SampleRate);
            edges[index] = index == 0 ? Math.Max(bin, 1) : Math.Max(bin, edges[index - 1] + 1);
        }
        return edges;
    }
}
