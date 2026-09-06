using System.Net;

namespace Aurelia.Home.Server.Services;

public static class LocalRequestPolicy
{
    public static bool IsAllowed(IPAddress? remoteAddress, bool isTesting)
    {
        return isTesting || remoteAddress is not null && IPAddress.IsLoopback(remoteAddress);
    }
}
