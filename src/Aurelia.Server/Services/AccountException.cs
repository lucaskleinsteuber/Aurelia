namespace Aurelia.Server.Services;

public sealed class AccountException(string code, string message, int statusCode) : Exception(message)
{
    public string Code { get; } = code;

    public int StatusCode { get; } = statusCode;
}
