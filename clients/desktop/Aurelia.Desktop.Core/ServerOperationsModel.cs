using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>A database backup the server keeps, as the list shows it.</summary>
public sealed record ServerBackupItem(string Name, string Kind, DateTimeOffset CreatedAt, long Bytes)
{
    public string KindText => Kind switch { "manual" => "Made by hand", "automatic" => "Automatic", _ => CultureInfo.CurrentCulture.TextInfo.ToTitleCase(Kind) };
    public string Details => $"{CreatedAt.ToLocalTime():g} · {ServerOperationsModel.Size(Bytes)}";
}

/// <summary>Something the server recorded about itself: when, what and how serious.</summary>
public sealed record ServerEventItem(DateTimeOffset At, string Code, string Severity, Guid? UserId = null, int? Status = null)
{
    public string Time => At.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
    public string Text => Code.Replace('_', ' ') + (Status is { } status ? $" ({status.ToString(CultureInfo.InvariantCulture)})" : "");
    public bool IsWarning => Severity is "warning" or "error";
}

public sealed record BackupVerification(bool IsValid, string Message, int AppliedMigrationCount);
public sealed record BackupExport(Guid Id, long Bytes);
public sealed record PreparedServerRestore(Guid Id, Guid ServerId, bool RevokesAllSessions);

/// <summary>A file the person chose, for restoring a backup.</summary>
public sealed record ChosenFile(Stream Content, long Length, string Name) : IDisposable
{
    public void Dispose() => Content.Dispose();
}

/// <summary>
/// Backups, metadata and diagnostics in Server Settings, as the Mac's server operations: database
/// backups made and verified on the server, an encrypted full backup to keep elsewhere and to restore
/// from, the movie database (TMDB) that fills in details and artwork, and the server's event log.
/// </summary>
public sealed class ServerOperationsModel(Func<IAdministrationClient> client) : INotifyPropertyChanged
{
    private PreparedServerRestore? prepared;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Management locked while working; Server Settings asks for the password again.</summary>
    public event Action? Locked;

    public bool IsBusy { get; private set => Set(ref field, value); }
    public string? Error { get; private set => Set(ref field, value, nameof(Error), nameof(HasError)); }
    public bool HasError => Error is not null;
    public string? Notice { get; private set => Set(ref field, value, nameof(Notice), nameof(HasNotice)); }
    public bool HasNotice => Notice is not null;

    // Backups
    public ObservableCollection<ServerBackupItem> Backups { get; } = [];
    public bool HasBackups => Backups.Count > 0;
    public string ExportPassphrase { get; set => Set(ref field, value); } = "";
    public string ExportConfirmation { get; set => Set(ref field, value); } = "";
    public string RestorePassphrase { get; set => Set(ref field, value); } = "";
    public bool AwaitsRestoreConfirmation { get; private set => Set(ref field, value); }
    public string RestoreQuestion { get; private set => Set(ref field, value); } = "";

    // Metadata
    public MetadataProviderStatus? Provider { get; private set => Set(ref field, value, nameof(Provider), nameof(ProviderText), nameof(HasProvider)); }
    public bool HasProvider => Provider is not null;
    public string ProviderText => Provider is not { } status ? ""
        : !status.HasToken ? "No TMDB token yet. Details come from file and folder names only."
        : status.Enabled ? "Aurelia fills in details and artwork from TMDB." : "A TMDB token is saved, but looking up details is turned off.";
    public string ProviderAttribution => Provider?.Attribution ?? "";
    public string Token { get; set => Set(ref field, value); } = "";
    public bool ProviderEnabled { get; set => Set(ref field, value); }

    // Diagnostics
    public ObservableCollection<ServerEventItem> Events { get; } = [];
    public bool HasEvents => Events.Count > 0;

    public static string Size(long bytes) => bytes switch
    {
        >= 1L << 30 => (bytes / (double)(1L << 30)).ToString("0.0", CultureInfo.CurrentCulture) + " GB",
        >= 1L << 20 => (bytes / (double)(1L << 20)).ToString("0.0", CultureInfo.CurrentCulture) + " MB",
        _ => Math.Max(1, bytes / 1024).ToString(CultureInfo.CurrentCulture) + " KB",
    };

    public Task LoadBackupsAsync() => RunAsync(LoadBackupListAsync);

    public Task BackUpNowAsync() => RunAsync(async token =>
    {
        await client().SendAsync<object>(HttpMethod.Post, "/api/v1/server/backups/database", null, token);
        Notice = "A database backup was made on the server.";
        await LoadBackupListAsync(token);
    });

    public Task VerifyAsync(ServerBackupItem backup) => RunAsync(async token =>
    {
        var result = await client().SendAsync<BackupVerification>(HttpMethod.Post, $"/api/v1/server/backups/{Uri.EscapeDataString(backup.Name)}/verify", null, token);
        if (result.IsValid) Notice = $"The backup from {backup.CreatedAt.ToLocalTime():g} is intact.";
        else Error = $"The backup from {backup.CreatedAt.ToLocalTime():g} could not be verified. {result.Message}";
    });

    /// <summary>An encrypted copy of the whole server for keeping elsewhere; the person chooses where after the passphrase checks out.</summary>
    public Task ExportAsync(Func<Task<Stream?>> chooseDestination)
    {
        if (ExportPassphrase.Length is < 12 or > 1024) return Fail("Use a passphrase with at least 12 characters. You need it to restore the backup.");
        if (ExportPassphrase != ExportConfirmation) return Fail("The passphrases do not match.");
        return RunAsync(async token =>
        {
            await using var destination = await chooseDestination();
            if (destination is null) return;
            var export = await client().SendAsync<BackupExport>(HttpMethod.Post, "/api/v1/server/backups/export",
                new { passphrase = ExportPassphrase }, token);
            try { await client().DownloadAsync($"/api/v1/server/backups/transfers/{export.Id}", destination, token); }
            finally { await ForgetTransferAsync(export.Id); }
            ExportPassphrase = "";
            ExportConfirmation = "";
            Notice = $"The encrypted backup was saved ({Size(export.Bytes)}). Keep the passphrase with it; without it the backup cannot be opened.";
        });
    }

    /// <summary>Uploads and checks an encrypted backup; nothing changes until the restore is confirmed.</summary>
    public Task PrepareRestoreAsync(Func<Task<ChosenFile?>> chooseFile)
    {
        if (RestorePassphrase.Length is < 12 or > 1024) return Fail("Enter the backup's passphrase.");
        return RunAsync(async token =>
        {
            using var file = await chooseFile();
            if (file is null) return;
            if (file.Length is <= 0 or > 4L * 1024 * 1024 * 1024)
            {
                Error = "Choose an Aurelia backup file of at most 4 GB.";
                return;
            }
            var upload = Guid.NewGuid();
            try
            {
                await client().UploadAsync($"/api/v1/server/backups/uploads/{upload}", file.Content, file.Length, token);
                prepared = await client().SendAsync<PreparedServerRestore>(HttpMethod.Post, "/api/v1/server/backups/restore/prepare",
                    new { uploadId = upload, passphrase = RestorePassphrase, revokeAllSessions = true, acceptDifferentServerIdentity = false }, token);
            }
            finally { await ForgetTransferAsync(upload); }
            RestorePassphrase = "";
            RestoreQuestion = $"Restore the server from {file.Name}? The current library, profiles and settings are replaced, the server restarts and every device signs in again.";
            AwaitsRestoreConfirmation = true;
        });
    }

    public Task ApplyRestoreAsync() => prepared is not { } restore ? Task.CompletedTask : RunAsync(async token =>
    {
        await client().SendAsync<object>(HttpMethod.Post, $"/api/v1/server/backups/restore/{restore.Id}/apply", null, token);
        prepared = null;
        AwaitsRestoreConfirmation = false;
        Notice = "Restoring the backup. The server restarts; sign in again with the Server Password from the backup.";
    });

    public void CancelRestore()
    {
        prepared = null;
        AwaitsRestoreConfirmation = false;
    }

    public Task LoadProviderAsync() => RunAsync(async token =>
    {
        Provider = await client().SendAsync<MetadataProviderStatus>(HttpMethod.Get, "/api/v1/metadata/provider", null, token);
        ProviderEnabled = Provider.Enabled;
        Changed(nameof(ProviderAttribution));
    });

    /// <summary>Saves the TMDB token (when one was entered) and whether details are looked up.</summary>
    public Task SaveProviderAsync() => RunAsync(async token =>
    {
        var key = Token.Trim();
        Provider = await client().SendAsync<MetadataProviderStatus>(HttpMethod.Put, "/api/v1/metadata/provider",
            new UpdateMetadataProviderRequest(ProviderEnabled, Provider?.Language ?? "en-US", key.Length == 0 ? null : key), token);
        Token = "";
        ProviderEnabled = Provider.Enabled;
        Notice = "Metadata settings were saved.";
    });

    public Task RemoveTokenAsync() => RunAsync(async token =>
    {
        Provider = await client().SendAsync<MetadataProviderStatus>(HttpMethod.Delete, "/api/v1/metadata/provider/token", null, token);
        ProviderEnabled = Provider.Enabled;
        Notice = "The TMDB token was removed from the server.";
    });

    /// <summary>Looks up details and artwork for the whole library again.</summary>
    public Task EnrichAsync() => RunAsync(async token =>
    {
        var job = await client().SendAsync<MetadataJobSummary>(HttpMethod.Post, "/api/v1/metadata/jobs", null, token);
        Notice = job.ItemsTotal > 0 ? $"Looking up details for {job.ItemsTotal} titles in the background." : "Looking up details in the background.";
    });

    public Task LoadEventsAsync() => RunAsync(async token =>
    {
        var events = await client().SendAsync<IReadOnlyList<ServerEventItem>>(HttpMethod.Get, "/api/v1/server/diagnostics", null, token);
        Events.Clear();
        foreach (var item in events.OrderByDescending(item => item.At).Take(200)) Events.Add(item);
        Changed(nameof(HasEvents));
    });

    /// <summary>Server events without names, addresses or paths, for a support request.</summary>
    public Task ExportDiagnosticsAsync(Func<Task<Stream?>> chooseDestination) => RunAsync(async token =>
    {
        await using var destination = await chooseDestination();
        if (destination is null) return;
        await client().DownloadAsync("/api/v1/server/diagnostics/export", destination, token);
        Notice = "The diagnostics were saved.";
    });

    private async Task LoadBackupListAsync(CancellationToken token)
    {
        var backups = await client().SendAsync<IReadOnlyList<ServerBackupItem>>(HttpMethod.Get, "/api/v1/server/backups", null, token);
        Backups.Clear();
        foreach (var backup in backups.OrderByDescending(backup => backup.CreatedAt)) Backups.Add(backup);
        Changed(nameof(HasBackups));
    }

    /// <summary>Encrypted transfers on the server are removed once they are no longer needed.</summary>
    private async Task ForgetTransferAsync(Guid id)
    {
        try { await client().SendAsync<AureliaServerApi.NoContent>(HttpMethod.Delete, $"/api/v1/server/backups/transfers/{id}", null, CancellationToken.None); }
        catch (AureliaApiException) { }
    }

    private Task Fail(string message)
    {
        Error = message;
        return Task.CompletedTask;
    }

    private async Task RunAsync(Func<CancellationToken, Task> operation)
    {
        if (IsBusy) return;
        IsBusy = true;
        Error = null;
        Notice = null;
        try { await operation(CancellationToken.None); }
        catch (AureliaApiException error) when (error.Code == "management_locked")
        {
            Error = "Enter the Server Password again to continue.";
            Locked?.Invoke();
        }
        catch (AureliaApiException error) { Error = error.Message; }
        catch (IOException error) { Error = "The file could not be written or read. " + error.Message; }
        catch (UnauthorizedAccessException error) { Error = "The file could not be written or read. " + error.Message; }
        finally { IsBusy = false; }
    }

    private void Changed(params string[] names)
    {
        foreach (var name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string name = "", params string[] also)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Changed(name);
        Changed(also);
        return true;
    }
}
