using Avalonia;
using Avalonia.Controls;

namespace Aurelia.Linux.Library;

/// <summary>
/// A row or a wrapping grid of equally sized cards that creates only the cards in and near the
/// visible part of the page, as the Mac's lazy stacks do. A library of thousands of titles used to
/// build (and lay out) every card on each change; now a page builds about two screens of them, and
/// more as it scrolls. Cards once made stay, so focus, menus and loaded pictures are kept.
/// </summary>
public sealed class LazyCards : Panel
{
    /// <summary>Lists up to this many cards are made at once, as before; longer ones lazily.</summary>
    public const int Threshold = 40;

    private readonly Func<int, Control> create;
    private readonly bool wrap;
    private readonly double spacing;
    private readonly double lineSpacing;
    private readonly SortedDictionary<int, Control> made = [];
    private Size item;
    private int columns = 1;
    private Rect viewport;

    public LazyCards(int count, Func<int, Control> create, bool wrap, double spacing, double lineSpacing = 0)
    {
        Count = count;
        this.create = create;
        this.wrap = wrap;
        this.spacing = spacing;
        this.lineSpacing = lineSpacing;
        EffectiveViewportChanged += (_, e) =>
        {
            viewport = e.EffectiveViewport;
            if (NeedsMore()) InvalidateMeasure();
        };
    }

    /// <summary>All cards, made or not.</summary>
    public int Count { get; }

    /// <summary>The size every card has: that of the first one.</summary>
    public Size ItemSize => item;

    /// <summary>The card at <paramref name="index"/>, made now if it was not yet (for keyboard paging and tests).</summary>
    public Control Card(int index)
    {
        if (made.TryGetValue(index, out var card)) return card;
        card = create(index);
        made[index] = card;
        // Children keep the order of the cards, so Tab moves through them in order.
        var position = made.Keys.TakeWhile(key => key < index).Count();
        Children.Insert(position, card);
        return card;
    }

    private (int First, int Last) Wanted()
    {
        if (Count == 0) return (0, -1);
        var stepX = item.Width + spacing;
        var stepY = item.Height + lineSpacing;
        // Before the page knows where it is, a first screen's worth; afterwards a screen on either side.
        if (viewport.Width <= 0 || viewport.Height <= 0 || stepX <= 0 || stepY <= 0)
            return (0, Math.Min(Count, wrap ? columns * 4 : 12) - 1);
        if (!wrap)
        {
            var margin = viewport.Width;
            var first = (int)Math.Floor((viewport.Left - margin) / stepX);
            var last = (int)Math.Ceiling((viewport.Right + margin) / stepX);
            return (Math.Clamp(first, 0, Count - 1), Math.Clamp(last, 0, Count - 1));
        }
        var buffer = viewport.Height;
        var firstRow = (int)Math.Floor((viewport.Top - buffer) / stepY);
        var lastRow = (int)Math.Ceiling((viewport.Bottom + buffer) / stepY);
        if (lastRow < 0 || firstRow * columns >= Count) return (0, -1);
        return (Math.Clamp(firstRow * columns, 0, Count - 1), Math.Clamp((lastRow + 1) * columns - 1, 0, Count - 1));
    }

    private bool NeedsMore()
    {
        var (first, last) = Wanted();
        for (var index = first; index <= last; index++)
            if (!made.ContainsKey(index)) return true;
        return false;
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (Count == 0) return default;
        var first = Card(0);
        first.Measure(Size.Infinity);
        item = first.DesiredSize;
        columns = wrap && !double.IsInfinity(availableSize.Width)
            ? Math.Max(1, (int)Math.Floor((availableSize.Width + spacing) / (item.Width + spacing)))
            : wrap ? 1 : Count;
        var (from, to) = Wanted();
        for (var index = from; index <= to; index++) Card(index);
        foreach (var card in made.Values) card.Measure(item);
        if (!wrap) return new Size(Count * item.Width + (Count - 1) * spacing, item.Height);
        var rows = (Count + columns - 1) / columns;
        return new Size(columns * item.Width + (columns - 1) * spacing, rows * item.Height + (rows - 1) * lineSpacing);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        foreach (var (index, card) in made)
        {
            var column = wrap ? index % columns : index;
            var row = wrap ? index / columns : 0;
            card.Arrange(new Rect(new Point(column * (item.Width + spacing), row * (item.Height + lineSpacing)), item));
        }
        return finalSize;
    }
}
