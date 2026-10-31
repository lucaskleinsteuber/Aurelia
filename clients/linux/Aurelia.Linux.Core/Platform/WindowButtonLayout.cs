namespace Aurelia.Linux.Core.Platform;

public enum WindowButton
{
    Close,
    Minimize,
    Maximize,
}

/// <summary>
/// Which window buttons the desktop shows on which side, so Aurelia's own buttons sit where the
/// person expects them. Buttons other than close, minimize and maximize are ignored.
/// </summary>
public sealed record WindowButtonLayout(IReadOnlyList<WindowButton> Left, IReadOnlyList<WindowButton> Right)
{
    /// <summary>The most common arrangement: minimize, maximize and close on the right.</summary>
    public static WindowButtonLayout Default { get; } = new([], [WindowButton.Minimize, WindowButton.Maximize, WindowButton.Close]);

    /// <summary>KDE's <c>ButtonsOnLeft</c>/<c>ButtonsOnRight</c> letters from kwinrc (X close, I minimize, A maximize).</summary>
    public static WindowButtonLayout FromKde(string? left, string? right) =>
        new(KdeButtons(left ?? "MS"), KdeButtons(right ?? "HIAX"));

    /// <summary>GNOME's <c>button-layout</c>, for example <c>appmenu:minimize,maximize,close</c>.</summary>
    public static WindowButtonLayout? FromGnome(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var text = value.Trim().Trim('\'', '"');
        var sides = text.Split(':', 2);
        return new(GnomeButtons(sides[0]), sides.Length > 1 ? GnomeButtons(sides[1]) : []);
    }

    private static List<WindowButton> KdeButtons(string letters)
    {
        var buttons = new List<WindowButton>();
        foreach (var letter in letters)
        {
            WindowButton? button = letter switch
            {
                'X' => WindowButton.Close,
                'I' => WindowButton.Minimize,
                'A' => WindowButton.Maximize,
                _ => null,
            };
            if (button is { } found && !buttons.Contains(found)) buttons.Add(found);
        }
        return buttons;
    }

    private static List<WindowButton> GnomeButtons(string names)
    {
        var buttons = new List<WindowButton>();
        foreach (var name in names.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            WindowButton? button = name switch
            {
                "close" => WindowButton.Close,
                "minimize" => WindowButton.Minimize,
                "maximize" => WindowButton.Maximize,
                _ => null,
            };
            if (button is { } found && !buttons.Contains(found)) buttons.Add(found);
        }
        return buttons;
    }
}
