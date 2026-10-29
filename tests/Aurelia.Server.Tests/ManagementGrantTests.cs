using System.Net;
using System.Security.Claims;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ManagementGrantTests
{
    [Theory]
    [InlineData("/api/v1/management/approval")]
    [InlineData("/api/v1/server/approval")]
    [InlineData("/api/v1/libraries/reset/approval")]
    public async Task UnlockedManagementIssuesApprovalsWithoutAnotherPassword(string route)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var action = route.Contains("reset", StringComparison.Ordinal) ? "POST /api/v1/libraries/reset" : "POST /api/v1/users";
        using var request = ApiTestClient.Authorized(HttpMethod.Post, route, owner.Token,
            new AdministrationApprovalRequest(action, AdministrationApprovalStore.Hash([])));
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        var approval = await ApiTestClient.ReadAsync<AdministrationApprovalResponse>(response);
        Assert.True(approval.ExpiresAt > DateTimeOffset.UtcNow);
        Assert.True(approval.ExpiresAt <= DateTimeOffset.UtcNow.AddMinutes(2));
    }

    [Fact]
    public async Task LegacyPasswordIsIgnoredAndNoAuthenticationThrottleAppliesToApprovalIssuance()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        for (var index = 0; index < 16; index++)
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/approval", owner.Token,
                new AdministrationApprovalRequest("POST /api/v1/users", AdministrationApprovalStore.Hash([]), "not-a-server-password"));
            using var response = await client.SendAsync(request);
            response.EnsureSuccessStatusCode();
        }
    }

    [Fact]
    public async Task LockingManagementDoesNotLockPersonalCatalogOrAllowPasswordBypass()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/lock", owner.Token))
        using (var response = await client.SendAsync(request)) response.EnsureSuccessStatusCode();
        foreach (var path in new[] { "/api/v1/home", "/api/v1/catalog/items" })
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, path, owner.Token);
            using var response = await client.SendAsync(request);
            response.EnsureSuccessStatusCode();
        }
        foreach (var path in new[] { "/api/v1/management/approval", "/api/v1/server/approval" })
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Post, path, owner.Token,
                new AdministrationApprovalRequest("POST /api/v1/users", AdministrationApprovalStore.Hash([]), "correct horse battery staple"));
            using var response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
            Assert.Equal("management_locked", (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
        }
    }

    [Fact]
    public async Task ExpectedManagementStatesAreInformationalAndNotDuplicatedAsAccessWarnings()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset", owner.Token,
            new ResetLibraryRequest([], "rev-1")))
        using (var response = await client.SendAsync(request)) Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/lock", owner.Token))
        using (var response = await client.SendAsync(request)) response.EnsureSuccessStatusCode();
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/approval", owner.Token,
            new AdministrationApprovalRequest("POST /api/v1/libraries/reset", AdministrationApprovalStore.Hash([]))))
        using (var response = await client.SendAsync(request)) Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        var diagnostics = factory.Services.GetRequiredService<ServerDiagnosticsStore>();
        await diagnostics.FlushAsync(CancellationToken.None);
        var entries = diagnostics.Read();
        Assert.Equal("information", Assert.Single(entries, entry => entry.Code == "approval_required").Severity);
        Assert.Equal("information", Assert.Single(entries, entry => entry.Code == "management_locked").Severity);
        Assert.DoesNotContain(entries, entry => entry.Code == "access_rejected");
    }

    [Fact]
    public async Task GenuineAuthenticationAndAuthorizationFailuresRemainWarnings()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/unlock", owner.Token,
            new UnlockManagementRequest("incorrect synthetic password")))
        using (var response = await client.SendAsync(request)) Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var user = await database.Users.SingleAsync(value => value.Id == owner.User.Id);
            user.Role = UserRole.User;
            await database.SaveChangesAsync();
        }
        using (var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/users", owner.Token))
        using (var response = await client.SendAsync(request)) Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        var diagnostics = factory.Services.GetRequiredService<ServerDiagnosticsStore>();
        await diagnostics.FlushAsync(CancellationToken.None);
        var entries = diagnostics.Read();
        Assert.Equal("warning", Assert.Single(entries, entry => entry.Code == "invalid_credentials").Severity);
        Assert.DoesNotContain(entries, entry => entry.Code == "authentication_rejected");
        Assert.Equal("warning", Assert.Single(entries, entry => entry.Code == "access_rejected").Severity);
    }

    [Fact]
    public void ProofsAreBoundToUnlockGenerationAndCanNeverExtendItsDeadline()
    {
        var clock = new GrantClock();
        using var sessions = new ProfileSessionStore(clock, new TokenService(), new ActiveStreamRegistry());
        var approvals = new AdministrationApprovalStore(clock, new TokenService(), sessions);
        var session = sessions.Issue(Guid.NewGuid(), Guid.NewGuid()).Session.Id;
        var action = "POST /api/v1/users";
        var hash = AdministrationApprovalStore.Hash([]);
        Assert.Equal("management_locked", Assert.Throws<AccountException>(() => approvals.Issue(session, action, hash)).Code);
        var deadline = sessions.UnlockManagement(session);
        var beforeLock = approvals.Issue(session, action, hash);
        sessions.LockManagement(session);
        sessions.UnlockManagement(session);
        Assert.False(approvals.Consume(beforeLock.Token, session, action, hash));
        var beforeReunlock = approvals.Issue(session, action, hash);
        sessions.UnlockManagement(session);
        Assert.False(approvals.Consume(beforeReunlock.Token, session, action, hash));
        clock.Advance(TimeSpan.FromMinutes(9));
        var finalMinute = approvals.Issue(session, action, hash);
        Assert.Equal(deadline, finalMinute.ExpiresAt);
        Assert.Equal(deadline, sessions.CurrentManagementGrant(session)!.ExpiresAt);
        clock.Advance(TimeSpan.FromMinutes(1));
        Assert.False(approvals.Consume(finalMinute.Token, session, action, hash));
        Assert.False(sessions.ManagementUnlocked(session));
    }

    [Fact]
    public void LateUnlockCannotUndoLockRelockOrProfileRetirement()
    {
        var clock = new GrantClock();
        using var sessions = new ProfileSessionStore(clock, new TokenService(), new ActiveStreamRegistry());
        var session = sessions.Issue(Guid.NewGuid(), Guid.NewGuid()).Session.Id;
        var pending = sessions.ManagementEpoch(session);
        sessions.LockManagement(session); // Even a locked window invalidates outstanding verification.
        Assert.Equal("management_unlock_superseded", Assert.Throws<AccountException>(() => sessions.UnlockManagement(session, pending)).Code);
        Assert.False(sessions.ManagementUnlocked(session));
        pending = sessions.ManagementEpoch(session);
        sessions.UnlockManagement(session, pending);
        Assert.Equal("management_unlock_superseded", Assert.Throws<AccountException>(() => sessions.UnlockManagement(session, pending)).Code);
        pending = sessions.ManagementEpoch(session);
        sessions.End(session);
        Assert.Equal("profile_session_expired", Assert.Throws<AccountException>(() => sessions.UnlockManagement(session, pending)).Code);
    }

    [Fact]
    public async Task LockDuringPasswordVerificationRejectsLateHttpUnlock()
    {
        using var hasher = new GatedPasswordHasher();
        using var factory = new AureliaServerFactory(configureServices: services =>
        {
            services.RemoveAll<IPasswordHasher<ServerUser>>();
            services.AddSingleton<IPasswordHasher<ServerUser>>(hasher);
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        hasher.BlockNextVerification();
        using var unlockRequest = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/unlock", owner.Token,
            new UnlockManagementRequest("correct horse battery staple"));
        var pending = Task.Run(() => client.SendAsync(unlockRequest));
        try
        {
            await hasher.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
            using var lockRequest = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/lock", owner.Token);
            using var locked = await client.SendAsync(lockRequest);
            locked.EnsureSuccessStatusCode();
        }
        finally { hasher.Release(); }
        using var late = await pending.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(HttpStatusCode.Conflict, late.StatusCode);
        Assert.Equal("management_unlock_superseded", (await ApiTestClient.ReadAsync<ApiProblem>(late)).Code);
        using var approvalRequest = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/approval", owner.Token,
            new AdministrationApprovalRequest("POST /api/v1/libraries/reset", AdministrationApprovalStore.Hash([])));
        using var approvalResp = await client.SendAsync(approvalRequest);
        Assert.Equal("management_locked", (await ApiTestClient.ReadAsync<ApiProblem>(approvalResp)).Code);
    }

    [Fact]
    public void ManagementCannotOutliveTheViewingSessionOrSurviveDeviceRevocation()
    {
        var clock = new GrantClock();
        using var sessions = new ProfileSessionStore(clock, new TokenService(), new ActiveStreamRegistry());
        var approvals = new AdministrationApprovalStore(clock, new TokenService(), sessions);
        var device = Guid.NewGuid();
        var issued = sessions.Issue(device, Guid.NewGuid());
        clock.Advance(TimeSpan.FromHours(11) + TimeSpan.FromMinutes(59));
        Assert.Equal(issued.Session.ExpiresAt, sessions.UnlockManagement(issued.Session.Id));
        var proof = approvals.Issue(issued.Session.Id, "POST /api/v1/users", AdministrationApprovalStore.Hash([]));
        Assert.Equal(issued.Session.ExpiresAt, proof.ExpiresAt);
        sessions.RevokeDevice(device);
        Assert.False(approvals.Consume(proof.Token, issued.Session.Id, "POST /api/v1/users", AdministrationApprovalStore.Hash([])));
    }

    [Fact]
    public void ProofBindsExactRawRequestTargetIncludingEncodingCaseAndQuery()
    {
        var context = new DefaultHttpContext();
        context.Request.Method = "DELETE";
        context.Request.Path = "/api/v1/users/name";
        context.Features.Get<IHttpRequestFeature>()!.RawTarget = "/API/v1/users/n%61me?revision=3";
        Assert.Equal("DELETE /API/v1/users/n%61me?revision=3", ServerRequestGuard.ApprovalAction(context.Request));
        var clock = new GrantClock();
        using var sessions = new ProfileSessionStore(clock, new TokenService(), new ActiveStreamRegistry());
        var approvals = new AdministrationApprovalStore(clock, new TokenService(), sessions);
        var session = sessions.Issue(Guid.NewGuid(), Guid.NewGuid()).Session.Id;
        sessions.UnlockManagement(session);
        var hash = AdministrationApprovalStore.Hash([]);
        var proof = approvals.Issue(session, ServerRequestGuard.ApprovalAction(context.Request), hash);
        Assert.False(approvals.Consume(proof.Token, session, "DELETE /api/v1/users/name?revision=3", hash));
    }

    [Fact]
    public async Task CurrentRoleIsCheckedAtConsumeEvenIfAuthenticatedClaimsAreStale()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var profiles = factory.Services.GetRequiredService<ProfileSessionStore>();
        var session = profiles.Find(factory.Services.GetRequiredService<TokenService>().Hash(owner.Token))!;
        var approvals = factory.Services.GetRequiredService<AdministrationApprovalStore>();
        var proof = approvals.Issue(session.Id, "POST /api/v1/libraries/reset", AdministrationApprovalStore.Hash([]));
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var user = await database.Users.SingleAsync(value => value.Id == owner.User.Id);
        user.Role = UserRole.User;
        await database.SaveChangesAsync();
        var context = new DefaultHttpContext { RequestServices = scope.ServiceProvider };
        context.User = new ClaimsPrincipal(new ClaimsIdentity([
            new Claim(ClaimTypes.NameIdentifier, user.Id.ToString()),
            new Claim(ClaimTypes.Role, nameof(UserRole.Owner)),
            new Claim(DeviceTokenAuthenticationHandler.SessionIdClaim, owner.SessionId.ToString()),
            new Claim(DeviceTokenAuthenticationHandler.ProfileSessionIdClaim, session.Id.ToString()),
        ], "synthetic"));
        context.Request.Method = "POST";
        context.Request.Path = "/api/v1/libraries/reset";
        context.Request.Headers["X-Aurelia-Approval"] = proof.Token;
        var error = await Assert.ThrowsAsync<AccountException>(() => ServerRequestGuard.RequireApprovalAsync(context, approvals));
        Assert.Equal("profile_session_revoked", error.Code);
        Assert.False(approvals.Consume(proof.Token, session.Id, "POST /api/v1/libraries/reset", AdministrationApprovalStore.Hash([])));
    }

    [Fact]
    public async Task DeadlineDoesNotExtendWhenApprovalsAreIssuedAndExpiryPreservesViewing()
    {
        var clock = new GrantClock();
        using var factory = new AureliaServerFactory(configureServices: services =>
        {
            services.RemoveAll<TimeProvider>();
            services.AddSingleton<TimeProvider>(clock);
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        clock.Advance(TimeSpan.FromMinutes(9));
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/approval", owner.Token,
            new AdministrationApprovalRequest("POST /api/v1/libraries/reset", AdministrationApprovalStore.Hash([])));
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        Assert.Equal(clock.GetUtcNow().AddMinutes(1), (await ApiTestClient.ReadAsync<AdministrationApprovalResponse>(response)).ExpiresAt);
        clock.Advance(TimeSpan.FromMinutes(1));
        using var expiredApprovalRequest = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/management/approval", owner.Token,
            new AdministrationApprovalRequest("POST /api/v1/libraries/reset", AdministrationApprovalStore.Hash([])));
        using var expired = await client.SendAsync(expiredApprovalRequest);
        Assert.Equal("management_locked", (await ApiTestClient.ReadAsync<ApiProblem>(expired)).Code);
        using var homeRequest = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/home", owner.Token);
        using var home = await client.SendAsync(homeRequest);
        home.EnsureSuccessStatusCode();
    }

    private sealed class GrantClock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan duration) => now += duration;
    }

    private sealed class GatedPasswordHasher : IPasswordHasher<ServerUser>, IDisposable
    {
        private readonly PasswordHasher<ServerUser> inner = new();
        private readonly ManualResetEventSlim release = new(false);
        private int block;
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void BlockNextVerification() => Volatile.Write(ref block, 1);
        public void Release() => release.Set();
        public string HashPassword(ServerUser user, string password) => inner.HashPassword(user, password);
        public PasswordVerificationResult VerifyHashedPassword(ServerUser user, string hashedPassword, string providedPassword)
        {
            if (Interlocked.Exchange(ref block, 0) == 1)
            {
                Started.TrySetResult();
                if (!release.Wait(TimeSpan.FromSeconds(10))) throw new InvalidOperationException("Synthetic password verification was not released.");
            }
            return inner.VerifyHashedPassword(user, hashedPassword, providedPassword);
        }
        public void Dispose() => release.Dispose();
    }
}
