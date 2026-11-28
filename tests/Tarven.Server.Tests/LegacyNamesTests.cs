using Tarven.Server.Authentication;
using Tarven.Server.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace Tarven.Server.Tests;

/// <summary>
/// Tarven was called Aurelia until server 3.0.0: a server takes over its data, settings and
/// backups from that time, and apps from that time still reach it. Synthetic folders only.
/// </summary>
public sealed class LegacyNamesTests
{
    [Fact]
    public void TheDefaultDataFolderOfTheOldNameIsTakenOverOnce()
    {
        var root = Directory.CreateTempSubdirectory("tarven-legacy-");
        try
        {
            var legacy = Path.Combine(root.FullName, LegacyNames.ServerFolderName);
            var current = Path.Combine(root.FullName, "Tarven Server");
            Directory.CreateDirectory(legacy);
            File.WriteAllText(Path.Combine(legacy, "server-settings.json"), "{}");

            Assert.Equal(current, LegacyNames.AdoptDefaultDataDirectory(current, legacy));
            Assert.False(Directory.Exists(legacy));
            Assert.Equal("{}", File.ReadAllText(Path.Combine(current, "server-settings.json")));
            // Once the new folder exists, an old one is left alone.
            Directory.CreateDirectory(legacy);
            Assert.Equal(current, LegacyNames.AdoptDefaultDataDirectory(current, legacy));
            Assert.True(Directory.Exists(legacy));
        }
        finally { root.Delete(recursive: true); }
    }

    [Fact]
    public void AFolderAServerStillUsesIsNotMoved()
    {
        var root = Directory.CreateTempSubdirectory("tarven-legacy-");
        try
        {
            var legacy = Path.Combine(root.FullName, LegacyNames.ServerFolderName);
            var current = Path.Combine(root.FullName, "Tarven Server");
            using (ServerInstanceLock.Acquire(legacy))
            {
                Assert.Equal(legacy, LegacyNames.AdoptDefaultDataDirectory(current, legacy));
                Assert.False(Directory.Exists(current));
            }
        }
        finally { root.Delete(recursive: true); }
    }

    [Fact]
    public void TheDatabaseItsJournalAndItsBackupsGetTheirNewNames()
    {
        var root = Directory.CreateTempSubdirectory("tarven-legacy-");
        try
        {
            var data = root.FullName;
            File.WriteAllText(Path.Combine(data, "aurelia.db"), "db");
            File.WriteAllText(Path.Combine(data, "aurelia.db-wal"), "wal");
            File.WriteAllText(Path.Combine(data, "aurelia.db-shm"), "shm");
            var backups = Directory.CreateDirectory(Path.Combine(data, "Backups")).FullName;
            File.WriteAllText(Path.Combine(backups, "aurelia-database-daily-20261127T000000000Z.db"), "daily");

            LegacyNames.AdoptDatabase(data);

            Assert.Equal(Path.Combine(data, "tarven.db"), LegacyNames.DatabasePath(data));
            Assert.Equal("db", File.ReadAllText(Path.Combine(data, "tarven.db")));
            Assert.Equal("wal", File.ReadAllText(Path.Combine(data, "tarven.db-wal")));
            Assert.Equal("shm", File.ReadAllText(Path.Combine(data, "tarven.db-shm")));
            Assert.False(File.Exists(Path.Combine(data, "aurelia.db")));
            Assert.Equal("daily", File.ReadAllText(Path.Combine(backups, "tarven-database-daily-20261127T000000000Z.db")));

            // A database under the new name is never replaced by a leftover old one.
            File.WriteAllText(Path.Combine(data, "aurelia.db"), "stale");
            LegacyNames.AdoptDatabase(data);
            Assert.Equal("db", File.ReadAllText(Path.Combine(data, "tarven.db")));
        }
        finally { root.Delete(recursive: true); }
    }

    [Fact]
    public void HeadersOfAppsFromBeforeTheRenameAreRead()
    {
        var old = new DefaultHttpContext();
        old.Request.Headers["X-Aurelia-Client"] = "ios/2.23.0";
        old.Request.Headers["X-Aurelia-Background"] = "1";
        Assert.Equal("ios/2.23.0", LegacyNames.Header(old.Request, ClientIdentity.ClientHeader));
        Assert.True(LegacyNames.HasHeader(old.Request, ServerUseClock.BackgroundHeader));

        var both = new DefaultHttpContext();
        both.Request.Headers["X-Tarven-Client"] = "macos/3.0.0";
        both.Request.Headers["X-Aurelia-Client"] = "macos/2.30.0";
        Assert.Equal("macos/3.0.0", LegacyNames.Header(both.Request, ClientIdentity.ClientHeader));
        Assert.Null(LegacyNames.Header(new DefaultHttpContext().Request, ClientIdentity.ClientHeader));
        Assert.False(LegacyNames.HasHeader(new DefaultHttpContext().Request, ServerUseClock.BackgroundHeader));
    }

    [Fact]
    public void ABrowserSignedInBeforeTheRenameStaysSignedIn()
    {
        var context = new DefaultHttpContext();
        context.Request.Headers["X-Aurelia-Web"] = "device";
        context.Request.Headers.Cookie = "aurelia_device=old-device-token";
        Assert.Equal("old-device-token", WebCookies.Credential(context.Request));

        var renamed = new DefaultHttpContext();
        renamed.Request.Headers[WebCookies.Header] = "device";
        renamed.Request.Headers.Cookie = "aurelia_device=old; tarven_device=new";
        Assert.Equal("new", WebCookies.Credential(renamed.Request));

        // Signing out removes the cookie under both names.
        var signOut = new DefaultHttpContext();
        WebCookies.Delete(signOut, WebCookies.Device);
        var cleared = string.Join('\n', signOut.Response.Headers.SetCookie.ToArray());
        Assert.Contains("tarven_device=", cleared, StringComparison.Ordinal);
        Assert.Contains("aurelia_device=", cleared, StringComparison.Ordinal);
    }

    [Fact]
    public void SettingsUnderTheOldNameStillApply()
    {
        var configuration = new ConfigurationManager();
        configuration.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Aurelia:Ffmpeg"] = "/opt/old/ffmpeg",
            ["Aurelia:HardwareEncoding"] = "off",
            ["Tarven:HardwareEncoding"] = "vaapi",
        });
        LegacyNames.MapConfiguration(configuration);
        Assert.Equal("/opt/old/ffmpeg", configuration["Tarven:Ffmpeg"]);
        Assert.Equal("vaapi", configuration["Tarven:HardwareEncoding"]);
    }

    [Fact]
    public void BackupsAndMovingFilesFromBeforeTheRenameAreRestoredUnderTheNewName()
    {
        Assert.True(EncryptedBackupContainer.AllowedName("aurelia.db"));
        Assert.True(EncryptedBackupContainer.IsDatabase("aurelia.db"));
        Assert.Equal("tarven.db", EncryptedBackupContainer.RestoredName("aurelia.db"));
        Assert.Equal("server-settings.json", EncryptedBackupContainer.RestoredName("server-settings.json"));
    }

    [Fact]
    public void ServerCommandsAcceptConfigurationUnderTheOldName()
    {
        var parsed = ServerCommandLine.Parse(["run", "--Aurelia:Ffmpeg", "/opt/ffmpeg"]);
        Assert.Null(parsed.Error);
    }
}
