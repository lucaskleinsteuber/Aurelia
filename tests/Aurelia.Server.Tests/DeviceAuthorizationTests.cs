using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class DeviceAuthorizationTests
{
    [Fact]
    public async Task ApprovedCredentialCanBeRetrievedAgainAndOnlyAcknowledgementCompletesDelivery()
    {
        var clock = new PairingClock();
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var pairing = await StartAsync(client);
        Assert.Equal(8, pairing.Code.Length);
        Assert.All(pairing.Code, character => Assert.True(char.IsAsciiDigit(character)));
        Assert.Equal(clock.GetUtcNow().AddMinutes(5), pairing.ExpiresAt);
        Assert.Equal(5, pairing.PollIntervalSeconds);
        var preview = await LookupAsync(client, owner, pairing.Code);
        Assert.Equal("Living Room TV", preview.DeviceName);
        Assert.Equal(pairing.Id, preview.Id);
        Assert.Equal(DeviceAuthorizationState.Pending, (await StatusAsync(client, pairing)).State);

        using (var proofless = ApiTestClient.Authorized(HttpMethod.Post, DecisionPath(pairing, true), owner.Token))
        using (var rejected = await client.SendAsync(proofless))
        {
            Assert.Equal(HttpStatusCode.Forbidden, rejected.StatusCode);
            Assert.Equal("approval_required", (await ApiTestClient.ReadAsync<ApiProblem>(rejected)).Code);
        }
        await DecideAsync(client, owner, pairing, true);
        await DecideAsync(client, owner, pairing, true); // A lost approval response creates no extra device.
        clock.Advance(TimeSpan.FromSeconds(5));
        var delivered = await StatusAsync(client, pairing);
        var credential = Assert.IsType<AuthenticationResponse>(delivered.Authentication);
        Assert.Equal(DeviceAuthorizationState.Approved, delivered.State);
        Assert.False(delivered.Acknowledged);
        clock.Advance(TimeSpan.FromSeconds(5));
        Assert.Equal(credential.Token, (await StatusAsync(client, pairing)).Authentication!.Token);

        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.Equal(2, await database.DeviceSessions.CountAsync());
            var stored = await database.DeviceAuthorizationRequests.SingleAsync();
            Assert.NotEqual(pairing.Code, stored.CodeHash);
            Assert.NotEqual(pairing.Secret, stored.SecretHash);
            Assert.Equal(64, stored.CodeHash.Length);
            Assert.Equal(64, stored.SecretHash.Length);
            Assert.NotNull(stored.ProtectedAuthentication);
            Assert.DoesNotContain(credential.Token, stored.ProtectedAuthentication, StringComparison.Ordinal);
        }
        using (var home = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/home", credential.Token))
        using (var unauthorized = await client.SendAsync(home)) Assert.Equal(HttpStatusCode.Forbidden, unauthorized.StatusCode);
        await AssertPickerAsync(client, credential.Token, HttpStatusCode.OK);

        var acknowledged = await SecretActionAsync(client, pairing, "ack");
        Assert.True(acknowledged.Acknowledged);
        Assert.Null(acknowledged.Authentication);
        Assert.True((await SecretActionAsync(client, pairing, "ack")).Acknowledged);
        clock.Advance(TimeSpan.FromMinutes(6));
        Assert.Null((await StatusAsync(client, pairing)).Authentication);
        await AssertPickerAsync(client, credential.Token, HttpStatusCode.OK);
        using var finalScope = factory.Services.CreateScope();
        var final = await finalScope.ServiceProvider.GetRequiredService<AureliaDbContext>().DeviceAuthorizationRequests.SingleAsync();
        Assert.Null(final.ProtectedAuthentication);
        Assert.NotNull(final.AcknowledgedAt);
    }

    [Fact]
    public async Task PollingTooQuicklyOrWithWrongSecretsCannotReceiveOrCancelACredential()
    {
        var clock = new PairingClock();
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var pairing = await StartAsync(client);
        foreach (var action in new[] { "status", "ack", "cancel" })
        {
            using var wrong = await client.PostAsJsonAsync($"/api/v1/auth/device-pairings/{pairing.Id}/{action}",
                new DeviceAuthorizationSecretRequest(new string('x', 43)), ApiTestClient.JsonOptions);
            Assert.Equal(HttpStatusCode.NotFound, wrong.StatusCode);
        }
        Assert.Equal(DeviceAuthorizationState.Pending, (await StatusAsync(client, pairing)).State);
        using (var tooFast = await client.PostAsJsonAsync($"/api/v1/auth/device-pairings/{pairing.Id}/status",
            new DeviceAuthorizationSecretRequest(pairing.Secret), ApiTestClient.JsonOptions))
        {
            Assert.Equal(HttpStatusCode.TooManyRequests, tooFast.StatusCode);
            Assert.Equal("device_pairing_slow_down", (await ApiTestClient.ReadAsync<ApiProblem>(tooFast)).Code);
        }
        await DecideAsync(client, owner, pairing, true);
        clock.Advance(TimeSpan.FromSeconds(5));
        var credential = (await StatusAsync(client, pairing)).Authentication!;
        Assert.Equal(DeviceAuthorizationState.Cancelled, (await SecretActionAsync(client, pairing, "cancel")).State);
        Assert.Equal(DeviceAuthorizationState.Cancelled, (await SecretActionAsync(client, pairing, "cancel")).State);
        await AssertPickerAsync(client, credential.Token, HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task UnacknowledgedCredentialExpiresImmediatelyWithoutWaitingForMaintenance()
    {
        var clock = new PairingClock();
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var pairing = await StartAsync(client);
        await DecideAsync(client, owner, pairing, true);
        var credential = (await StatusAsync(client, pairing)).Authentication!;
        clock.Advance(TimeSpan.FromMinutes(5));
        await AssertPickerAsync(client, credential.Token, HttpStatusCode.Unauthorized);
        using (var scope = factory.Services.CreateScope())
        {
            var session = await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().DeviceSessions.SingleAsync(value => value.Id == credential.SessionId);
            Assert.Null(session.RevokedAt); // The authentication predicate itself enforces the deadline.
        }
        var expired = await StatusAsync(client, pairing);
        Assert.Equal(DeviceAuthorizationState.Expired, expired.State);
        Assert.Null(expired.Authentication);
        using var acknowledgement = await client.PostAsJsonAsync($"/api/v1/auth/device-pairings/{pairing.Id}/ack",
            new DeviceAuthorizationSecretRequest(pairing.Secret), ApiTestClient.JsonOptions);
        Assert.Equal(HttpStatusCode.Conflict, acknowledgement.StatusCode);
    }

    [Fact]
    public async Task DeletedUnacknowledgedDeviceExpiresItsDeliveryAfterForeignKeyBecomesNull()
    {
        var clock = new PairingClock();
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var pairing = await StartAsync(client);
        await DecideAsync(client, owner, pairing, true);
        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var deviceId = await database.DeviceAuthorizationRequests.Select(request => request.DeviceSessionId).SingleAsync();
            Assert.NotNull(deviceId);
            Assert.Equal(1, await database.DeviceSessions.Where(session => session.Id == deviceId).ExecuteDeleteAsync());
            var receipt = await database.DeviceAuthorizationRequests.AsNoTracking().SingleAsync();
            Assert.Null(receipt.DeviceSessionId);
            Assert.Equal(DeviceAuthorizationState.Approved, receipt.State);
            Assert.NotNull(receipt.ProtectedAuthentication);
        }
        var status = await StatusAsync(client, pairing);
        Assert.Equal(DeviceAuthorizationState.Expired, status.State);
        Assert.Null(status.Authentication);
        Assert.False(status.Acknowledged);
        using var finalScope = factory.Services.CreateScope();
        var final = finalScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.Null((await final.DeviceAuthorizationRequests.SingleAsync()).ProtectedAuthentication);
        Assert.Single(await final.DeviceSessions.ToListAsync());
    }

    [Fact]
    public async Task PendingRequestsExpireAndDeniedOrCancelledRequestsCreateNoDevices()
    {
        var clock = new PairingClock();
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var denied = await StartAsync(client);
        await DecideAsync(client, owner, denied, false);
        await DecideAsync(client, owner, denied, false);
        Assert.Equal(DeviceAuthorizationState.Denied, (await StatusAsync(client, denied)).State);
        var cancelled = await StartAsync(client);
        Assert.Equal(DeviceAuthorizationState.Cancelled, (await SecretActionAsync(client, cancelled, "cancel")).State);
        var expired = await StartAsync(client);
        clock.Advance(TimeSpan.FromMinutes(5));
        Assert.Equal(DeviceAuthorizationState.Expired, (await StatusAsync(client, expired)).State);
        using var lookup = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/device-pairings/lookup", owner.Token,
            new DeviceAuthorizationLookupRequest(expired.Code));
        using var invalid = await client.SendAsync(lookup);
        Assert.Equal(HttpStatusCode.NotFound, invalid.StatusCode);
        using var scope = factory.Services.CreateScope();
        Assert.Single(await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().DeviceSessions.ToListAsync());
    }

    [Fact]
    public async Task ManagementLockAndDisabledPairingPreventApprovalWithoutLosingExistingDevices()
    {
        var clock = new PairingClock();
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var pairing = await StartAsync(client);
        var approvedPairing = await StartAsync(client);
        await DecideAsync(client, owner, approvedPairing, true);
        var unacknowledged = (await StatusAsync(client, approvedPairing)).Authentication!;
        using (var locking = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/lock", owner.Token))
        using (var locked = await client.SendAsync(locking)) locked.EnsureSuccessStatusCode();
        using (var lookup = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/device-pairings/lookup", owner.Token,
            new DeviceAuthorizationLookupRequest(pairing.Code)))
        using (var rejected = await client.SendAsync(lookup))
        {
            Assert.Equal(HttpStatusCode.Forbidden, rejected.StatusCode);
            Assert.Equal("management_locked", (await ApiTestClient.ReadAsync<ApiProblem>(rejected)).Code);
        }
        var configuration = factory.Services.GetRequiredService<ServerConfigurationStore>();
        configuration.Update(configuration.Current with { PairingEnabled = false });
        using (var disabled = await client.PostAsJsonAsync("/api/v1/auth/device-pairings",
            new DeviceAuthorizationStartRequest("Another TV"), ApiTestClient.JsonOptions))
        {
            Assert.Equal(HttpStatusCode.Forbidden, disabled.StatusCode);
            Assert.Equal("pairing_disabled", (await ApiTestClient.ReadAsync<ApiProblem>(disabled)).Code);
        }
        Assert.Equal(DeviceAuthorizationState.Expired, (await StatusAsync(client, pairing)).State);
        await AssertPickerAsync(client, unacknowledged.Token, HttpStatusCode.Unauthorized);
        using var home = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/home", owner.Token);
        using var available = await client.SendAsync(home);
        available.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task PublicStartAndOwnerLookupHaveIndependentLimits()
    {
        var clock = new PairingClock();
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var pairing = await StartAsync(client);
        for (var index = 0; index < 10; index++)
        {
            using var lookup = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/device-pairings/lookup", owner.Token,
                new DeviceAuthorizationLookupRequest("not-a-code"));
            using var rejected = await client.SendAsync(lookup);
            Assert.Equal(HttpStatusCode.NotFound, rejected.StatusCode);
        }
        using (var limitedLookup = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/device-pairings/lookup", owner.Token,
            new DeviceAuthorizationLookupRequest(pairing.Code)))
        using (var limited = await client.SendAsync(limitedLookup)) Assert.Equal(HttpStatusCode.TooManyRequests, limited.StatusCode);
        for (var index = 1; index < 5; index++) _ = await StartAsync(client);
        using (var limitedStart = await client.PostAsJsonAsync("/api/v1/auth/device-pairings",
            new DeviceAuthorizationStartRequest("Limited TV"), ApiTestClient.JsonOptions)) Assert.Equal(HttpStatusCode.TooManyRequests, limitedStart.StatusCode);
        Assert.Equal(DeviceAuthorizationState.Pending, (await StatusAsync(client, pairing)).State);
    }

    [Fact]
    public async Task ApprovalProofIsBoundToExactActionAndAdministratorsCannotApproveDevices()
    {
        var clock = new PairingClock();
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var pairing = await StartAsync(client);
        using var proofRequest = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/approval", owner.Token,
            new AdministrationApprovalRequest("POST " + DecisionPath(pairing, true), AdministrationApprovalStore.Hash([])));
        using var proofResponse = await client.SendAsync(proofRequest);
        proofResponse.EnsureSuccessStatusCode();
        var proof = await ApiTestClient.ReadAsync<AdministrationApprovalResponse>(proofResponse);
        foreach (var approve in new[] { false, true })
        {
            using var wrongAction = ApiTestClient.Authorized(HttpMethod.Post, DecisionPath(pairing, approve), owner.Token);
            wrongAction.Headers.Add("X-Aurelia-Approval", proof.Token);
            using var rejected = await client.SendAsync(wrongAction);
            Assert.Equal(HttpStatusCode.Forbidden, rejected.StatusCode);
            Assert.Equal("approval_required", (await ApiTestClient.ReadAsync<ApiProblem>(rejected)).Code);
        }
        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var user = await database.Users.SingleAsync(value => value.Id == owner.User.Id);
            user.Role = UserRole.Admin;
            await database.SaveChangesAsync();
        }
        using (var lookup = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/device-pairings/lookup", owner.Token,
            new DeviceAuthorizationLookupRequest(pairing.Code)))
        using (var rejected = await client.SendAsync(lookup)) Assert.Equal(HttpStatusCode.Forbidden, rejected.StatusCode);
        using (var approve = ApiTestClient.Authorized(HttpMethod.Post, DecisionPath(pairing, true), owner.Token))
        using (var rejected = await client.SendAsync(approve)) Assert.Equal(HttpStatusCode.Forbidden, rejected.StatusCode);
        using var finalScope = factory.Services.CreateScope();
        var final = finalScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.Equal(DeviceAuthorizationState.Pending, (await final.DeviceAuthorizationRequests.SingleAsync()).State);
        Assert.Single(await final.DeviceSessions.ToListAsync());
    }

    [Fact]
    public async Task FailedApprovalWriteLeavesNoPartialDeviceAndRetryCanCompleteTheSameRequest()
    {
        var failure = new PairingWriteFailure();
        using var factory = new AureliaServerFactory(configureServices: services =>
            services.ConfigureDbContext<AureliaDbContext>((_, options) => options.AddInterceptors(failure)));
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var pairing = await StartAsync(client);
        failure.FailNext = true;
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, DecisionPath(pairing, true), owner.Token))
        using (var rejected = await ApiTestClient.SendAsync(client, request)) Assert.Equal(HttpStatusCode.ServiceUnavailable, rejected.StatusCode);
        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.Single(await database.DeviceSessions.ToListAsync());
            var stored = await database.DeviceAuthorizationRequests.SingleAsync();
            Assert.Equal(DeviceAuthorizationState.Pending, stored.State);
            Assert.Null(stored.DeviceSessionId);
            Assert.Null(stored.ProtectedAuthentication);
        }
        await DecideAsync(client, owner, pairing, true);
        var delivered = (await StatusAsync(client, pairing)).Authentication!;
        await AssertPickerAsync(client, delivered.Token, HttpStatusCode.OK);
        using var finalScope = factory.Services.CreateScope();
        Assert.Equal(2, await finalScope.ServiceProvider.GetRequiredService<AureliaDbContext>().DeviceSessions.CountAsync());
    }

    [Fact]
    public async Task ApprovalQueuedBeforeLockCannotBorrowTheNextManagementUnlock()
    {
        var clock = new PairingClock();
        using var factory = Factory(clock);
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var pairing = await StartAsync(client);
        var profiles = factory.Services.GetRequiredService<ProfileSessionStore>();
        var profile = profiles.Find(factory.Services.GetRequiredService<TokenService>().Hash(owner.Token))!;
        var generation = profiles.CurrentManagementGrant(profile.Id)!.Generation;
        profiles.LockManagement(profile.Id);
        profiles.UnlockManagement(profile.Id);
        using var scope = factory.Services.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DeviceAuthorizationService>();
        var rejected = await Assert.ThrowsAsync<AccountException>(() => service.DecideAsync(pairing.Id, true,
            owner.User.Id, owner.SessionId, profile.Id, generation, CancellationToken.None));
        Assert.Equal("management_locked", rejected.Code);
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.Single(await database.DeviceSessions.ToListAsync());
        Assert.Equal(DeviceAuthorizationState.Pending, (await database.DeviceAuthorizationRequests.SingleAsync()).State);
    }

    [Fact]
    public async Task RestartKeepsTheEncryptedUnacknowledgedDeliveryWithoutCreatingAnotherDevice()
    {
        var directory = TestPaths.CreateDataDirectory();
        var clock = new PairingClock();
        try
        {
            DeviceAuthorizationStartResponse pairing;
            AuthenticationResponse delivered;
            using (var first = Factory(clock, directory))
            using (var client = first.CreateClient())
            {
                var owner = await ApiTestClient.SetupOwnerAsync(client);
                pairing = await StartAsync(client);
                await DecideAsync(client, owner, pairing, true);
                delivered = (await StatusAsync(client, pairing)).Authentication!;
            }
            clock.Advance(TimeSpan.FromSeconds(5));
            using var restarted = Factory(clock, directory);
            using var nextClient = restarted.CreateClient();
            var redelivered = (await StatusAsync(nextClient, pairing)).Authentication!;
            Assert.Equal(delivered.Token, redelivered.Token);
            Assert.Equal(delivered.SessionId, redelivered.SessionId);
            await AssertPickerAsync(nextClient, redelivered.Token, HttpStatusCode.OK);
            await SecretActionAsync(nextClient, pairing, "ack");
            using var scope = restarted.Services.CreateScope();
            Assert.Equal(2, await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().DeviceSessions.CountAsync());
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RestoresInvalidateOpenAndApprovedDeliveries(bool fullBackup)
    {
        var directory = TestPaths.CreateDataDirectory();
        var clock = new PairingClock();
        var runtime = ServerRuntimeOptions.Resolve(new ConfigurationBuilder().Build(), ["--data-dir", directory]);
        try
        {
            DeviceAuthorizationStartResponse pending;
            DeviceAuthorizationStartResponse approved;
            AuthenticationResponse delivered;
            string backupPath;
            using (var factory = Factory(clock, directory))
            using (var client = factory.CreateClient())
            {
                var owner = await ApiTestClient.SetupOwnerAsync(client);
                pending = await StartAsync(client);
                approved = await StartAsync(client);
                await DecideAsync(client, owner, approved, true);
                delivered = (await StatusAsync(client, approved)).Authentication!;
                var backups = factory.Services.GetRequiredService<DatabaseBackupService>();
                if (fullBackup)
                {
                    var full = factory.Services.GetRequiredService<FullServerBackupService>();
                    var exported = await full.ExportAsync("synthetic pairing backup passphrase", CancellationToken.None);
                    backupPath = full.TransferPath(exported.Id);
                }
                else backupPath = await backups.CreateBackupAsync(DatabaseBackupKind.Manual, CancellationToken.None);
            }
            using (ServerInstanceLock.Acquire(directory))
            {
                var backups = new DatabaseBackupService(runtime);
                if (fullBackup)
                {
                    using var full = new FullServerBackupService(runtime, backups, new ServerConfigurationStore(runtime));
                    var uploadId = Guid.ParseExact(Path.GetFileNameWithoutExtension(backupPath), "N");
                    var prepared = await full.PrepareRestoreAsync(new(uploadId, "synthetic pairing backup passphrase", true), CancellationToken.None);
                    await FullServerBackupService.ApplyPreparedAsync(runtime, prepared.Id, CancellationToken.None);
                }
                else await backups.RestoreAsync(backupPath, CancellationToken.None);
            }
            clock.Advance(TimeSpan.FromSeconds(5));
            using var restored = Factory(clock, directory);
            using var restoredClient = restored.CreateClient();
            Assert.Equal(DeviceAuthorizationState.Expired, (await StatusAsync(restoredClient, pending)).State);
            Assert.Equal(DeviceAuthorizationState.Expired, (await StatusAsync(restoredClient, approved)).State);
            await AssertPickerAsync(restoredClient, delivered.Token, HttpStatusCode.Unauthorized);
            using var scope = restored.Services.CreateScope();
            Assert.All(await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().DeviceAuthorizationRequests.ToListAsync(),
                request => Assert.Null(request.ProtectedAuthentication));
        }
        finally { Directory.Delete(directory, true); }
    }

    private static AureliaServerFactory Factory(PairingClock clock, string? directory = null) => new(directory, configureServices: services =>
    {
        services.RemoveAll<TimeProvider>();
        services.AddSingleton<TimeProvider>(clock);
    });

    private static async Task<DeviceAuthorizationStartResponse> StartAsync(HttpClient client)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/auth/device-pairings", new DeviceAuthorizationStartRequest("Living Room TV"), ApiTestClient.JsonOptions);
        response.EnsureSuccessStatusCode();
        Assert.Contains("no-store", response.Headers.CacheControl!.ToString(), StringComparison.Ordinal);
        return await ApiTestClient.ReadAsync<DeviceAuthorizationStartResponse>(response);
    }

    private static async Task<DeviceAuthorizationPreview> LookupAsync(HttpClient client, AuthenticationResponse owner, string code)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/server/device-pairings/lookup", owner.Token,
            new DeviceAuthorizationLookupRequest(code));
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<DeviceAuthorizationPreview>(response);
    }

    private static string DecisionPath(DeviceAuthorizationStartResponse pairing, bool approve) =>
        $"/api/v1/server/device-pairings/{pairing.Id}/{(approve ? "approve" : "deny")}";

    private static async Task DecideAsync(HttpClient client, AuthenticationResponse owner, DeviceAuthorizationStartResponse pairing, bool approve)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, DecisionPath(pairing, approve), owner.Token);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        var decided = await ApiTestClient.ReadAsync<DeviceAuthorizationPreview>(response);
        Assert.Equal(approve ? DeviceAuthorizationState.Approved : DeviceAuthorizationState.Denied, decided.State);
    }

    private static Task<DeviceAuthorizationStatusResponse> StatusAsync(HttpClient client, DeviceAuthorizationStartResponse pairing) => SecretActionAsync(client, pairing, "status");

    private static async Task<DeviceAuthorizationStatusResponse> SecretActionAsync(HttpClient client, DeviceAuthorizationStartResponse pairing, string action)
    {
        using var response = await client.PostAsJsonAsync($"/api/v1/auth/device-pairings/{pairing.Id}/{action}",
            new DeviceAuthorizationSecretRequest(pairing.Secret), ApiTestClient.JsonOptions);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<DeviceAuthorizationStatusResponse>(response);
    }

    private static async Task AssertPickerAsync(HttpClient client, string deviceToken, HttpStatusCode status)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/profiles", deviceToken);
        using var response = await client.SendAsync(request);
        Assert.Equal(status, response.StatusCode);
    }

    private sealed class PairingClock : TimeProvider
    {
        private long ticks = DateTimeOffset.UtcNow.UtcTicks;
        public override DateTimeOffset GetUtcNow() => new(Interlocked.Read(ref ticks), TimeSpan.Zero);
        public void Advance(TimeSpan interval) => Interlocked.Add(ref ticks, interval.Ticks);
    }

    private sealed class PairingWriteFailure : SaveChangesInterceptor
    {
        public bool FailNext { get; set; }
        public override ValueTask<InterceptionResult<int>> SavingChangesAsync(DbContextEventData eventData,
            InterceptionResult<int> result, CancellationToken cancellationToken = default)
        {
            if (FailNext && eventData.Context!.ChangeTracker.Entries<DeviceSession>()
                .Any(entry => entry.State == EntityState.Added && entry.Entity.DeviceName == "Living Room TV"))
            {
                FailNext = false;
                throw new SqliteException("synthetic pairing storage failure", 13);
            }
            return ValueTask.FromResult(result);
        }
    }
}
