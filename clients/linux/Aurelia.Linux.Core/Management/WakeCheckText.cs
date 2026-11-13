using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Management;

public enum WakeCheckState { Ok, Warning, Problem, Info }

public sealed record WakeCheckItem(WakeCheckState State, string Title, string Detail);

/// <summary>
/// Settings › Power › Wake-on-LAN Check: what a Linux package server found about its network card,
/// connection and sleep (server 2.16.0) for the chosen mode, what only a test shows, and what to
/// change. Same items and words as the Mac app and the browser.
/// </summary>
public static class WakeCheckText
{
    public const string Intro = "Aurelia on a Mac, Linux PC, iPhone or iPad wakes the server with a Wake-on-LAN call. What this server knows about it, for the choice above:";

    public const string Footer = "Most desktop PCs connected by cable wake from sleep, even old ones. Waking from off also needs the BIOS setting. Wi-Fi, many laptops and some USB network adapters can't be woken.";

    /// <summary>Null where nothing wakes over the network: other modes, or a server an app hosts.</summary>
    public static IReadOnlyList<WakeCheckItem>? Items(ServerPowerSettings power, string mode)
    {
        if (!power.Available || power.Hosting is "macApp" or "linuxApp" || mode is not ("sleep" or "shutdown")) return null;
        var items = new List<WakeCheckItem>();
        void Add(WakeCheckState state, string title, string detail) => items.Add(new(state, title, detail));
        var network = power.Network ?? "";
        var wakeOn = power.WakeOn ?? "";
        var support = power.WakeSupport ?? "";
        switch (network)
        {
            case "wired":
                Add(WakeCheckState.Ok, "Connected by cable", "Wake-on-LAN needs a network cable to the router, and this computer has one.");
                break;
            case "wifi":
                Add(WakeCheckState.Problem, "Connected by Wi-Fi", "Almost no computer wakes over Wi-Fi. Connect it to the router with a network cable.");
                break;
            case "":
                break;
            default:
                Add(WakeCheckState.Info, "Connection not recognized", "Wake-on-LAN needs a network cable to the router; Aurelia couldn't tell how this computer is connected.");
                break;
        }
        if (support.Length > 0 && !support.Contains('g', StringComparison.Ordinal))
            Add(WakeCheckState.Problem, "The network card can't wake the computer", "Choose “Stop Only Aurelia Server” instead, or add a network card or USB network adapter that supports Wake-on-LAN.");
        else if (wakeOn.Contains('g', StringComparison.Ordinal))
            Add(WakeCheckState.Ok, "Wake-on-LAN is on", "The network card wakes the computer when it gets a Wake-on-LAN call.");
        else if (wakeOn.Length > 0)
            Add(WakeCheckState.Warning, "Wake-on-LAN is off right now", "Aurelia switches it on at every start and before powering down. If waking fails, restart the computer once.");
        else
            Add(WakeCheckState.Info, "Network card not checked yet", "The server checks its network card when the computer starts. Restart it once, or update Aurelia Server, to see it here.");
        if (mode == "sleep")
        {
            switch (power.SleepKind ?? "")
            {
                case "deep":
                    Add(WakeCheckState.Ok, "Real sleep", "Fans and disks stop, it uses only a few watts, and waking takes about 10 to 20 seconds.");
                    break;
                case "light":
                    Add(WakeCheckState.Warning, "Only light sleep", "This computer offers only a lighter sleep (s2idle). It may use more power, and some network cards can't wake it. Try it once.");
                    break;
                case "none":
                    Add(WakeCheckState.Problem, "This computer can't sleep", "Choose “Shut Down the Computer” or “Stop Only Aurelia Server” instead.");
                    break;
            }
        }
        else
        {
            Add(WakeCheckState.Info, "Waking from off needs the BIOS", "Aurelia can't check this from here. Open the BIOS setup (usually Del or F2 right after switching on), turn on “Wake on LAN”, “Power On By PCI-E” or “Resume by LAN”, and turn off “ErP” or “Deep Sleep”. Starting takes 30 to 60 seconds, because the whole computer starts up; waking from sleep is much faster.");
        }
        Add(WakeCheckState.Info, "Try it once", "Let the server power down, then open Aurelia on a Mac, Linux PC or iPhone: it sends the Wake-on-LAN call and connects once the server is back. If it stays off, its power button starts it as usual.");
        return items;
    }

    /// <summary>The mark in front of an item, read out as its label.</summary>
    public static (string Glyph, string Label, string Color) Mark(WakeCheckState state) => state switch
    {
        WakeCheckState.Ok => ("✓", "Fine", "#4CC38A"),
        WakeCheckState.Warning => ("!", "Check this", "#FFB547"),
        WakeCheckState.Problem => ("✕", "Problem", "#FF6B6B"),
        _ => ("i", "Note", "#9AA0A6"),
    };
}
