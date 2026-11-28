namespace Tarven.Server.Services;

public sealed class PlaybackException(string code, string message, int statusCode) : ApiException(code, message, statusCode);
