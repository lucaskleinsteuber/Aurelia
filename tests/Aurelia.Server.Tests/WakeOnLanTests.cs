using System.Net.NetworkInformation;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class WakeOnLanTests
{
    [Fact]
    public void WakeAddressesAreSixByteHardwareAddresses()
    {
        Assert.Equal("02:00:5e:10:00:01", WakeOnLan.Format(PhysicalAddress.Parse("02-00-5E-10-00-01")));
        Assert.Null(WakeOnLan.Format(PhysicalAddress.None));
        Assert.Null(WakeOnLan.Format(PhysicalAddress.Parse("00-00-00-00-00-00")));
        Assert.All(WakeOnLan.LocalAddresses(), address => Assert.Matches("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", address));
    }
}
