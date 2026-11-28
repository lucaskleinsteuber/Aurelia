namespace Tarven.Server.Services;

public sealed class LibraryException(string code, string message, int statusCode) : ApiException(code, message, statusCode);
