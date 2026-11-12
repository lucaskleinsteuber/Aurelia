import SwiftUI

/// The "Screen Time" part of the profile editor (docs/SCREEN_TIME.md): bedtime and a daily limit
/// for school nights and the weekend, what closes, how a playing title ends, and today's exceptions.
struct ScreenTimeSection: View {
  @Binding var rules: ScreenTimeRules
  /// The saved profile's state; nil while a profile is being created.
  let current: ProfileScreenTime?
  /// Applies an exception for today at once; nil while a profile is being created.
  let grant: ((ScreenTimeGrant) async -> Void)?
  @State private var granting = false

  var body: some View {
    GroupBox("Screen Time") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Screen Time", isOn: $rules.enabled)
          .toggleStyle(.switch)
          .accessibilityIdentifier("profile-editor-screen-time")
        Text(
          "A bedtime and a daily limit. The next episode does not start, and a good-night screen shows instead."
        )
        .font(.caption).foregroundStyle(.secondary)
        if rules.enabled {
          Picker("When time is up, close", selection: $rules.lockScope) {
            ForEach(ScreenTimeLockScope.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .accessibilityIdentifier("profile-editor-screen-time-scope")
          Text("Playback only keeps browsing open. The whole profile closes until the wake time.")
            .font(.caption).foregroundStyle(.secondary)
          Picker("A title that is playing", selection: $rules.ending) {
            ForEach(ScreenTimeEnding.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .accessibilityIdentifier("profile-editor-screen-time-ending")
          if rules.ending == .finishTitle {
            Stepper(
              "Finish within \(rules.maxOvertimeMinutes) minutes",
              value: $rules.maxOvertimeMinutes, in: 0...180, step: 5)
            Text("A title that runs longer stops after this many minutes past the time.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Divider()
          evening("School Nights", "Sunday to Thursday evening.", $rules.schoolNight)
          Divider()
          evening("Weekend", "Friday and Saturday evening.", $rules.weekend)
          if let current, let status = current.status, let grant {
            Divider()
            today(status, today: current.today, grant: grant)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
    }
  }

  private func evening(_ title: String, _ help: String, _ rule: Binding<ScreenTimeDayRule>)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      Text(help).font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Toggle(
          "Bedtime",
          isOn: Binding(
            get: { rule.wrappedValue.bedtime != nil },
            set: { rule.wrappedValue.bedtime = $0 ? (rule.wrappedValue.bedtime ?? "19:30") : nil }))
        if rule.wrappedValue.bedtime != nil {
          DatePicker(
            "Bedtime", selection: Self.time(rule.bedtime, fallback: "19:30"),
            displayedComponents: .hourAndMinute
          )
          .labelsHidden()
        }
        Spacer(minLength: 20)
        DatePicker(
          "Wake time", selection: Self.time(rule.wakeTime), displayedComponents: .hourAndMinute)
      }
      HStack(spacing: 12) {
        Toggle(
          "Daily limit",
          isOn: Binding(
            get: { rule.wrappedValue.dailyLimitMinutes != nil },
            set: {
              rule.wrappedValue.dailyLimitMinutes =
                $0 ? (rule.wrappedValue.dailyLimitMinutes ?? 60) : nil
            }))
        if let minutes = rule.wrappedValue.dailyLimitMinutes {
          Stepper(
            ScreenTimeSection.duration(minutes),
            value: Binding(
              get: { minutes }, set: { rule.wrappedValue.dailyLimitMinutes = $0 }),
            in: 15...720, step: 15)
        }
      }
    }
  }

  private func today(
    _ status: ScreenTimeStatus, today: ScreenTimeToday,
    grant: @escaping (ScreenTimeGrant) async -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Today").font(.headline)
      Text(ScreenTimeText.todaySummary(status)).font(.callout).foregroundStyle(.secondary)
        .accessibilityIdentifier("profile-editor-screen-time-today")
      HStack {
        ForEach([15, 30, 60], id: \.self) { minutes in
          Button("+\(minutes) min") { run(grant, ScreenTimeGrant(addMinutes: minutes)) }
        }
        if !today.bedtimeLifted {
          Button("No Bedtime Tonight") { run(grant, ScreenTimeGrant(liftBedtime: true)) }
        }
        Button("One More Episode") { run(grant, ScreenTimeGrant(oneMoreTitle: true)) }
      }
      .disabled(granting)
      Text("Exceptions last until the next wake time.").font(.caption).foregroundStyle(.secondary)
    }
  }

  private func run(_ grant: @escaping (ScreenTimeGrant) async -> Void, _ value: ScreenTimeGrant) {
    granting = true
    Task {
      await grant(value)
      granting = false
    }
  }

  static func duration(_ minutes: Int) -> String {
    minutes < 60
      ? "\(minutes) min"
      : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
  }

  /// A "HH:mm" string as the date a time picker edits, today in this Mac's calendar.
  static func time(_ value: Binding<String>, fallback: String = "07:00") -> Binding<Date> {
    Binding(
      get: { date(value.wrappedValue) ?? date(fallback) ?? Date() },
      set: { value.wrappedValue = text($0) })
  }

  static func time(_ value: Binding<String?>, fallback: String) -> Binding<Date> {
    Binding(
      get: { date(value.wrappedValue ?? fallback) ?? Date() },
      set: { value.wrappedValue = text($0) })
  }

  static func date(_ text: String) -> Date? {
    guard let clean = ScreenTimeText.time(text) else { return nil }
    let parts = clean.split(separator: ":").compactMap { Int($0) }
    return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
  }

  static func text(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }
}
