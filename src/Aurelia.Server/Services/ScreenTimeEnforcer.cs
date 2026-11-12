using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Ends what screen time no longer allows: a title still playing after it must have ended ("Stop now" at
/// once, "Finish the title" after the overtime), and an open children's profile when the whole profile closes.
/// A profile that is still watching its last title keeps its session until that title ends.
/// </summary>
public sealed partial class ScreenTimeEnforcer(IServiceScopeFactory scopes, TimeProvider clock, ActiveStreamRegistry streams,
    ProfileSessionStore sessions, ILogger<ScreenTimeEnforcer> logger) : BackgroundService
{
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(15);

    /// <summary>A profile that reported no progress for this long is not watching anything.</summary>
    public static readonly TimeSpan IdleAfter = TimeSpan.FromMinutes(2);

    private DateTimeOffset lastPrune;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(Interval, clock);
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
            {
                try { await EnforceAsync(stoppingToken); }
                catch (Exception exception) when (exception is not OperationCanceledException)
                { CheckFailed(logger, exception); }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    public async Task EnforceAsync(CancellationToken token)
    {
        await using var scope = scopes.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var screenTime = scope.ServiceProvider.GetRequiredService<ScreenTimeService>();
        var now = screenTime.Now;
        var users = await database.ScreenTimeRules.AsNoTracking()
            .Where(rule => rule.Enabled && rule.User.Role == UserRole.User && rule.User.IsEnabled)
            .Select(rule => rule.UserId).ToListAsync(token);
        foreach (var userId in users)
        {
            if (await screenTime.StatusAsync(userId, token) is not { State: ScreenTimeState.Closed } status) continue;
            var extraEnd = await database.PlaybackTickets.IgnoreQueryFilters().AsNoTracking()
                .Where(ticket => ticket.UserId == userId && ticket.RevokedAt == null && ticket.ScreenTimeExtraEndsAt != null)
                .Select(ticket => ticket.ScreenTimeExtraEndsAt).ToListAsync(token);
            var extra = extraEnd.Where(end => end > now).Max();
            var mustEnd = extra ?? status.TitleEndsBy ?? now;
            var playing = streams.HasPlayback(userId);
            if (now >= mustEnd && playing) streams.RevokeUser(userId);
            if (status.LockScope != ScreenTimeLockScope.WholeProfile || status.OneMoreTitleAvailable || extra is not null) continue;
            var lastReport = await database.PlaybackProgress.IgnoreQueryFilters().AsNoTracking()
                .Where(progress => progress.UserId == userId).Select(progress => (DateTimeOffset?)progress.UpdatedAt)
                .ToListAsync(token);
            var watching = playing || lastReport.Max() is { } last && now - last < IdleAfter;
            if (now >= mustEnd || !watching) sessions.RevokeUser(userId);
        }
        if (now - lastPrune > TimeSpan.FromHours(6))
        {
            lastPrune = now;
            var oldest = DateOnly.FromDateTime(now.UtcDateTime).AddDays(-90);
            await database.ScreenTimeDays.Where(day => day.Day < oldest).ExecuteDeleteAsync(token);
        }
    }

    [LoggerMessage(LogLevel.Warning, "Screen time could not be checked; it is checked again shortly.")]
    private static partial void CheckFailed(ILogger logger, Exception exception);
}
