using System.Text.Json;
using System.Text.Json.Serialization;

namespace Aurelia.Linux.Core.Api;

/// <summary>The server's JSON: camelCase names, enums as camelCase strings, dates as ISO 8601 text.</summary>
public static class AureliaJson
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
    };
}
