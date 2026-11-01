namespace Aurelia.Linux;

internal static class ControlExtensions
{
    /// <summary>Applies a setting to a control inside an object initializer.</summary>
    public static T Also<T>(this T control, Action<T> configure)
    {
        configure(control);
        return control;
    }
}
