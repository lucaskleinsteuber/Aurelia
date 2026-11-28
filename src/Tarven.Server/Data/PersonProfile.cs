namespace Tarven.Server.Data;

/// <summary>
/// A person's life and the titles TMDB knows them for ("people-v1"), read once when their page
/// opens and kept for 30 days. Only what TMDB publishes; nothing about the server's viewers.
/// </summary>
public sealed class PersonProfile
{
    public string Provider { get; set; } = "tmdb";
    public string ProviderPersonId { get; set; } = string.Empty;
    public string Language { get; set; } = "en-US";
    public string Name { get; set; } = string.Empty;
    public string? Biography { get; set; }
    public string? Birthday { get; set; }
    public string? Deathday { get; set; }
    public string? PlaceOfBirth { get; set; }
    public string? KnownForDepartment { get; set; }
    public string? ProfilePath { get; set; }
    /// <summary>The titles they are known for, most known first, as TMDB lists them (JSON).</summary>
    public string CreditsJson { get; set; } = "[]";
    public DateTimeOffset FetchedAt { get; set; }
}
