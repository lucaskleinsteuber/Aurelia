using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Management;

// Answers the server builds without a shared contract, shaped as the server sends them.

public sealed record ServerBackupSummary(string Name, string Kind, DateTimeOffset CreatedAt, long Bytes);

public sealed record ServerEventSummary(DateTimeOffset At, string Code, string Severity, int? Status = null);

public sealed record ServerJobHistory(IReadOnlyList<LibraryScanSummary> Scans, IReadOnlyList<MetadataJobSummary> Metadata);

public sealed record BackupExportResult(Guid Id, long Bytes);

public sealed record PreparedRestore(Guid Id, Guid ServerId, bool RevokesAllSessions);

/// <summary>Where the server runs, which decides what the Server settings offer.</summary>
public enum ServerHosting
{
    /// <summary>The Linux package's systemd service: restarts, saves power and updates itself.</summary>
    LinuxPackage,

    /// <summary>Hosted by Aurelia on a Mac, which controls its network and restarts.</summary>
    MacApp,

    Other,
}

public static class ServerHostingKind
{
    public static ServerHosting From(ServerManagementCapabilities? capabilities) => capabilities switch
    {
        { LinuxPackage: true } => ServerHosting.LinuxPackage,
        { NativeHostOperations: true, Platform: "macos" } => ServerHosting.MacApp,
        _ => ServerHosting.Other,
    };

    public static string? Location(ServerHosting hosting) => hosting switch
    {
        ServerHosting.LinuxPackage => "Linux Server",
        ServerHosting.MacApp => "Aurelia on a Mac",
        _ => null,
    };
}
