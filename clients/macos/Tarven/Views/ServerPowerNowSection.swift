import SwiftUI

/// Settings › Power › Right Now for the owner: Sleep, Turn Off or Stop Now, without waiting for
/// the unused minutes ("power-now-v1").
struct ServerPowerNowSection: View {
  @EnvironmentObject private var model: AppModel
  @State private var actions: [String]?
  @State private var message: String?
  @State private var problem: String?
  @State private var working = false
  @State private var confirmation: Confirmation?

  struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: String
    let perform: () -> Void
  }

  private var client: APIClient? { model.profile.map(APIClient.init(profile:)) }

  var body: some View {
    if model.profile?.user?.role == .owner, PowerNowText.isOffered(by: model.libraryCapabilities) {
      TarvenSettingsSection(
        "Right Now", symbol: "power",
        description: "Without waiting for the unused minutes."
      ) {
        VStack(alignment: .leading, spacing: 10) {
          if let actions {
            if actions.isEmpty {
              Text(
                "This server can't turn itself off; it runs as a service that something else starts and stops."
              )
              .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(actions, id: \.self) { action in
              LabeledContent {
                Button(PowerNowText.title(action)) {
                  confirmation = Confirmation(
                    title: "\(PowerNowText.title(action))?", message: PowerNowText.detail(action),
                    action: PowerNowText.title(action)
                  ) { Task { await powerNow(action, force: false) } }
                }
                .disabled(working)
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(PowerNowText.title(action))
                  Text(PowerNowText.detail(action)).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          } else if let problem {
            ErrorBanner(message: problem, retry: { Task { await load() } }, inline: true)
          } else {
            TarvenDelayedProgress(controlSize: .small)
          }
          if let message {
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .task(id: model.profile?.serverId) { await load() }
      .alert(
        confirmation?.title ?? "",
        isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
        presenting: confirmation
      ) { item in
        Button(item.action, role: .destructive) { item.perform() }
        Button("Cancel", role: .cancel) {}
      } message: { item in
        Text(item.message)
      }
    }
  }

  private func load() async {
    guard let client else { return }
    let capabilities = model.libraryCapabilities
    do {
      actions = PowerNowText.known(try await client.powerNowActions(capabilities: capabilities))
      problem = nil
    } catch is CancellationError {
    } catch let failure as APIClientError where failure.isManagementLocked {
      if await model.unlockManagementInteractively() {
        await load()
      } else {
        problem = "Turning the server off needs the Server Password. Try again to enter it."
      }
    } catch {
      problem = error.localizedDescription
    }
  }

  private func powerNow(_ action: String, force: Bool) async {
    guard let client else { return }
    working = true
    defer { working = false }
    do {
      message = try await client.powerNow(action: action, force: force).message
    } catch let failure as APIClientError where failure.problemCode == "playback_active" {
      confirmation = Confirmation(
        title: "Someone Is Watching", message: "Turn it off anyway? Their playback stops.",
        action: PowerNowText.title(action)
      ) { Task { await powerNow(action, force: true) } }
    } catch let failure as APIClientError where failure.isManagementLocked {
      if await model.unlockManagementInteractively() { await powerNow(action, force: force) }
    } catch {
      message = error.localizedDescription
    }
  }
}
