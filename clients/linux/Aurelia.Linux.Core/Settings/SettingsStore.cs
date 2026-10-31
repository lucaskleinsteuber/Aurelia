using System.Text.Json;
using System.Text.Json.Nodes;

namespace Aurelia.Linux.Core.Settings;

/// <summary>The app's preferences: small values by key, like the Mac app's UserDefaults.</summary>
public interface ISettingsStore
{
    T? Read<T>(string key);

    void Write<T>(string key, T value);

    void Remove(string key);
}

/// <summary>Preferences kept in memory only, for tests.</summary>
public sealed class MemorySettingsStore : ISettingsStore
{
    private readonly Dictionary<string, JsonNode?> values = [];

    public T? Read<T>(string key) => values.TryGetValue(key, out var node) && node is not null ? node.Deserialize<T>(SettingsJson.Options) : default;

    public void Write<T>(string key, T value) => values[key] = JsonSerializer.SerializeToNode(value, SettingsJson.Options);

    public void Remove(string key) => values.Remove(key);
}

/// <summary>
/// Preferences in one JSON file that only this user may read. Every change is written at once
/// through a temporary file, so a crash never leaves a half-written file. A damaged file is set
/// aside and the defaults apply.
/// </summary>
public sealed class JsonFileSettingsStore : ISettingsStore
{
    private readonly Lock gate = new();
    private readonly string path;
    private readonly JsonObject values;

    public JsonFileSettingsStore(string path)
    {
        this.path = path;
        values = Load(path);
    }

    public T? Read<T>(string key)
    {
        lock (gate)
        {
            if (!values.TryGetPropertyValue(key, out var node) || node is null) return default;
            try
            {
                return node.Deserialize<T>(SettingsJson.Options);
            }
            catch (JsonException)
            {
                return default;
            }
        }
    }

    public void Write<T>(string key, T value)
    {
        lock (gate)
        {
            values[key] = JsonSerializer.SerializeToNode(value, SettingsJson.Options);
            Save();
        }
    }

    public void Remove(string key)
    {
        lock (gate)
        {
            if (values.Remove(key)) Save();
        }
    }

    private static JsonObject Load(string path)
    {
        if (!File.Exists(path)) return [];
        try
        {
            return JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? [];
        }
        catch (Exception exception) when (exception is JsonException or IOException)
        {
            File.Move(path, path + ".damaged", overwrite: true);
            return [];
        }
    }

    private void Save()
    {
        var directory = Path.GetDirectoryName(path)!;
        PrivateFiles.CreateDirectory(directory);
        var temporary = path + ".tmp";
        PrivateFiles.WriteAllText(temporary, values.ToJsonString(SettingsJson.Options));
        File.Move(temporary, path, overwrite: true);
    }
}

internal static class SettingsJson
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { WriteIndented = true };
}
