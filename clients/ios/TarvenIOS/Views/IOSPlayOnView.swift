import SwiftUI

/// Play On: the other Tarven players signed in to this server. Choosing one starts the title
/// there, and the sheet becomes its remote: play and pause, skip, position and stop.
struct IOSPlayOnView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let mediaID: UUID
  let title: String

  @State private var players: [IOSRemotePlayer]?
  @State private var controlled: IOSRemotePlayer?
  @State private var error: String?
  @State private var busy = false
  @State private var scrub: Double?

  var body: some View {
    NavigationStack {
      Group {
        if let controlled {
          remote(controlled)
        } else if let players {
          list(players)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle(controlled == nil ? "Play On" : controlled?.deviceName ?? "")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.accessibilityIdentifier("play-on-done")
        }
      }
    }
    .presentationDetents([.medium, .large])
    .task { await load() }
    .task(id: controlled?.deviceId) { await follow() }
  }

  private func list(_ players: [IOSRemotePlayer]) -> some View {
    List {
      Section {
        if players.isEmpty {
          Text(IOSRemotePlaybackText.empty).foregroundStyle(.secondary)
        }
        ForEach(players) { player in
          Button {
            Task { await start(on: player) }
          } label: {
            HStack(spacing: 14) {
              Image(systemName: player.symbol).font(.title3)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(width: 32)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 2) {
                Text(player.deviceName).font(.body.weight(.semibold))
                Text("\(player.kindTitle) · \(player.statusText)")
                  .font(.footnote).foregroundStyle(.secondary)
                  .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
              }
              Spacer()
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(busy)
          .accessibilityIdentifier("play-on-\(player.deviceId)")
        }
      } header: {
        Text("Play “\(title)” On")
      } footer: {
        if let error { Text(error).foregroundStyle(.orange) }
      }
    }
    .refreshable { await load() }
  }

  private func remote(_ player: IOSRemotePlayer) -> some View {
    ScrollView {
      VStack(spacing: 22) {
        VStack(spacing: 6) {
          Image(systemName: player.symbol).font(.system(size: 40, weight: .light))
            .accessibilityHidden(true)
          Text(player.title ?? title).font(.headline).multilineTextAlignment(.center)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          Text(player.isPlaying ? (player.isPaused ? "Paused" : "Playing") : "Starting…")
            .font(.subheadline).foregroundStyle(.secondary)
        }
        if let duration = player.durationSeconds, duration > 0 {
          VStack(spacing: 4) {
            Slider(
              value: Binding(
                get: { scrub ?? min(player.positionSeconds ?? 0, duration) },
                set: { scrub = $0 }),
              in: 0...duration,
              onEditingChanged: { editing in
                guard !editing, let target = scrub else { return }
                scrub = nil
                send(.seek(milliseconds: Int64(target * 1_000)))
              }
            )
            .accessibilityLabel("Playback Position").accessibilityIdentifier("play-on-position")
            if let text = IOSRemotePlaybackText.position(
              scrub ?? player.positionSeconds, of: duration)
            {
              Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
          }
        }
        HStack(spacing: 24) {
          remoteButton("Back 10 Seconds", symbol: "gobackward.10", id: "back") {
            send(.skip(milliseconds: -10_000))
          }
          remoteButton(
            player.isPaused || !player.isPlaying ? "Play" : "Pause",
            symbol: player.isPaused || !player.isPlaying ? "play.fill" : "pause.fill", id: "toggle",
            size: 28, diameter: 60
          ) {
            send(player.isPaused || !player.isPlaying ? .resume : .pause)
          }
          remoteButton("Forward 10 Seconds", symbol: "goforward.10", id: "forward") {
            send(.skip(milliseconds: 10_000))
          }
        }
        Button("Stop Playback", systemImage: "stop.fill", role: .destructive) {
          send(.stop)
          controlled = nil
        }
        .buttonStyle(IOSButtonStyle(kind: .secondary))
        .accessibilityIdentifier("play-on-stop")
        if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
      }
      .padding(24)
      .frame(maxWidth: 520)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  private func remoteButton(
    _ label: String, symbol: String, id: String, size: CGFloat = 22, diameter: CGFloat = 52,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: size, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: diameter, height: diameter)
        .background(reduceTransparency ? IOSDesign.surface : IOSDesign.raised, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(IOSContentButtonStyle())
    .accessibilityLabel(label).accessibilityIdentifier("play-on-\(id)")
  }

  private func client() -> IOSAPIClient? {
    guard let connection = model.connection, let session = model.session else { return nil }
    return model.makeClient(connection: connection, session: session)
  }

  private func load() async {
    guard let api = client() else { return }
    do {
      players = try await api.remotePlayers(currentDeviceId: model.tvDeviceId)
      error = nil
    } catch {
      players = players ?? []
      self.error = "The players could not be loaded. \(error.localizedDescription)"
    }
  }

  private func start(on player: IOSRemotePlayer) async {
    guard let api = client(), !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await api.sendRemoteCommand(.play(mediaID), to: player.deviceId)
      error = nil
      controlled = player
    } catch {
      self.error = "\(player.deviceName) could not start the title. \(error.localizedDescription)"
    }
  }

  private func send(_ action: IOSRemoteAction) {
    guard let api = client(), let player = controlled else { return }
    Task {
      do {
        try await api.sendRemoteCommand(action, to: player.deviceId)
        error = nil
        if let status = try? await api.remotePlayerStatus(deviceId: player.deviceId) {
          controlled = status
        }
      } catch {
        self.error = "\(player.deviceName) did not answer. \(error.localizedDescription)"
      }
    }
  }

  /// The remote follows what the device reports, every two seconds while it is open.
  private func follow() async {
    guard let deviceId = controlled?.deviceId, let api = client() else { return }
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard controlled?.deviceId == deviceId, scrub == nil else { continue }
      if let status = try? await api.remotePlayerStatus(deviceId: deviceId) {
        controlled = status
      }
    }
  }
}
