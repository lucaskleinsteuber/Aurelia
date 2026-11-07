import SwiftUI

/// The player's Watch Together popover: start a party for this title, or see who watches along
/// and leave.
struct WatchTogetherPopover: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var controller: PlaybackController
  @State private var working = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Watch Together", systemImage: "person.2.fill").font(.headline)
      if let session = model.watchParty {
        WatchTogetherMembers(session: session)
        Button("Leave Watch Together", role: .destructive) {
          Task { await model.leaveWatchTogether() }
        }
        .accessibilityIdentifier("watch-together-leave")
      } else {
        Text(
          "Watch this title in step with other devices at home. They join from the title's page, and play, pause and jumps apply to everyone."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Button("Start Watch Together") {
          working = true
          Task {
            await model.startWatchTogether(with: controller)
            working = false
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(working)
        .accessibilityIdentifier("watch-together-start")
      }
    }
    .padding(16)
    .frame(width: 300)
  }
}

private struct WatchTogetherMembers: View {
  @ObservedObject var session: WatchTogetherSession

  var body: some View {
    if let state = session.state {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(state.members) { member in
          HStack {
            Image(systemName: member.isHost ? "crown.fill" : "person.fill")
              .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
              Text(member.isYou ? "\(member.name) (You)" : member.name)
              Text(member.deviceName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if member.isBuffering { ProgressView().controlSize(.small) }
          }
        }
        if state.isWaiting {
          Text("Waiting until everyone is ready…").font(.caption).foregroundStyle(.secondary)
        }
      }
    } else if let error = session.errorText {
      Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    } else {
      ProgressView()
    }
  }
}

/// A short notice in the player when someone else in the party acts, such as "Mia paused".
struct WatchTogetherNotice: View {
  @ObservedObject var session: WatchTogetherSession
  @Environment(\.aureliaReduceTransparency) private var reduceTransparency

  var body: some View {
    if let text = session.notice ?? (session.state?.isWaiting == true ? "Waiting until everyone is ready…" : nil) {
      Label(text, systemImage: "person.2.fill")
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .playerMaterial(reduceTransparency: reduceTransparency, shape: Capsule())
        .transition(.opacity)
        .accessibilityIdentifier("watch-together-notice")
    }
  }
}

/// On a title's page: parties others started for it, to join with one click.
struct WatchTogetherJoinButtons: View {
  @EnvironmentObject private var model: AppModel
  let mediaIds: Set<UUID>
  @State private var parties: [WatchPartySummary] = []

  var body: some View {
    ForEach(parties) { party in
      Button {
        Task { await model.joinWatchTogether(party) }
      } label: {
        Label("Join \(party.hostName)", systemImage: "person.2.fill")
      }
      .help("Watch \(party.title) together with \(party.hostName)")
      .accessibilityIdentifier("watch-together-join")
    }
    .task(id: mediaIds) {
      while !Task.isCancelled {
        let all = await model.watchParties()
        parties = all.filter { mediaIds.contains($0.mediaId) && $0.id != model.watchParty?.partyId }
        try? await Task.sleep(for: .seconds(10))
      }
    }
  }
}
