import AppIntents
import Foundation

// Siri and Shortcuts: wake the server, turn it off, play a title on the Apple TV and ask what
// plays. They run without opening Aurelia; everything but waking uses the Siri key from
// Settings › Smart Home (see SiriSupport.swift and docs/AUTOMATION.md).

enum SiriError: Error, CustomLocalizedStringResourceConvertible {
  case notConnected
  case noKey
  case server(String)

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notConnected: "Aurelia isn't connected to a server yet. Open Aurelia to connect."
    case .noKey: "Set up Siri first in Aurelia: Settings › Smart Home › Set Up Siri."
    case .server(let message): "\(message)"
    }
  }
}

private enum SiriContext {
  static func profile() throws -> StoredServerProfile {
    guard let profile = try? KeychainServerStore().load() else { throw SiriError.notConnected }
    return profile
  }

  static func client() throws -> IntegrationClient {
    let profile = try profile()
    guard let key = SiriKeyStore().load(server: profile.serverId) else { throw SiriError.noKey }
    return IntegrationClient(profile: profile, key: key)
  }

  static func message(_ error: Error) -> SiriError {
    if let siri = error as? SiriError { return siri }
    if let failure = error as? APIClientError, let message = failure.problemMessage { return .server(message) }
    return .server("The server isn't answering. It may be off; say “Turn on my Aurelia server”.")
  }
}

struct WakeServerIntent: AppIntent {
  static let title: LocalizedStringResource = "Turn On Aurelia Server"
  static let description = IntentDescription("Wakes the Aurelia server with Wake-on-LAN and waits until it answers.")

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let profile = try SiriContext.profile()
    guard !WakeOnLan.addresses(for: profile.serverId).isEmpty else {
      return .result(dialog: "Aurelia doesn't know how to wake this server. Open Aurelia once while the server is on.")
    }
    let checker = IntegrationClient(profile: profile, key: "")
    if await checker.answers() { return .result(dialog: "Your Aurelia server is already on.") }
    for _ in 0..<12 {
      WakeOnLan.wake(serverId: profile.serverId, lastKnown: profile.baseURL)
      try await Task.sleep(for: .seconds(5))
      if await checker.answers() { return .result(dialog: "Your Aurelia server is on.") }
    }
    return .result(dialog: "I sent the wake signal, but the server hasn't answered yet. It can take up to a minute when it was turned off.")
  }
}

enum PowerChoice: String, AppEnum {
  case sleep, shutdown

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Power Action"
  static let caseDisplayRepresentations: [PowerChoice: DisplayRepresentation] = [
    .sleep: "Sleep", .shutdown: "Turn Off",
  ]
}

struct TurnOffServerIntent: AppIntent {
  static let title: LocalizedStringResource = "Turn Off Aurelia Server"
  static let description = IntentDescription("Puts the Aurelia server to sleep or turns it off.")

  @Parameter(title: "Action", default: .shutdown) var action: PowerChoice

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let client = try SiriContext.client()
    let status: IntegrationStatus
    do { status = try await client.status() } catch { throw SiriContext.message(error) }
    let wanted = status.powerActions.contains(action.rawValue) ? action.rawValue : status.powerActions.first
    guard let wanted else { return .result(dialog: "This server can't turn itself off.") }
    if !status.playing.isEmpty {
      try await requestConfirmation(dialog: "Someone is watching on \(status.playing[0].device.name). Turn the server off anyway?")
    }
    do {
      return .result(dialog: "\(try await client.powerNow(wanted))")
    } catch {
      throw SiriContext.message(error)
    }
  }
}

struct PlayInAureliaIntent: AppIntent {
  static let title: LocalizedStringResource = "Play in Aurelia"
  static let description = IntentDescription(
    "Plays a movie or an episode on the Apple TV or another device that has Aurelia open, for example “Breaking Bad season 3 episode 4”.")

  @Parameter(title: "Title", requestValueDialog: "What should I play?") var request: String
  @Parameter(title: "Device") var device: String?

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let client = try SiriContext.client()
    let parsed = SiriTitleRequest.parse(request)
    guard !parsed.title.isEmpty else { return .result(dialog: "Say a movie or a show.") }
    do {
      let players = try await client.players()
      guard let player = SiriTitleRequest.player(players, named: device) else {
        return .result(dialog: players.isEmpty
          ? "No device has Aurelia open. Open Aurelia on the Apple TV first."
          : "Say which device: \(players.map(\.deviceName).joined(separator: ", ")).")
      }
      guard let title = SiriTitleRequest.best(try await client.search(parsed.title), for: parsed) else {
        return .result(dialog: "I couldn't find “\(parsed.title)” in your library.")
      }
      let target: IntegrationTitle
      if title.kind == "series", let season = parsed.season, let episode = parsed.episode {
        target = try await client.episode(of: title.id, season: season, episode: episode)
      } else if title.kind == "series" {
        target = try await client.next(in: title.id)
      } else {
        target = title
      }
      try await client.play(target.id, on: player.deviceId)
      let what = target.seasonNumber.map { "\(title.title), season \($0), episode \(target.episodeNumber ?? 0)" } ?? target.title
      return .result(dialog: "Playing \(what) on \(player.deviceName).")
    } catch {
      throw SiriContext.message(error)
    }
  }
}

struct WhatsPlayingIntent: AppIntent {
  static let title: LocalizedStringResource = "What's Playing in Aurelia"
  static let description = IntentDescription("Says what is playing on which device.")

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let client = try SiriContext.client()
    let status: IntegrationStatus
    do { status = try await client.status() } catch { throw SiriContext.message(error) }
    guard !status.playing.isEmpty else { return .result(dialog: "Nothing is playing.") }
    let lines = status.playing.map { entry in
      let title = entry.media.seriesTitle.map { "\($0), season \(entry.media.season ?? 0), episode \(entry.media.episode ?? 0)" }
        ?? entry.media.title
      return "\(title) on \(entry.device.name)\(entry.state == "paused" ? ", paused" : "")"
    }
    return .result(dialog: "\(lines.joined(separator: ". "))")
  }
}

struct AureliaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: WakeServerIntent(),
      phrases: ["Turn on my \(.applicationName) server", "Wake \(.applicationName)", "Wake my \(.applicationName) server"],
      shortTitle: "Turn On Server", systemImageName: "power")
    AppShortcut(
      intent: TurnOffServerIntent(),
      phrases: ["Turn off my \(.applicationName) server", "Put \(.applicationName) to sleep"],
      shortTitle: "Turn Off Server", systemImageName: "moon")
    AppShortcut(
      intent: PlayInAureliaIntent(),
      phrases: ["Play in \(.applicationName)", "Play something in \(.applicationName)", "Watch in \(.applicationName)"],
      shortTitle: "Play", systemImageName: "play.fill")
    AppShortcut(
      intent: WhatsPlayingIntent(),
      phrases: ["What's playing in \(.applicationName)", "What's on in \(.applicationName)"],
      shortTitle: "What's Playing", systemImageName: "tv")
  }
}
