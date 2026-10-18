using System.Runtime.InteropServices;
using LibVLCSharp.Shared;

namespace Aurelia.Desktop.Playback;

/// <summary>
/// Turns on a VLC audio filter for one player. A player creates its own empty "audio-filter"
/// setting, which hides the library option, so the filter is set on the player itself and its
/// audio output rebuilt, exactly as the Mac app does.
/// </summary>
public static class VlcAudioFilter
{
    private const int VlcVarString = 0x0040;

    public static unsafe bool Enable(MediaPlayer player, string filter, string output)
    {
        if (CoreLibrary() is not { } core || !NativeLibrary.TryGetExport(core, "var_SetChecked", out var export)) return false;
        var setChecked = (delegate* unmanaged[Cdecl]<IntPtr, byte*, int, IntPtr, int>)export;
        var value = Marshal.StringToCoTaskMemUTF8(filter);
        try
        {
            fixed (byte* name = "audio-filter\0"u8)
            {
                // vlc_value_t is an 8-byte union; its string member is passed like a pointer.
                if (setChecked(player.NativeReference, name, VlcVarString, value) != 0) return false;
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(value);
        }
        return player.SetAudioOutput(output);
    }

    private static IntPtr? CoreLibrary()
    {
        var directory = VlcRuntime.NativeDirectory();
        string[] candidates = OperatingSystem.IsWindows() ? ["libvlccore.dll"]
            : OperatingSystem.IsMacOS() ? ["libvlccore.dylib", "libvlccore.9.dylib"]
            : ["libvlccore.so.9", "libvlccore.so"];
        foreach (var name in candidates)
        {
            var path = directory is null ? name : Path.Combine(directory, name);
            if (NativeLibrary.TryLoad(path, out var handle)) return handle;
        }
        return null;
    }
}
