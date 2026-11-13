using System.Data.Common;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace Aurelia.Server.Services;

/// <summary>
/// Counts the database commands of each request and hands slow ones to
/// <see cref="ServerPerformanceStore"/>, with the endpoint that ran them. EF Core measures the
/// duration itself; this only reads it. Commands outside a request (background work) are slow
/// queries without an endpoint.
/// </summary>
public sealed class SlowQueryInterceptor(ServerPerformanceStore store, IHttpContextAccessor http) : DbCommandInterceptor
{
    public override DbDataReader ReaderExecuted(DbCommand command, CommandExecutedEventData eventData, DbDataReader result)
    {
        Observe(command, eventData);
        return result;
    }

    public override ValueTask<DbDataReader> ReaderExecutedAsync(DbCommand command, CommandExecutedEventData eventData,
        DbDataReader result, CancellationToken cancellationToken = default)
    {
        Observe(command, eventData);
        return ValueTask.FromResult(result);
    }

    public override int NonQueryExecuted(DbCommand command, CommandExecutedEventData eventData, int result)
    {
        Observe(command, eventData);
        return result;
    }

    public override ValueTask<int> NonQueryExecutedAsync(DbCommand command, CommandExecutedEventData eventData, int result,
        CancellationToken cancellationToken = default)
    {
        Observe(command, eventData);
        return ValueTask.FromResult(result);
    }

    public override object? ScalarExecuted(DbCommand command, CommandExecutedEventData eventData, object? result)
    {
        Observe(command, eventData);
        return result;
    }

    public override ValueTask<object?> ScalarExecutedAsync(DbCommand command, CommandExecutedEventData eventData, object? result,
        CancellationToken cancellationToken = default)
    {
        Observe(command, eventData);
        return ValueTask.FromResult(result);
    }

    private void Observe(DbCommand command, CommandExecutedEventData eventData)
    {
        var context = http.HttpContext;
        if (context is not null)
        {
            var items = context.Items;
            lock (items)
                items[ServerPerformanceStore.QueryCountItem] =
                    (items.TryGetValue(ServerPerformanceStore.QueryCountItem, out var value) && value is long count ? count : 0L) + 1;
        }
        var milliseconds = eventData.Duration.TotalMilliseconds;
        if (milliseconds >= ServerPerformanceStore.SlowQueryMilliseconds)
            store.RecordQuery(milliseconds, command.CommandText, context is null ? null : ServerPerformanceStore.EndpointKey(context));
    }
}
