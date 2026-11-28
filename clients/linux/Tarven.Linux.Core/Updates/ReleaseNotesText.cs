namespace Tarven.Linux.Core.Updates;

/// <summary>One block of a release's notes as the app shows it.</summary>
public sealed record ReleaseNotesBlock(ReleaseNotesBlockKind Kind, string Text);

public enum ReleaseNotesBlockKind { Heading, Paragraph, Bullet }

/// <summary>
/// A release's notes as headings, paragraphs and bullets. GitHub writes them in Markdown, and the
/// app showed the marks themselves ("> **Beta:**", "## What changed"; audit Linux S2).
/// </summary>
public static class ReleaseNotesText
{
    public static IReadOnlyList<ReleaseNotesBlock> Blocks(string? markdown)
    {
        var blocks = new List<ReleaseNotesBlock>();
        if (string.IsNullOrWhiteSpace(markdown)) return blocks;
        var paragraph = new List<string>();
        void EndParagraph()
        {
            if (paragraph.Count > 0) blocks.Add(new(ReleaseNotesBlockKind.Paragraph, string.Join(' ', paragraph)));
            paragraph.Clear();
        }
        foreach (var raw in markdown.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0)
            {
                EndParagraph();
                continue;
            }
            if (line.StartsWith('#'))
            {
                EndParagraph();
                blocks.Add(new(ReleaseNotesBlockKind.Heading, Inline(line.TrimStart('#'))));
                continue;
            }
            if (line.StartsWith("- ", StringComparison.Ordinal) || line.StartsWith("* ", StringComparison.Ordinal))
            {
                EndParagraph();
                blocks.Add(new(ReleaseNotesBlockKind.Bullet, Inline(line[2..])));
                continue;
            }
            paragraph.Add(Inline(line.TrimStart('>')));
        }
        EndParagraph();
        return [.. blocks.Where(block => block.Text.Length > 0)];
    }

    /// <summary>Bold, code and links become their text.</summary>
    private static string Inline(string text)
    {
        var plain = text.Trim().Replace("**", "", StringComparison.Ordinal).Replace("__", "", StringComparison.Ordinal).Replace("`", "", StringComparison.Ordinal);
        // [label](address) → label
        var result = new System.Text.StringBuilder();
        for (var index = 0; index < plain.Length; index++)
        {
            if (plain[index] == '[' && plain.IndexOf("](", index, StringComparison.Ordinal) is var middle and > 0
                && plain.IndexOf(')', middle) is var end and > 0)
            {
                result.Append(plain, index + 1, middle - index - 1);
                index = end;
                continue;
            }
            result.Append(plain[index]);
        }
        return result.ToString().Trim();
    }
}

/// <summary>Counts what is written through it, for a download's progress.</summary>
public sealed class ProgressStream(Stream inner, long expected, Action<double> progress) : Stream
{
    private long written;
    private int lastPercent = -1;

    public override bool CanRead => false;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => written;
    public override long Position { get => written; set => throw new NotSupportedException(); }
    public override void Flush() => inner.Flush();
    public override Task FlushAsync(CancellationToken cancellationToken) => inner.FlushAsync(cancellationToken);
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count)
    {
        inner.Write(buffer, offset, count);
        Count(count);
    }

    public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        await inner.WriteAsync(buffer, cancellationToken);
        Count(buffer.Length);
    }

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    private void Count(int count)
    {
        written += count;
        if (expected <= 0) return;
        var percent = (int)Math.Min(100, written * 100 / expected);
        if (percent == lastPercent) return;
        lastPercent = percent;
        progress(percent / 100.0);
    }
}
