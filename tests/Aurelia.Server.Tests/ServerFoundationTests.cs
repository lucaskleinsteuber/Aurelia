using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ServerFoundationTests
{
    [Fact]
    public void ExplicitRuntimeArgumentsOverrideDefaults()
    {
        var expectedDirectory = TestPaths.CreateDataDirectory();
        var configuration = new ConfigurationBuilder().Build();

        var runtime = ServerRuntimeOptions.Resolve(
            configuration,
            ["run", "--data-dir", expectedDirectory, "--urls", "http://127.0.0.1:45678"]);

        Assert.Equal(Path.GetFullPath(expectedDirectory), runtime.DataDirectory);
        Assert.Equal("http://127.0.0.1:45678", runtime.ListenUrl);
    }

    [Fact]
    public async Task HealthCreatesSmallValidDatabaseAndStableServerIdentity()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();

        try
        {
            Guid firstServerId;
            using (var firstFactory = new AureliaServerFactory(dataDirectory))
            using (var firstClient = firstFactory.CreateClient())
            {
                var health = await firstClient.GetFromJsonAsync<HealthResponse>(
                    "/api/v1/health",
                    ApiTestClient.JsonOptions);
                Assert.NotNull(health);
                Assert.Equal("ok", health.Status);

                var serverInfo = await firstClient.GetFromJsonAsync<ServerInfoResponse>(
                    "/api/v1/server/info",
                    ApiTestClient.JsonOptions);
                Assert.NotNull(serverInfo);
                Assert.False(serverInfo.IsSetup);
                firstServerId = serverInfo.ServerId;
            }

            using (var secondFactory = new AureliaServerFactory(dataDirectory))
            using (var secondClient = secondFactory.CreateClient())
            {
                var serverInfo = await secondClient.GetFromJsonAsync<ServerInfoResponse>(
                    "/api/v1/server/info",
                    ApiTestClient.JsonOptions);
                Assert.NotNull(serverInfo);
                Assert.Equal(firstServerId, serverInfo.ServerId);
            }

            var databasePath = Path.Combine(dataDirectory, "aurelia.db");
            Assert.True(File.Exists(databasePath));
            Assert.InRange(new FileInfo(databasePath).Length, 1, 2 * 1024 * 1024);

            await using var connection = new SqliteConnection($"Data Source={databasePath};Mode=ReadOnly");
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA integrity_check;";
            Assert.Equal("ok", await command.ExecuteScalarAsync());
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task OwnerSetupIsOneTimeAndLoginCreatesRevocableSession()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        Assert.Equal(UserRole.Owner, owner.User.Role);
        Assert.True(owner.Token.Length >= 32);

        using var duplicate = await client.PostAsJsonAsync(
            "/api/v1/setup/owner",
            new SetupOwnerRequest("other", "another secure password", "Other Mac"),
            ApiTestClient.JsonOptions);
        Assert.Equal(HttpStatusCode.Forbidden, duplicate.StatusCode);

        using var login = await client.PostAsJsonAsync(
            "/api/v1/auth/login",
            new LoginRequest("LUCAS", "correct horse battery staple", "Second Mac"),
            ApiTestClient.JsonOptions);
        login.EnsureSuccessStatusCode();
        var secondSession = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);

        using var meRequest = ApiTestClient.Authorized(
            HttpMethod.Get,
            "/api/v1/auth/me",
            secondSession.Token);
        using var meResponse = await ApiTestClient.SendAsync(client, meRequest);
        meResponse.EnsureSuccessStatusCode();
        var currentUser = await ApiTestClient.ReadAsync<UserSummary>(meResponse);
        Assert.Equal(owner.User.Id, currentUser.Id);
        Assert.Equal(UserRole.Owner, currentUser.Role);

        using var listRequest = ApiTestClient.Authorized(
            HttpMethod.Get,
            "/api/v1/auth/sessions",
            secondSession.Token);
        using var listResponse = await ApiTestClient.SendAsync(client, listRequest);
        listResponse.EnsureSuccessStatusCode();
        var sessions = await ApiTestClient.ReadAsync<List<DeviceSessionSummary>>(listResponse);
        Assert.Equal(2, sessions.Count);
        Assert.Single(sessions, session => session.IsCurrent);

        using var logoutRequest = ApiTestClient.Authorized(
            HttpMethod.Post,
            "/api/v1/auth/logout",
            secondSession.Token);
        using var logoutResponse = await ApiTestClient.SendAsync(client, logoutRequest);
        Assert.Equal(HttpStatusCode.NoContent, logoutResponse.StatusCode);

        using var rejectedRequest = ApiTestClient.Authorized(
            HttpMethod.Get,
            "/api/v1/auth/sessions",
            secondSession.Token);
        using var rejectedResponse = await ApiTestClient.SendAsync(client, rejectedRequest);
        Assert.Equal(HttpStatusCode.Unauthorized, rejectedResponse.StatusCode);
    }

    [Fact]
    public async Task OwnerCanCreateAdminsAndFinalOwnerCannotBeRemoved()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var unauthenticated = await client.GetAsync("/api/v1/users");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthenticated.StatusCode);

        using var createAdminRequest = ApiTestClient.Authorized(
            HttpMethod.Post,
            "/api/v1/users",
            owner.Token,
            new CreateUserRequest("second-admin", "secure admin password", UserRole.Admin));
        using var createAdminResponse = await ApiTestClient.SendAsync(client, createAdminRequest);
        createAdminResponse.EnsureSuccessStatusCode();
        var admin = await ApiTestClient.ReadAsync<UserSummary>(createAdminResponse);
        Assert.Equal(UserRole.Admin, admin.Role);

        using var adminLoginResponse = await client.PostAsJsonAsync(
            "/api/v1/auth/login",
            new LoginRequest("second-admin", "secure admin password", "Admin Mac"),
            ApiTestClient.JsonOptions);
        adminLoginResponse.EnsureSuccessStatusCode();
        var adminLogin = await ApiTestClient.ReadAsync<AuthenticationResponse>(adminLoginResponse);

        using var createAnotherAdminRequest = ApiTestClient.Authorized(
            HttpMethod.Post,
            "/api/v1/users",
            adminLogin.Token,
            new CreateUserRequest("third-admin", "another secure password", UserRole.Admin));
        using var createAnotherAdminResponse = await ApiTestClient.SendAsync(client, createAnotherAdminRequest);
        Assert.Equal(HttpStatusCode.Forbidden, createAnotherAdminResponse.StatusCode);

        using var createOwnerRequest = ApiTestClient.Authorized(
            HttpMethod.Post,
            "/api/v1/users",
            adminLogin.Token,
            new CreateUserRequest("forbidden-owner", "another secure password", UserRole.Owner));
        using var createOwnerResponse = await ApiTestClient.SendAsync(client, createOwnerRequest);
        Assert.Equal(HttpStatusCode.Forbidden, createOwnerResponse.StatusCode);

        using var demoteOwnerRequest = ApiTestClient.Authorized(
            HttpMethod.Put,
            $"/api/v1/users/{owner.User.Id}/role",
            owner.Token,
            new ChangeUserRoleRequest(UserRole.Admin));
        using var demoteOwnerResponse = await ApiTestClient.SendAsync(client, demoteOwnerRequest);
        Assert.Equal(HttpStatusCode.Conflict, demoteOwnerResponse.StatusCode);
    }

    [Fact]
    public async Task PairingCodeIsSingleUse()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var codeRequest = ApiTestClient.Authorized(
            HttpMethod.Post,
            "/api/v1/auth/pairings",
            owner.Token);
        using var codeResponse = await ApiTestClient.SendAsync(client, codeRequest);
        codeResponse.EnsureSuccessStatusCode();
        var pairingCode = await ApiTestClient.ReadAsync<PairingCodeResponse>(codeResponse);
        Assert.Matches("^[0-9]{8}$", pairingCode.Code);

        using var redeemResponse = await client.PostAsJsonAsync(
            "/api/v1/auth/pair",
            new RedeemPairingCodeRequest(pairingCode.Code, "Paired Mac"),
            ApiTestClient.JsonOptions);
        redeemResponse.EnsureSuccessStatusCode();
        var paired = await ApiTestClient.ReadAsync<AuthenticationResponse>(redeemResponse);
        Assert.Equal(owner.User.Id, paired.User.Id);

        using var replayResponse = await client.PostAsJsonAsync(
            "/api/v1/auth/pair",
            new RedeemPairingCodeRequest(pairingCode.Code, "Replay Mac"),
            ApiTestClient.JsonOptions);
        Assert.Equal(HttpStatusCode.Unauthorized, replayResponse.StatusCode);
    }

    [Fact]
    public async Task PasswordsTokensAndPairingCodesAreHashedAtRest()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        const string password = "correct horse battery staple";
        var owner = await ApiTestClient.SetupOwnerAsync(client, password: password);

        using var codeRequest = ApiTestClient.Authorized(
            HttpMethod.Post,
            "/api/v1/auth/pairings",
            owner.Token);
        using var codeResponse = await ApiTestClient.SendAsync(client, codeRequest);
        codeResponse.EnsureSuccessStatusCode();
        var pairing = await ApiTestClient.ReadAsync<PairingCodeResponse>(codeResponse);

        var databasePath = Path.Combine(factory.DataDirectory, "aurelia.db");
        await using var connection = new SqliteConnection(
            $"Data Source={databasePath};Mode=ReadOnly;Cache=Shared");
        await connection.OpenAsync();

        var passwordHash = await ScalarStringAsync(connection, "SELECT PasswordHash FROM Users LIMIT 1;");
        var tokenHash = await ScalarStringAsync(connection, "SELECT TokenHash FROM DeviceSessions LIMIT 1;");
        var codeHash = await ScalarStringAsync(connection, "SELECT CodeHash FROM PairingCodes LIMIT 1;");

        Assert.NotEqual(password, passwordHash);
        Assert.NotEqual(owner.Token, tokenHash);
        Assert.NotEqual(pairing.Code, codeHash);
        Assert.Matches("^[0-9A-F]{64}$", tokenHash);
        Assert.Matches("^[0-9A-F]{64}$", codeHash);
    }

    [Fact]
    public void DataDirectoryAllowsOnlyOneServerInstance()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();

        try
        {
            using var first = ServerInstanceLock.Acquire(dataDirectory);
            Assert.Throws<InvalidOperationException>(() =>
                ServerInstanceLock.Acquire(dataDirectory));
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    private static async Task<string> ScalarStringAsync(SqliteConnection connection, string sql)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Assert.IsType<string>(await command.ExecuteScalarAsync());
    }
}
