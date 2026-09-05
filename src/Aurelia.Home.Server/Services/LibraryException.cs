namespace Aurelia.Home.Server.Services;

public sealed class LibraryException(string code, string message, int statusCode) : Exception(message)
{
    public string Code { get; } = code;

    public int StatusCode { get; } = statusCode;
}
