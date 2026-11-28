namespace Tarven.Linux.Core.Api;

/// <summary>Profile PINs are four to eight digits on every Tarven client.</summary>
public static class ProfilePin
{
    public static bool IsValid(string? pin) => pin is { Length: >= 4 and <= 8 } && pin.All(char.IsAsciiDigit);
}
