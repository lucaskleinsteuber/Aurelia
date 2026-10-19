using System.Text.Json;
using System.Text.Json.Nodes;

namespace Aurelia.Desktop.Core;

/// <summary>Whether this computer runs its own Aurelia server or connects to one elsewhere.</summary>
public enum AppMode { Host, Client }

/// <summary>Remembers the choice from the welcome screen. It is not a secret, only a preference.</summary>
public sealed class AppModeStore(string path)
{
    public static AppModeStore Default => new(Path.Combine(DesktopPaths.DataDirectory, "app-mode.json"));

    public AppMode? Load()
    {
        try
        {
            if (!File.Exists(path)) return null;
            return (JsonNode.Parse(File.ReadAllText(path)) as JsonObject)?["mode"]?.GetValue<string>() switch
            {
                "host" => AppMode.Host,
                "client" => AppMode.Client,
                _ => null,
            };
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    public void Save(AppMode mode)
    {
        DesktopPaths.EnsurePrivateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, new JsonObject { ["mode"] = mode == AppMode.Host ? "host" : "client" }.ToJsonString());
        File.Move(temporary, path, overwrite: true);
    }
}
