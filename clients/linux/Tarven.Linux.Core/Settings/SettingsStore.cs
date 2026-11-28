using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tarven.Linux.Core.Settings;

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
/// aside and the defaults apply. A file that exists but cannot be read right now (a passing disk or
/// permission error) is left alone: changes then stay in memory for this session, so the saved
/// preferences are never replaced by defaults (audit C-X12).
/// </summary>
public sealed class JsonFileSettingsStore : ISettingsStore
{
    private readonly Lock gate = new();
    private readonly string path;
    private readonly JsonObject values;
    private readonly bool unreadable;

    public JsonFileSettingsStore(string path)
    {
        this.path = path;
        (values, unreadable) = Load(path);
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

    private static (JsonObject Values, bool Unreadable) Load(string path)
    {
        if (!File.Exists(path)) return ([], false);
        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return ([], true);
        }
        try
        {
            return (JsonNode.Parse(text) as JsonObject ?? [], false);
        }
        catch (JsonException)
        {
            try { File.Move(path, path + ".damaged", overwrite: true); }
            catch (Exception move) when (move is IOException or UnauthorizedAccessException) { }
            return ([], false);
        }
    }

    /// <summary>
    /// A full or read-only disk keeps the value for this session instead of ending the app; the
    /// next successful write saves everything.
    /// </summary>
    private void Save()
    {
        if (unreadable)
        {
            LastSaveFailed = true;
            return;
        }
        try
        {
            var directory = Path.GetDirectoryName(path)!;
            PrivateFiles.CreateDirectory(directory);
            var temporary = path + ".tmp";
            PrivateFiles.WriteAllText(temporary, values.ToJsonString(SettingsJson.Options));
            File.Move(temporary, path, overwrite: true);
            LastSaveFailed = false;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LastSaveFailed = true;
        }
    }

    /// <summary>True when the last change could not be written to disk.</summary>
    public bool LastSaveFailed { get; private set; }
}

internal static class SettingsJson
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { WriteIndented = true };
}
