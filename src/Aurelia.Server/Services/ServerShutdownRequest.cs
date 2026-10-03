namespace Aurelia.Server.Services;

public static class ServerShutdownRequest
{
    public static async Task RunAsync(HttpContext context, RequestDelegate next, CancellationToken serverStopping)
    {
        var original = context.RequestAborted;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(original, serverStopping);
        context.RequestAborted = cancellation.Token;
        try { await next(context); }
        catch (OperationCanceledException) when (serverStopping.IsCancellationRequested) { context.Abort(); }
        finally { context.RequestAborted = original; }
    }
}
