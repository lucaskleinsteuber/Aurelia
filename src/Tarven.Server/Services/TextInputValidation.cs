using System.Globalization;
using System.Text;

namespace Tarven.Server.Services;

/// <summary>Shared input validation helpers for display names and page bounds.</summary>
public static class TextInputValidation
{
    /// <summary>
    /// Returns true if the text contains ASCII/Unicode control characters or bidirectional
    /// override/isolate formatting characters (which can spoof visual text direction).
    /// </summary>
    public static bool HasForbiddenControlCharacters(string value)
    {
        foreach (var ch in value)
        {
            if (char.IsControl(ch)) return true;
            if (ch is '\u200E' or '\u200F' or '\u061C'
                or (>= '\u202A' and <= '\u202E')
                or (>= '\u2066' and <= '\u2069'))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// Returns true when the text contains at least one visible character (excluding whitespace,
    /// control characters, Unicode format characters such as zero-width spaces, and unassigned
    /// or combining-only code points).
    /// </summary>
    public static bool HasVisibleCharacter(string value)
    {
        foreach (var rune in value.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune)) continue;
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.Control
                or UnicodeCategory.Format
                or UnicodeCategory.SpaceSeparator
                or UnicodeCategory.LineSeparator
                or UnicodeCategory.ParagraphSeparator
                or UnicodeCategory.NonSpacingMark
                or UnicodeCategory.OtherNotAssigned)
            {
                continue;
            }
            return true;
        }
        return false;
    }

    public static void ValidatePage(int offset, int limit, int maximumLimit)
    {
        if (offset < 0 || limit < 1 || limit > maximumLimit)
        {
            throw new LibraryException(
                "invalid_page",
                $"Offset must be at least 0 and limit must be between 1 and {maximumLimit}.",
                StatusCodes.Status400BadRequest);
        }
    }
}
