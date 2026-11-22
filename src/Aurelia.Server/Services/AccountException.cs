namespace Aurelia.Server.Services;

public sealed class AccountException(string code, string message, int statusCode) : ApiException(code, message, statusCode);
