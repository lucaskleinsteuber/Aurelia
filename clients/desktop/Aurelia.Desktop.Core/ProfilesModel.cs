using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>A profile as the list in Server Settings shows it.</summary>
public sealed record ProfileRow(UserAccessSummary Access)
{
    public UserSummary User => Access.User;
    public string Name => User.Username;
    public string RoleName => ProfilesModel.RoleName(User.Role);
    public bool IsOwner => User.Role == UserRole.Owner;
    public string Details => string.Join(" · ", new[]
    {
        RoleName,
        User.PinProtectionEnabled ? "PIN" : "No PIN",
        User.AccessMode == ProfileAccessMode.SelectedTitles ? "Selected titles" : "Entire library",
        Access.IsEnabled ? null : "Turned off",
    }.OfType<string>());
}

/// <summary>A movie or show the profile may watch when it sees only selected titles.</summary>
public sealed class TitleChoice(CatalogItemSummary item) : INotifyPropertyChanged
{
    public Guid Id => item.Id;
    public string Title => item.Title;
    public string Caption => (item.Kind == MediaKind.Series ? "TV Show" : "Movie") + (item.Year is { } year ? " · " + year.ToString(CultureInfo.InvariantCulture) : "");
    public bool IsSelected { get; set { if (field == value) return; field = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected))); } }
    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>
/// Profiles in Server Settings, for the owner as on the Mac: who may watch, with which role,
/// whether a PIN protects the profile, and whether it sees the entire library or selected titles.
/// Changes are approved like every other management change.
/// </summary>
public sealed class ProfilesModel(Func<IAdministrationClient> client) : INotifyPropertyChanged
{
    public static readonly IReadOnlyList<string> Roles = ["User", "Administrator"];
    public static readonly IReadOnlyList<string> AccessModes = ["Entire Library", "Selected Titles"];
    private ProfileRow? editing;
    private ProfileEditorResponse? editor;
    private List<TitleChoice> allTitles = [];

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Management locked while working; Server Settings asks for the password again.</summary>
    public event Action? Locked;

    public ObservableCollection<ProfileRow> Profiles { get; } = [];
    public bool IsBusy { get; private set => Set(ref field, value); }
    public string? Error { get; private set => Set(ref field, value, nameof(Error), nameof(HasError)); }
    public bool HasError => Error is not null;
    public string? Notice { get; private set => Set(ref field, value, nameof(Notice), nameof(HasNotice)); }
    public bool HasNotice => Notice is not null;

    public bool IsEditing { get; private set => Set(ref field, value, nameof(IsEditing), nameof(ShowsList)); }
    public bool ShowsList => !IsEditing;
    public bool IsNew => editing is null;
    public bool EditsOwner => editing?.IsOwner == true;
    public bool CanChooseRole => !EditsOwner;
    public string EditorTitle => editing is null ? "New Profile" : editing.Name;
    public string Name { get; set => Set(ref field, value); } = "";
    public int RoleIndex { get; set => Set(ref field, Math.Clamp(value, 0, 1), nameof(RoleIndex), nameof(PinRequired)); }
    public bool IsEnabled { get; set => Set(ref field, value); } = true;
    public bool PinProtection { get; set => Set(ref field, value, nameof(PinProtection), nameof(AsksForPin)); } = true;
    /// <summary>Owners and administrators always use a PIN.</summary>
    public bool PinRequired => EditsOwner || RoleIndex == 1;
    public bool AsksForPin => PinProtection || PinRequired;
    public string PinHint => IsNew || editor?.User.NeedsPinSetup == true ? "Choose a PIN with four to eight digits." : "Leave empty to keep the current PIN.";
    public string Pin { get; set => Set(ref field, value); } = "";
    public string PinConfirmation { get; set => Set(ref field, value); } = "";
    public int AccessIndex { get; set => Set(ref field, Math.Clamp(value, 0, 1), nameof(AccessIndex), nameof(ChoosesTitles)); }
    public bool ChoosesTitles => AccessIndex == 1;
    public ObservableCollection<TitleChoice> Titles { get; } = [];
    public string TitleFilter { get; set { if (Set(ref field, value)) FilterTitles(); } } = "";
    public string SelectionText => $"{allTitles.Count(title => title.IsSelected)} of {allTitles.Count} titles";

    public static string RoleName(UserRole role) => role switch
    {
        UserRole.Owner => "Owner",
        UserRole.Admin => "Administrator",
        _ => "User",
    };

    public Task LoadAsync() => RunAsync(LoadProfilesAsync);

    public Task BeginNewAsync() => OpenEditorAsync(null);

    public Task BeginEditAsync(ProfileRow row) => OpenEditorAsync(row);

    public void CancelEdit()
    {
        IsEditing = false;
        Error = null;
        Pin = "";
        PinConfirmation = "";
    }

    public Task SaveAsync()
    {
        var name = Name.Trim();
        if (IsNew && name.Length is < 3 or > 64) return Fail("Enter a profile name with 3 to 64 characters.");
        var needsNewPin = IsNew || editor?.User.NeedsPinSetup == true || (AsksForPin && editor?.User.PinProtectionEnabled == false);
        if (AsksForPin && (Pin.Length > 0 || needsNewPin))
        {
            if (!ProfilePin.IsValid(Pin)) return Fail("Choose a PIN with four to eight digits.");
            if (Pin != PinConfirmation) return Fail("The PINs do not match.");
        }
        var selected = allTitles.Where(title => title.IsSelected).Select(title => title.Id).ToList();
        if (ChoosesTitles && selected.Count == 0) return Fail("Choose at least one movie or show, or allow the entire library.");
        var role = EditsOwner ? UserRole.Owner : RoleIndex == 1 ? UserRole.Admin : UserRole.User;
        var mode = ChoosesTitles ? ProfileAccessMode.SelectedTitles : ProfileAccessMode.EntireLibrary;
        var pin = AsksForPin && Pin.Length > 0 ? Pin : null;
        return RunAsync(async token =>
        {
            if (editing is null)
            {
                await client().SendAsync<UserSummary>(HttpMethod.Post, "/api/v1/users",
                    new CreateUserRequest(name, null, role, pin, AsksForPin, mode, ChoosesTitles ? selected : null, IsEnabled), token);
                Notice = $"{name} was added. They choose it on the profile screen of any device.";
            }
            else
            {
                await client().SendAsync<ProfileEditorResponse>(HttpMethod.Put, $"/api/v1/users/{editing.User.Id}/profile",
                    new UpdateProfileRequest(editor!.Revision, role, EditsOwner || IsEnabled, AsksForPin, pin, mode, ChoosesTitles ? selected : null),
                    token);
                Notice = $"{editing.Name} was saved.";
            }
            CancelEdit();
            await LoadProfilesAsync(token);
        });
    }

    /// <summary>Removes a profile with its progress and favorites; the owner stays.</summary>
    public Task RemoveAsync(ProfileRow row) => row.IsOwner ? Task.CompletedTask : RunAsync(async token =>
    {
        await client().SendAsync<AureliaServerApi.NoContent>(HttpMethod.Delete, $"/api/v1/users/{row.User.Id}", null, token);
        Notice = $"{row.Name} was removed.";
        await LoadProfilesAsync(token);
    });

    private Task OpenEditorAsync(ProfileRow? row) => RunAsync(async token =>
    {
        Notice = null;
        editing = row;
        editor = row is null ? null : await client().SendAsync<ProfileEditorResponse>(HttpMethod.Get, $"/api/v1/users/{row.User.Id}/profile", null, token);
        Name = row?.Name ?? "";
        RoleIndex = editor?.User.Role == UserRole.Admin ? 1 : 0;
        IsEnabled = editor?.IsEnabled ?? true;
        PinProtection = editor?.User.PinProtectionEnabled ?? true;
        Pin = "";
        PinConfirmation = "";
        AccessIndex = editor?.Access.Mode == ProfileAccessMode.SelectedTitles ? 1 : 0;
        TitleFilter = "";
        allTitles = await TitlesAsync(token);
        var granted = editor?.Access.TitleIds.ToHashSet() ?? [];
        foreach (var title in allTitles)
        {
            title.IsSelected = granted.Contains(title.Id);
            title.PropertyChanged += (_, _) => Changed(nameof(SelectionText));
        }
        FilterTitles();
        Changed(nameof(IsNew), nameof(EditsOwner), nameof(CanChooseRole), nameof(EditorTitle), nameof(PinRequired), nameof(AsksForPin), nameof(PinHint));
        IsEditing = true;
    });

    /// <summary>Every movie and show on the server, in pages, for the selected-titles choice.</summary>
    private async Task<List<TitleChoice>> TitlesAsync(CancellationToken token)
    {
        var titles = new List<TitleChoice>();
        foreach (var kind in new[] { "movie", "series" })
        {
            for (var offset = 0; offset < 20_000;)
            {
                var page = await client().SendAsync<PagedResponse<CatalogItemSummary>>(HttpMethod.Get,
                    $"/api/v1/catalog/items?kind={kind}&sort=title&direction=ascending&offset={offset}&limit=200", null, token);
                titles.AddRange(page.Items.Select(item => new TitleChoice(item)));
                offset += page.Items.Count;
                if (page.Items.Count == 0 || offset >= page.Total) break;
            }
        }
        return [.. titles.OrderBy(title => title.Title, StringComparer.CurrentCultureIgnoreCase)];
    }

    private void FilterTitles()
    {
        var filter = TitleFilter.Trim();
        Titles.Clear();
        foreach (var title in allTitles.Where(title => filter.Length == 0 || title.Title.Contains(filter, StringComparison.CurrentCultureIgnoreCase)))
            Titles.Add(title);
        Changed(nameof(SelectionText));
    }

    private async Task LoadProfilesAsync(CancellationToken token)
    {
        var users = await client().SendAsync<IReadOnlyList<UserAccessSummary>>(HttpMethod.Get, "/api/v1/server/users", null, token);
        Profiles.Clear();
        foreach (var user in users.OrderBy(user => user.User.Role).ThenBy(user => user.User.Username, StringComparer.CurrentCultureIgnoreCase))
            Profiles.Add(new ProfileRow(user));
    }

    private Task Fail(string message)
    {
        Error = message;
        return Task.CompletedTask;
    }

    private async Task RunAsync(Func<CancellationToken, Task> operation)
    {
        if (IsBusy) return;
        IsBusy = true;
        Error = null;
        try { await operation(CancellationToken.None); }
        catch (AureliaApiException error) when (error.Code == "management_locked")
        {
            Error = "Enter the Server Password again to continue.";
            Locked?.Invoke();
        }
        catch (AureliaApiException error) { Error = error.Message; }
        finally { IsBusy = false; }
    }

    private void Changed(params string[] names)
    {
        foreach (var name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string name = "", params string[] also)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Changed(name);
        Changed(also);
        return true;
    }
}
