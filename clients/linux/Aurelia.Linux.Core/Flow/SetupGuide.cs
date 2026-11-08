using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Flow;

/// <summary>Who watches with this server: decides whether the assistant offers to add profiles.</summary>
public enum SetupAudience
{
    JustMe,
    SeveralPeople,
}

/// <summary>The other devices the owner wants to use; the last page explains how to connect each.</summary>
[Flags]
public enum SetupDevices
{
    None = 0,
    AppleTv = 1,
    PhoneOrTablet = 2,
    Computer = 4,
    WebBrowser = 8,
}

/// <summary>A step of the guided setup, shown in the step bar above each setup screen.</summary>
public enum SetupStep
{
    Choose,
    Secure,
    Pin,
    Media,
    People,
    Connect,
    Profile,
    Done,
}

/// <summary>
/// The setup assistant: a short introduction, a few questions, then the real setup screens under a step bar,
/// a last page with what was done and how to connect other devices, and a short tour of the library.
/// It shows only on a computer that has never been set up, and every part can be skipped.
/// </summary>
public sealed class SetupGuide : ObservableObject
{
    public const string IntroSeenKey = "setupGuide.introSeen";
    public const string GuidingKey = "setupGuide.guiding";
    public const string AudienceKey = "setupGuide.audience";
    public const string DevicesKey = "setupGuide.devices";
    public const string TourPendingKey = "setupGuide.tourPending";

    private readonly ISettingsStore store;
    private bool guiding;
    private bool tourPending;

    public SetupGuide(ISettingsStore store, bool alreadySetUp)
    {
        this.store = store;
        // A computer that already had Aurelia set up before the assistant existed never sees it.
        if (alreadySetUp && store.Read<bool?>(IntroSeenKey) is null) store.Write(IntroSeenKey, true);
        guiding = store.Read<bool?>(GuidingKey) ?? false;
        tourPending = store.Read<bool?>(TourPendingKey) ?? false;
    }

    /// <summary>The first screen asked "New to Aurelia?" once already.</summary>
    public bool IntroSeen => store.Read<bool?>(IntroSeenKey) ?? false;

    /// <summary>The owner chose "Show Me Around" and setup is not finished yet.</summary>
    public bool IsGuiding
    {
        get => guiding;
        private set
        {
            store.Write(GuidingKey, value);
            SetProperty(ref guiding, value);
        }
    }

    /// <summary>The library tour waits for the next time the library shows.</summary>
    public bool TourPending
    {
        get => tourPending;
        private set
        {
            store.Write(TourPendingKey, value);
            SetProperty(ref tourPending, value);
        }
    }

    public SetupAudience Audience
    {
        get => store.Read<string>(AudienceKey) == "several" ? SetupAudience.SeveralPeople : SetupAudience.JustMe;
        set => store.Write(AudienceKey, value == SetupAudience.SeveralPeople ? "several" : "me");
    }

    public SetupDevices Devices
    {
        get => (SetupDevices)(store.Read<int?>(DevicesKey) ?? 0) & (SetupDevices.AppleTv | SetupDevices.PhoneOrTablet | SetupDevices.Computer | SetupDevices.WebBrowser);
        set => store.Write(DevicesKey, (int)value);
    }

    /// <summary>"Show Me Around": the questions, the guided setup and the tour follow.</summary>
    public void Start()
    {
        store.Write(IntroSeenKey, true);
        IsGuiding = true;
        OnPropertyChanged(nameof(IntroSeen));
    }

    /// <summary>"I Know Aurelia", or "Skip Assistant" on any step: the normal setup screens, without guidance or tour.</summary>
    public void Skip()
    {
        store.Write(IntroSeenKey, true);
        IsGuiding = false;
        OnPropertyChanged(nameof(IntroSeen));
    }

    /// <summary>"Start Watching" on the last page: guidance ends and the tour shows in the library.</summary>
    public void Finish()
    {
        IsGuiding = false;
        TourPending = true;
    }

    /// <summary>Settings › About › Show Tour.</summary>
    public void RequestTour() => TourPending = true;

    public void TourShown() => TourPending = false;

    /// <summary>The steps of the step bar: hosting on this computer, or connecting to a server elsewhere.</summary>
    public IReadOnlyList<SetupStep> Steps(OperatingMode? mode) => mode == OperatingMode.Client
        ? [SetupStep.Choose, SetupStep.Connect, SetupStep.Profile, SetupStep.Done]
        : Audience == SetupAudience.SeveralPeople
            ? [SetupStep.Choose, SetupStep.Secure, SetupStep.Pin, SetupStep.Media, SetupStep.People, SetupStep.Done]
            : [SetupStep.Choose, SetupStep.Secure, SetupStep.Pin, SetupStep.Media, SetupStep.Done];

    public static string Title(SetupStep step) => step switch
    {
        SetupStep.Choose => "Choose",
        SetupStep.Secure => "Secure",
        SetupStep.Pin => "Your PIN",
        SetupStep.Media => "Your Media",
        SetupStep.People => "People",
        SetupStep.Connect => "Connect",
        SetupStep.Profile => "Profile",
        _ => "Done",
    };
}
