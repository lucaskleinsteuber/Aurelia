namespace Aurelia.Server.Services.Hls;

/// <summary>What a request for a segment needs.</summary>
public enum SegmentPlan
{
    /// <summary>The segment is here.</summary>
    Ready,
    /// <summary>The running conversion reaches it soon.</summary>
    Wait,
    /// <summary>A new conversion has to start at the segment (a seek).</summary>
    Restart,
}

/// <summary>
/// The converted segments of one HLS session, in memory only: a window from a few segments
/// behind the player to some ahead of it, capped in bytes. Nothing is ever written to disk, and
/// everything is gone when the session ends. Thread-safe; waiting is signalled to callers.
/// </summary>
public sealed class SegmentStore(int maximumBytes = SegmentStore.DefaultMaximumBytes, int ahead = SegmentStore.DefaultAhead, int behind = SegmentStore.DefaultBehind)
{
    public const int DefaultMaximumBytes = 96 * 1024 * 1024;
    public const int DefaultAhead = 15;
    public const int DefaultBehind = 3;
    /// <summary>A request this many segments beyond what is being converted waits instead of restarting.</summary>
    public const int WaitReach = 3;

    private readonly object gate = new();
    private readonly SortedDictionary<int, List<byte[]>> segments = [];
    private readonly HashSet<int> complete = [];
    private TaskCompletionSource changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private long bytes;
    private int playhead;
    private int? producing;
    private int? producerStart;

    public long Bytes { get { lock (gate) return bytes; } }
    public int Playhead { get { lock (gate) return playhead; } }
    /// <summary>The segment the running conversion writes now, or null when none runs.</summary>
    public int? Producing { get { lock (gate) return producing; } }
    public int Count { get { lock (gate) return complete.Count; } }

    /// <summary>A conversion begins at this segment.</summary>
    public void BeginProducing(int start)
    {
        lock (gate)
        {
            producerStart = start;
            producing = start;
            Pulse();
        }
    }

    /// <summary>The conversion ended: what it was writing is complete if it got anything.</summary>
    public void EndProducing(bool finished)
    {
        lock (gate)
        {
            if (finished && producing is { } last && segments.ContainsKey(last)) complete.Add(last);
            else if (producing is { } partial && !complete.Contains(partial) && segments.Remove(partial, out var parts))
                bytes -= parts.Sum(part => (long)part.Length);
            producing = null;
            producerStart = null;
            Pulse();
        }
    }

    /// <summary>A fragment of segment <paramref name="index"/> arrived; a later segment completes the earlier ones.</summary>
    public void Add(int index, byte[] fragment)
    {
        ArgumentNullException.ThrowIfNull(fragment);
        lock (gate)
        {
            if (producing is { } current && index > current && segments.ContainsKey(current)) complete.Add(current);
            if (producing is { } now && index < now) index = now; // a stray earlier time belongs to the open segment
            producing = index;
            if (complete.Contains(index)) return; // already here from an earlier run
            if (!segments.TryGetValue(index, out var parts)) segments[index] = parts = [];
            parts.Add(fragment);
            bytes += fragment.Length;
            Evict();
            Pulse();
        }
    }

    public byte[]? TryGet(int index)
    {
        lock (gate)
        {
            if (!complete.Contains(index) || !segments.TryGetValue(index, out var parts)) return null;
            if (parts.Count == 1) return parts[0];
            var joined = new byte[parts.Sum(part => part.Length)];
            var offset = 0;
            foreach (var part in parts)
            {
                part.CopyTo(joined, offset);
                offset += part.Length;
            }
            return joined;
        }
    }

    /// <summary>What a request for the segment needs, and the player's position moves there.</summary>
    public SegmentPlan Request(int index)
    {
        lock (gate)
        {
            playhead = index;
            Evict();
            Pulse();
            if (complete.Contains(index)) return SegmentPlan.Ready;
            return producerStart is { } start && producing is { } now && index >= start && index <= now + WaitReach
                ? SegmentPlan.Wait
                : SegmentPlan.Restart;
        }
    }

    /// <summary>Whether the conversion should stop reading for now: far enough ahead, or the memory cap is reached.</summary>
    public bool ShouldPause
    {
        get
        {
            lock (gate) return producing is { } now && now > playhead && (now - playhead > ahead || bytes >= maximumBytes);
        }
    }

    /// <summary>Completes on the next change: a fragment, a request or the end of a conversion.</summary>
    public Task ChangedAsync(CancellationToken cancellationToken)
    {
        Task task;
        lock (gate) task = changed.Task;
        return task.WaitAsync(cancellationToken);
    }

    /// <summary>Removes everything, for a new init segment or the end of the session.</summary>
    public void Clear()
    {
        lock (gate)
        {
            segments.Clear();
            complete.Clear();
            bytes = 0;
            Pulse();
        }
    }

    private void Evict()
    {
        // Behind the player first, then the farthest ahead, but never the segment being written or the next ones the player needs.
        foreach (var index in segments.Keys.Where(index => index < playhead - behind).ToList()) Remove(index);
        while (bytes > maximumBytes)
        {
            var farthest = segments.Keys.Where(index => index != producing && index > playhead + 1).DefaultIfEmpty(int.MinValue).Max();
            if (farthest == int.MinValue) break;
            Remove(farthest);
        }
    }

    private void Remove(int index)
    {
        if (!segments.Remove(index, out var parts)) return;
        complete.Remove(index);
        bytes -= parts.Sum(part => (long)part.Length);
    }

    private void Pulse()
    {
        var previous = changed;
        changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        previous.TrySetResult();
    }
}
