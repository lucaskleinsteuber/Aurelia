namespace Aurelia.Desktop.Core;

/// <summary>A failed server request with the server's own problem code, when it sent one.</summary>
public sealed class AureliaApiException(int status, string? code, string message, TimeSpan? retryAfter = null)
    : Exception(message)
{
    public int Status { get; } = status;
    public string? Code { get; } = code;
    public TimeSpan? RetryAfter { get; } = retryAfter;

    public bool IsAuthenticationFailure => Status == 401;
    public bool IsTransient => Status is 0 or 408 or 429 or >= 500;

    public static AureliaApiException IdentityMismatch() =>
        new(0, "identity_mismatch", "This server's identity does not match the one you trusted. Check the server, then connect again.");

    public static AureliaApiException InvalidResponse() =>
        new(0, "invalid_response", "The server sent a response this version of Aurelia does not understand.");

    public static AureliaApiException Unreachable() =>
        new(0, "unreachable", "The server could not be reached. Check the address and that Aurelia is running on it.");
}
