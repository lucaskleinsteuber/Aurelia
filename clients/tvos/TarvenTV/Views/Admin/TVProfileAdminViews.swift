import SwiftUI

// MARK: Screen time (screen-time-v1), for the owner

/// The children's profiles, each with its screen time.
struct TVScreenTimeProfilesPage: View {
  @ObservedObject var admin: TVAdministrationModel
  @State private var users: [TVUserAccessSummary]?

  var body: some View {
    TVSettingsPage(
      symbol: "moon.stars", title: "Screen Time",
      subtitle: "A bedtime, a wake time and a daily limit for a profile, and more time today."
    ) {
      if let users {
        let profiles = users.filter { $0.user.role == "user" }
        if profiles.isEmpty { TVSettingsNote(text: "There are no viewer profiles yet.") }
        ForEach(profiles) { summary in
          NavigationLink {
            TVScreenTimeEditor(admin: admin, user: summary.user).tvAdministration(admin)
          } label: {
            HStack {
              Text(summary.user.displayName ?? summary.user.username)
              Spacer()
              Image(systemName: "chevron.right").opacity(0.5)
            }
            .padding(.horizontal, 30).frame(maxWidth: .infinity, minHeight: 72)
          }
          .buttonStyle(TVButtonStyle(kind: .row))
          .accessibilityIdentifier("screen-time-\(summary.user.id)")
        }
      }
    }
    .task { users = await admin.value { try await $0.serverUsers() } }
  }
}

/// One profile's screen time: the rules with the remote (times in 15-minute steps) and Today's
/// extra time, No Bedtime Tonight and One More Episode.
struct TVScreenTimeEditor: View {
  @ObservedObject var admin: TVAdministrationModel
  let user: TVAdminUser
  @State private var stored: TVProfileScreenTime?
  @State private var rules = TVScreenTimeRules.default
  @State private var saving = false

  private static let times = (0..<96).map { String(format: "%02d:%02d", $0 / 4, $0 % 4 * 15) }
  private static let limits: [Int?] = [nil, 30, 45, 60, 90, 120, 150, 180, 240]

  var body: some View {
    TVSettingsPage(
      symbol: "moon.stars.fill", title: user.displayName ?? user.username,
      subtitle: "The server decides in its own time zone and counts only time that played."
    ) {
      if let stored {
        TVSettingsRow(title: "Screen Time", value: rules.enabled ? "On" : "Off", id: "st-enabled") {
          rules.enabled.toggle()
        }
        if rules.enabled {
          day("School Nights (Sunday to Thursday)", \.schoolNight, id: "school")
          day("Weekend", \.weekend, id: "weekend")
          TVSettingsHeader(text: "When Time Is Up")
          TVSettingsRow(
            title: "Close",
            value: rules.lockScope == "wholeProfile" ? "The Whole Profile" : "Only Playback",
            id: "st-scope"
          ) {
            rules.lockScope = rules.lockScope == "wholeProfile" ? "playbackOnly" : "wholeProfile"
          }
          TVSettingsRow(
            title: "A Playing Title",
            value: rules.ending == "finishTitle" ? "May Finish" : "Stops at Once", id: "st-ending"
          ) { rules.ending = rules.ending == "finishTitle" ? "stopNow" : "finishTitle" }
          if rules.ending == "finishTitle" {
            TVSettingsRow(
              title: "For at Most", value: "\(rules.maxOvertimeMinutes) minutes", id: "st-overtime"
            ) {
              rules.maxOvertimeMinutes = TVSettingsRow.next(
                after: rules.maxOvertimeMinutes, in: [15, 30, 45, 60, 90, 120])
            }
          }
          TVSettingsRow(
            title: "Allow Offline Downloads", value: rules.allowOfflineDownloads ? "On" : "Off",
            id: "st-downloads"
          ) { rules.allowOfflineDownloads.toggle() }
          TVSettingsNote(
            text:
              "Off by default so offline downloads cannot bypass bedtime or daily limits. Existing downloads stay on devices."
          )
        }
        TVSettingsRow(
          title: saving ? "Saving…" : "Save", value: rules == stored.rules ? "Saved" : nil,
          id: "st-save"
        ) { Task { await save() } }
        .disabled(saving || rules == stored.rules)

        TVSettingsHeader(text: "Today")
        if let status = stored.status {
          TVSettingsRow(
            title: "Watched Today",
            value: status.limitMinutes.map { "\(status.watchedMinutesToday) of \($0) min" }
              ?? "\(status.watchedMinutesToday) min")
        }
        if stored.today.extraMinutes > 0 {
          TVSettingsRow(title: "Extra Today", value: "+\(stored.today.extraMinutes) min")
        }
        TVSettingsRow(title: "15 Minutes More", id: "st-plus15") { grant(.init(addMinutes: 15)) }
        TVSettingsRow(title: "30 Minutes More", id: "st-plus30") { grant(.init(addMinutes: 30)) }
        TVSettingsRow(
          title: "No Bedtime Tonight", value: stored.today.bedtimeLifted ? "On" : nil,
          id: "st-no-bedtime"
        ) { grant(.init(liftBedtime: true)) }
        .disabled(stored.today.bedtimeLifted)
        TVSettingsRow(
          title: "One More Episode",
          value: stored.today.oneMoreTitle ? (stored.today.oneMoreTitleUsed ? "Used" : "On") : nil,
          id: "st-one-more"
        ) { grant(.init(oneMoreTitle: true)) }
        .disabled(stored.today.oneMoreTitle)
        TVSettingsNote(text: "Today's extras last until the next wake time.")
      }
    }
    .task { await load() }
  }

  @ViewBuilder
  private func day(
    _ title: String, _ key: WritableKeyPath<TVScreenTimeRules, TVScreenTimeDayRule>, id: String
  ) -> some View {
    TVSettingsHeader(text: title)
    TVSettingsRow(
      title: "Bedtime", value: rules[keyPath: key].bedtime ?? "None", id: "st-\(id)-bed"
    ) {
      let choices: [String?] = [nil] + Self.times.map(Optional.some)
      rules[keyPath: key].bedtime = TVSettingsRow.next(
        after: rules[keyPath: key].bedtime, in: choices)
    }
    TVSettingsRow(title: "Wake Time", value: rules[keyPath: key].wakeTime, id: "st-\(id)-wake") {
      rules[keyPath: key].wakeTime = TVSettingsRow.next(
        after: rules[keyPath: key].wakeTime, in: Self.times)
    }
    TVSettingsRow(
      title: "Daily Limit",
      value: rules[keyPath: key].dailyLimitMinutes.map { TVScreenTimeAdminText.minutes($0) }
        ?? "None", id: "st-\(id)-limit"
    ) {
      rules[keyPath: key].dailyLimitMinutes = TVSettingsRow.next(
        after: rules[keyPath: key].dailyLimitMinutes, in: Self.limits)
    }
  }

  private func load() async {
    let id = user.id
    if let value = await admin.value({ try await $0.screenTime(user: id) }) {
      stored = value
      rules = value.rules
    }
  }

  private func save() async {
    guard let stored else { return }
    saving = true
    defer { saving = false }
    let id = user.id
    let update = TVProfileScreenTimeUpdate(rules: rules, revision: stored.revision)
    do {
      let saved = try await admin.run { try await $0.setScreenTime(user: id, update) }
      self.stored = saved
      rules = saved.rules
    } catch is CancellationError {
    } catch let failure as TVCoreError where failure.isConflict {
      admin.alert = "Screen time was changed on another device. It shows the newest now."
      await load()
    } catch {
      admin.alert = TVAdministrationModel.message(error)
    }
  }

  private func grant(_ value: TVScreenTimeGrant) {
    let id = user.id
    Task {
      if let saved = await admin.value({ try await $0.grantScreenTime(user: id, value) }) {
        stored = saved
      }
    }
  }
}

// MARK: Review Matches

/// Titles whose TMDB match the server wasn't sure about: choose one of its candidates, or search.
struct TVReviewMatchesPage: View {
  @ObservedObject var admin: TVAdministrationModel
  @State private var reviews: [TVMetadataReview]?

  var body: some View {
    TVSettingsPage(
      symbol: "checkmark.seal", title: "Review Matches",
      subtitle: "Choose what a title really is; its information and artwork follow."
    ) {
      if let reviews {
        if reviews.isEmpty { TVSettingsNote(text: "Nothing to review.") }
        ForEach(reviews) { review in
          NavigationLink {
            TVMatchChooser(admin: admin, review: review) {
              self.reviews?.removeAll { $0.id == review.id }
            }
            .tvAdministration(admin)
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              Text(review.title)
              Text(review.reason).font(.system(size: 21)).opacity(0.65)
            }
            .padding(.horizontal, 30).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
          }
          .buttonStyle(TVButtonStyle(kind: .row))
        }
      }
    }
    .task(id: admin.revision) { reviews = await admin.value { try await $0.metadataReviews() } }
  }
}

private struct TVMatchChooser: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var admin: TVAdministrationModel
  let review: TVMetadataReview
  let matched: () -> Void
  @State private var query: String
  @State private var candidates: [TVMetadataCandidate]

  init(admin: TVAdministrationModel, review: TVMetadataReview, matched: @escaping () -> Void) {
    self.admin = admin
    self.review = review
    self.matched = matched
    _query = State(initialValue: review.title)
    _candidates = State(initialValue: review.candidates)
  }

  var body: some View {
    TVSettingsPage(
      symbol: "magnifyingglass", title: review.title,
      subtitle: "Choose the right title. Saved manual changes stay in place."
    ) {
      TextField("Search TMDB", text: $query)
        .onSubmit { Task { await search() } }
        .accessibilityIdentifier("match-search")
      ForEach(candidates) { candidate in
        TVSettingsRow(
          title: [candidate.title, candidate.year.map(String.init)].compactMap { $0 }
            .joined(separator: " · "),
          value: candidate.mediaType == "tv" ? "Series" : "Movie"
        ) { Task { await choose(candidate) } }
      }
      if candidates.isEmpty { TVSettingsNote(text: "No candidates. Search with other words.") }
    }
  }

  private func search() async {
    let id = review.mediaId
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if let found = await admin.value({ try await $0.searchMetadata(mediaId: id, query: text) }) {
      candidates = found
    }
  }

  private func choose(_ candidate: TVMetadataCandidate) async {
    let id = review.mediaId
    if await admin.perform({ try await $0.selectMetadataMatch(mediaId: id, candidate: candidate) })
    {
      matched()
      dismiss()
    }
  }
}

// MARK: New devices (security-v1), for the owner

struct TVNewDevicesPage: View {
  @ObservedObject var admin: TVAdministrationModel
  @State private var devices: [TVSecurityDevice]?

  var body: some View {
    TVSettingsPage(
      symbol: "person.badge.shield.checkmark", title: "New Devices",
      subtitle: "Devices that signed in. That Was Me keeps one; Block signs it out for good."
    ) {
      if let devices {
        let shown = devices.filter { !$0.isCurrent }
        if shown.isEmpty { TVSettingsNote(text: "No other devices.") }
        ForEach(shown) { device in
          TVDeviceRow(admin: admin, device: device) { await load() }
        }
      }
    }
    .task(id: admin.revision) { await load() }
  }

  private func load() async {
    devices = await admin.value { try await $0.securityDevices() }
  }
}

struct TVDeviceRow: View {
  @ObservedObject var admin: TVAdministrationModel
  let device: TVSecurityDevice
  let changed: () async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("\(device.deviceName) · \(device.userName)").font(.system(size: 28, weight: .semibold))
        if device.isNew {
          Text("New").font(.system(size: 20, weight: .bold)).padding(.horizontal, 10)
            .background(Color.orange.opacity(0.8), in: Capsule())
        }
      }
      Text(
        [
          TVSecurityText.deviceLine(platform: device.platform, ipAddress: device.ipAddress),
          "Last seen \(TVAdminFormat.date(device.lastSeenAt))",
        ].filter { !$0.isEmpty }
          .joined(separator: " · ")
      )
      .font(.system(size: 22)).foregroundStyle(.secondary)
      HStack(spacing: 24) {
        if device.isNew {
          Button("That Was Me") {
            Task {
              if await admin.perform({ try await $0.acknowledgeDevice(id: device.id) }) {
                await changed()
              }
            }
          }
        }
        if device.canBlock {
          Button("Block", role: .destructive) {
            Task {
              if await admin.perform({ _ = try await $0.blockDevice(id: device.id) }) {
                await changed()
              }
            }
          }
        }
      }
      .buttonStyle(TVButtonStyle())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10).padding(.vertical, 14)
  }
}

/// While the app is open on Home, the owner hears about a device that just signed in, as on the
/// Mac and the iPhone. It waits on the server's alerts and never shows during playback.
@MainActor
final class TVSecurityAlertCenter: ObservableObject {
  @Published private(set) var device: TVSecurityDevice?
  private var version: Int64 = 0
  private var task: Task<Void, Never>?
  private var dismissed = Set<UUID>()

  func start(client: @escaping @MainActor () -> TVAPIClient?) {
    guard task == nil else { return }
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let api = client() else { return }
        do {
          let alerts = try await api.securityAlerts(version: self.version, waitSeconds: 25)
          self.version = alerts.version
          if let fresh = alerts.newDevices.first(where: {
            $0.isNew && !self.dismissed.contains($0.id)
          }) {
            self.device = fresh
          }
        } catch is CancellationError {
          return
        } catch {
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  func handled(_ id: UUID) {
    dismissed.insert(id)
    if device?.id == id { device = nil }
  }
}
