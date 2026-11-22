using Microsoft.Data.Sqlite;

namespace Aurelia.Server.Services;

/// <summary>A domain error that maps directly to an HTTP status code and <see cref="Aurelia.Contracts.ApiProblem"/>.</summary>
public abstract class ApiException(string code, string message, int statusCode) : Exception(message)
{
    public string Code { get; } = code;

    public int StatusCode { get; } = statusCode;
}

/// <summary>Recognises disk-full failures across SQLite, EF Core and raw I/O so requests answer 507 instead of 500.</summary>
public static class ServerStorageErrors
{
    private const int SqliteIoError = 10;
    private const int SqliteFull = 13;
    private const int SqliteCantOpen = 14;
    private const int UnixEnospc = 28;
    private const int WindowsErrorDiskFull = unchecked((int)0x80070070);
    private const int WindowsErrorHandleDiskFull = unchecked((int)0x80070027);
    private const long LowDiskThresholdBytes = 1_048_576;

    public static bool IsStorageFull(Exception exception, string? dataDirectory = null)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            if (current is SqliteException sqlite)
            {
                if (sqlite.SqliteErrorCode == SqliteFull) return true;
                if (sqlite.SqliteErrorCode is SqliteIoError or SqliteCantOpen
                    && AvailableFreeSpace(dataDirectory) is { } free
                    && free < LowDiskThresholdBytes)
                {
                    return true;
                }
            }
            if (current is IOException io && IsNoSpaceHResult(io.HResult))
            {
                return true;
            }
        }
        return false;
    }

    public static bool IsNoSpaceHResult(int hResult) =>
        hResult is UnixEnospc or WindowsErrorDiskFull or WindowsErrorHandleDiskFull;

    public static long? AvailableFreeSpace(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(path));
            if (string.IsNullOrEmpty(root)) return null;
            var drive = new DriveInfo(root);
            return drive.IsReady ? drive.AvailableFreeSpace : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }
}
