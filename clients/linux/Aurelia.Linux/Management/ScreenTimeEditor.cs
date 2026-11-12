using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Playback;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>
/// The "Screen Time" part of the profile editor, like the Mac's (docs/SCREEN_TIME.md): bedtime and a daily limit
/// for school nights and the weekend, what closes, how a playing title ends, and today's exceptions.
/// </summary>
internal sealed class ScreenTimeEditor
{
    private static readonly (ScreenTimeLockScope Value, string Label)[] Scopes =
        [(ScreenTimeLockScope.PlaybackOnly, "Playback Only"), (ScreenTimeLockScope.WholeProfile, "The Whole Profile")];
    private static readonly (ScreenTimeEnding Value, string Label)[] Endings =
        [(ScreenTimeEnding.FinishTitle, "Let the Title Finish"), (ScreenTimeEnding.StopNow, "Stop Right Away")];

    private readonly ToggleSwitch enabled = new() { OnContent = "", OffContent = "" };
    private readonly StackPanel details = new() { Spacing = 10 };
    private readonly StackPanel today = new() { Spacing = 8 };
    private readonly TextBox overtime = new() { Width = 80 };
    private readonly (TextBox Bedtime, TextBox Wake, TextBox Limit) school;
    private readonly (TextBox Bedtime, TextBox Wake, TextBox Limit) weekend;
    private readonly Func<GrantScreenTimeRequest, Task<ProfileScreenTimeResponse?>>? grant;
    private ScreenTimeLockScope scope;
    private ScreenTimeEnding ending;

    public ScreenTimeEditor(ProfileScreenTimeResponse? loaded, Func<GrantScreenTimeRequest, Task<ProfileScreenTimeResponse?>>? grant)
    {
        this.grant = grant;
        var rules = loaded?.Rules ?? ScreenTimeRules.Default;
        enabled.IsChecked = rules.Enabled;
        AutomationProperties.SetName(enabled, "Screen Time");
        scope = rules.LockScope;
        ending = rules.Ending;
        overtime.Text = rules.MaxOvertimeMinutes.ToString(CultureInfo.InvariantCulture);
        AutomationProperties.SetName(overtime, "Finish within minutes");
        school = Fields(rules.SchoolNight, "School night");
        weekend = Fields(rules.Weekend, "Weekend");
        details.Children.Add(Choice("When time is up, close", "Playback only keeps browsing open. The whole profile closes until the wake time.",
            Scopes, scope, value => scope = value).Also(r => r.Margin = new Thickness(0)));
        details.Children.Add(Choice("A title that is playing", null, Endings, ending, value => ending = value).Also(r => r.Margin = new Thickness(0)));
        details.Children.Add(Row("Finish within (minutes)", "A title that runs longer stops this many minutes past the time.", overtime).Also(r => r.Margin = new Thickness(0)));
        details.Children.Add(Evening("School Nights", "Sunday to Thursday evening.", school));
        details.Children.Add(Evening("Weekend", "Friday and Saturday evening.", weekend));
        details.Children.Add(today);
        DrawToday(loaded);
        enabled.IsCheckedChanged += (_, _) => details.IsVisible = enabled.IsChecked == true;
        details.IsVisible = enabled.IsChecked == true;
        Section = Settings.SettingsRows.Section("Screen Time",
            Row("Screen Time", "A bedtime and a daily limit. The next episode does not start, and a good-night screen shows instead.", enabled),
            Block(details));
    }

    public Control Section { get; }

    /// <summary>The edited rules, or the first problem with them.</summary>
    public (ScreenTimeRules? Rules, string? Problem) Collect()
    {
        if (!int.TryParse(overtime.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var over)) return (null, "A title may run over by 0 to 180 minutes.");
        var schoolRule = Rule(school, "school-night", out var schoolProblem);
        if (schoolProblem is not null) return (null, schoolProblem);
        var weekendRule = Rule(weekend, "weekend", out var weekendProblem);
        if (weekendProblem is not null) return (null, weekendProblem);
        var rules = new ScreenTimeRules(enabled.IsChecked == true, scope, ending, over, schoolRule!, weekendRule!);
        return ScreenTimeText.Problem(rules) is { } problem ? (null, problem) : (rules, null);
    }

    private static ScreenTimeDayRule? Rule((TextBox Bedtime, TextBox Wake, TextBox Limit) fields, string label, out string? problem)
    {
        problem = null;
        var bedtime = string.IsNullOrWhiteSpace(fields.Bedtime.Text) ? null : ScreenTimeText.Time(fields.Bedtime.Text);
        if (!string.IsNullOrWhiteSpace(fields.Bedtime.Text) && bedtime is null) problem = $"Enter the {label} bedtime like 19:30.";
        else if (ScreenTimeText.Time(fields.Wake.Text) is null) problem = $"Enter the {label} wake time like 07:00.";
        int? limit = null;
        if (problem is null && !string.IsNullOrWhiteSpace(fields.Limit.Text))
        {
            if (int.TryParse(fields.Limit.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var minutes)) limit = minutes;
            else problem = $"The {label} daily limit is 5 to 1440 minutes.";
        }
        return problem is null ? new ScreenTimeDayRule(bedtime, ScreenTimeText.Time(fields.Wake.Text)!, limit) : null;
    }

    private static (TextBox Bedtime, TextBox Wake, TextBox Limit) Fields(ScreenTimeDayRule rule, string label)
    {
        var bedtime = new TextBox { Text = rule.Bedtime, PlaceholderText = "None", Width = 80 };
        var wake = new TextBox { Text = rule.WakeTime, PlaceholderText = "07:00", Width = 80 };
        var limit = new TextBox { Text = rule.DailyLimitMinutes?.ToString(CultureInfo.InvariantCulture), PlaceholderText = "No limit", Width = 90 };
        AutomationProperties.SetName(bedtime, $"{label} bedtime");
        AutomationProperties.SetName(wake, $"{label} wake time");
        AutomationProperties.SetName(limit, $"{label} daily limit in minutes");
        return (bedtime, wake, limit);
    }

    private static StackPanel Evening(string title, string help, (TextBox Bedtime, TextBox Wake, TextBox Limit) fields) => new()
    {
        Spacing = 6,
        Children =
        {
            new TextBlock { Text = title, FontWeight = Avalonia.Media.FontWeight.SemiBold },
            Note(help),
            Row("Bedtime", "Like 19:30; empty for none.", fields.Bedtime).Also(r => r.Margin = new Thickness(0)),
            Row("Wake time", "The next morning, like 07:00.", fields.Wake).Also(r => r.Margin = new Thickness(0)),
            Row("Daily limit (minutes)", "Empty for none.", fields.Limit).Also(r => r.Margin = new Thickness(0)),
        },
    };

    private void DrawToday(ProfileScreenTimeResponse? current)
    {
        today.Children.Clear();
        if (grant is null || current?.Status is not { } status) return;
        var summary = Note(ScreenTimeText.TodaySummary(status));
        Control Exception(string label, GrantScreenTimeRequest request) => Button(label, async () =>
        {
            if (await grant(request) is { } updated) DrawToday(updated);
        });
        var buttons = new List<Control> { Exception("+15 min", new(AddMinutes: 15)), Exception("+30 min", new(AddMinutes: 30)), Exception("+60 min", new(AddMinutes: 60)) };
        if (!current.Today.BedtimeLifted) buttons.Add(Exception("No Bedtime Tonight", new(LiftBedtime: true)));
        buttons.Add(Exception("One More Episode", new(OneMoreTitle: true)));
        today.Children.Add(new TextBlock { Text = "Today", FontWeight = Avalonia.Media.FontWeight.SemiBold });
        today.Children.Add(summary);
        today.Children.Add(Buttons([.. buttons]));
        today.Children.Add(Note("Exceptions last until the next wake time."));
    }
}
