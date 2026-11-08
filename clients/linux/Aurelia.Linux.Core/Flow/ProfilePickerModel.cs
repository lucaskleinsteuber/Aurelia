using System.Collections.ObjectModel;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Flow;

/// <summary>
/// "Who's watching?", as on the Mac: the server's profiles; a profile without a PIN opens at once,
/// others ask for their four- to eight-digit PIN. A server whose profiles were never set up asks
/// for its password and the owner's new PIN first.
/// </summary>
public sealed class ProfilePickerModel : ObservableObject
{
    private readonly AppSession session;
    private bool isLoading;
    private bool isBusy;
    private bool needsSetup;
    private WatchingProfile? selected;
    private string pin = "";
    private string? error;
    private int failedAttempts;

    public ProfilePickerModel(AppSession session) => this.session = session;

    public ObservableCollection<WatchingProfile> Profiles { get; } = [];

    public string ServerName => session.Server?.Name ?? "Aurelia";

    public bool IsLoading
    {
        get => isLoading;
        private set => SetProperty(ref isLoading, value);
    }

    public bool IsBusy
    {
        get => isBusy;
        private set => SetProperty(ref isBusy, value);
    }

    /// <summary>The server's profiles were never set up; the owner sets the server password and PIN first.</summary>
    public bool NeedsSetup
    {
        get => needsSetup;
        private set => SetProperty(ref needsSetup, value);
    }

    /// <summary>The profile waiting for its PIN, or null.</summary>
    public WatchingProfile? Selected
    {
        get => selected;
        private set
        {
            if (SetProperty(ref selected, value)) OnPropertyChanged(nameof(IsEnteringPin));
        }
    }

    public bool IsEnteringPin => Selected is not null;

    public string Pin
    {
        get => pin;
        set => SetProperty(ref pin, new string((value ?? "").Where(char.IsAsciiDigit).Take(8).ToArray()));
    }

    public string? Error
    {
        get => error;
        private set => SetProperty(ref error, value);
    }

    /// <summary>Counts wrong PINs, so the field can shake each time.</summary>
    public int FailedAttempts
    {
        get => failedAttempts;
        private set => SetProperty(ref failedAttempts, value);
    }

    public async Task LoadAsync()
    {
        if (session.Server is not { } server) return;
        IsLoading = true;
        Error = null;
        try
        {
            var response = await session.Api.ProfilesAsync(server, CancellationToken.None);
            NeedsSetup = response.ManagementSetupRequired;
            Profiles.Clear();
            foreach (var profile in response.Profiles) Profiles.Add(profile);
        }
        catch (AureliaApiException failure)
        {
            if (failure.IsAuthenticationFailure || failure.Code is "device_session_revoked")
            {
                session.HandleSessionFailure(failure);
                return;
            }
            Error = failure.Status == 404 ? "This server is too old for this app. Update Aurelia on the server." : failure.Message;
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>A profile that still needs a PIN set up on the server cannot be opened here.</summary>
    public static bool CanChoose(WatchingProfile profile) => !profile.NeedsPinSetup;

    public static bool NeedsPin(WatchingProfile profile) =>
        profile.PinProtectionEnabled || profile.Role is UserRole.Owner or UserRole.Admin;

    public async Task ChooseAsync(WatchingProfile profile)
    {
        if (!CanChoose(profile)) return;
        Error = null;
        Pin = "";
        if (NeedsPin(profile))
        {
            Selected = profile;
            return;
        }
        await UnlockAsync(profile, null);
    }

    public Task SubmitPinAsync() => Selected is { } profile && ProfilePin.IsValid(Pin) ? UnlockAsync(profile, Pin) : Task.CompletedTask;

    public void CancelPin()
    {
        Selected = null;
        Pin = "";
        Error = null;
    }

    /// <summary>Sets up the server's profiles with the server password and the owner's new PIN.</summary>
    public async Task SetUpAsync(string password, string newPin, string confirmation)
    {
        if (!ProfilePin.IsValid(newPin))
        {
            Error = "Enter a PIN with four to eight digits.";
            return;
        }
        if (newPin != confirmation)
        {
            Error = "The PINs do not match.";
            return;
        }
        if (session.Server is not { } server) return;
        IsBusy = true;
        Error = null;
        try
        {
            await session.Api.InitializeProfilesAsync(server, password, newPin, CancellationToken.None);
            await LoadAsync();
            // The owner just chose this PIN: open the owner's profile without asking for it again.
            if (Profiles.FirstOrDefault(profile => profile.Role == UserRole.Owner) is { } owner)
            {
                IsBusy = false;
                await UnlockAsync(owner, newPin);
            }
        }
        catch (AureliaApiException failure)
        {
            Error = failure.Code is "invalid_credentials" or "invalid_password" ? "The server password is not correct." : failure.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task UnlockAsync(WatchingProfile profile, string? enteredPin)
    {
        if (session.Server is not { } server) return;
        IsBusy = true;
        try
        {
            var opened = await session.Api.UnlockProfileAsync(server, profile.Id, enteredPin, CancellationToken.None);
            Selected = null;
            Pin = "";
            session.OpenProfile(opened);
            session.NotifyUnlocked(profile, enteredPin);
        }
        catch (AureliaApiException failure)
        {
            if (failure.Code == "invalid_profile_pin")
            {
                Error = "PIN is incorrect.";
                Pin = "";
                FailedAttempts++;
            }
            else if (failure.IsAuthenticationFailure || failure.Code is "device_session_revoked")
            {
                session.HandleSessionFailure(failure);
            }
            else
            {
                Error = failure.Message;
            }
        }
        finally
        {
            IsBusy = false;
        }
    }
}
