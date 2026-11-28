import AppKit
import SwiftUI

/// Set Up This Mac › Move from Another Tarven Server: this Mac's new server takes over an
/// existing one, over the network with its move code or from a moving file, and each storage
/// location is pointed at its folder on this Mac.
struct HostSetupMoveView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var browser = BonjourBrowser()

  private enum Method: Hashable {
    case network
    case file
  }

  @State private var method: Method = .network
  @State private var address = ""
  @State private var code = ""
  @State private var file: URL?
  @State private var passphrase = ""
  @State private var status: SetupMoveStatus?
  @State private var choices: [UUID: String] = [:]
  @State private var previews: [UUID: StorageRelocationPreview] = [:]
  @State private var working = false
  @State private var problem: String?

  var body: some View {
    TarvenSheet(
      title: "Move from Another Server",
      subtitle: subtitle,
      symbol: "shippingbox.and.arrow.backward",
      errorMessage: problem,
      primary: primary,
      cancelTitle: status?.state == "done" ? "Close" : "Cancel",
      onCancel: { cancel() }
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) { content }
          .padding(24)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .tarvenSheetFrame(minWidth: 540, idealWidth: 620, minHeight: 440, idealHeight: 600)
    .onAppear { browser.start() }
    .onDisappear { browser.stop() }
    .task { await poll() }
    .onChange(of: model.hostSnapshot.state) { _, state in
      // The moved server restarted as this Mac's server: sign in like on a welcome back.
      if status?.state == "done", state == .running { dismiss() }
    }
  }

  private var stage: String {
    switch status?.state {
    case "fetching": "fetching"
    case "received": "mapping"
    case "applying", "done": "finishing"
    default: "start"
    }
  }

  private var subtitle: String {
    switch stage {
    case "fetching": "Taking over the data from “\(status?.source?.name ?? "the old server")”…"
    case "mapping": "Point each storage location at its folder on this Mac."
    case "finishing": "Tarven restarts the server as the moved one."
    default: "Take over an existing Tarven server, with everything on it."
    }
  }

  private var primary: TarvenSheetAction? {
    switch stage {
    case "start":
      return TarvenSheetAction(
        title: method == .network ? "Connect" : "Open Moving File", busyTitle: "Connecting…",
        isBusy: working, isDisabled: !canStart, action: { Task { await start() } })
    case "mapping":
      return TarvenSheetAction(
        title: "Finish Move", busyTitle: "Finishing…", isBusy: working,
        action: { Task { await finish() } })
    default:
      return nil
    }
  }

  private var canStart: Bool {
    switch method {
    case .network:
      !address.trimmingCharacters(in: .whitespaces).isEmpty
        && code.filter { $0.isLetter || $0.isNumber }.count >= 12
    case .file: file != nil && passphrase.count >= 12
    }
  }

  @ViewBuilder private var content: some View {
    switch stage {
    case "fetching":
      if let fraction = status?.progress?.fraction {
        ProgressView(value: fraction)
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      Text("This can take a few minutes for a large library. Keep both computers on.")
        .foregroundStyle(.secondary)
    case "mapping":
      mapping
    case "finishing":
      HStack(spacing: 10) {
        TarvenDelayedProgress(controlSize: .small)
        Text("Restarting the server…")
      }
      Text(
        "Then sign in with the old server's owner name and its Server Password. Your other devices find this Mac by themselves."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    default:
      startForm
    }
  }

  @ViewBuilder private var startForm: some View {
    Text(
      "On the old server, open Settings › Server › Move to a New Server first. This Mac then takes over its name, identity, profiles and sign-ins. Media files are not copied."
    )
    .fixedSize(horizontal: false, vertical: true)
    Picker("How", selection: $method) {
      Text("Over the Network").tag(Method.network)
      Text("Moving File").tag(Method.file)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    switch method {
    case .network:
      if !browser.servers.isEmpty {
        Text("Found nearby").font(.headline)
        ForEach(browser.servers) { server in
          Button {
            address = server.baseURL.absoluteString
          } label: {
            HStack {
              Image(
                systemName: address == server.baseURL.absoluteString
                  ? "largecircle.fill.circle" : "circle")
              Text(server.name)
              Spacer(minLength: 0)
              Text(server.baseURL.host ?? "").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      TextField("Old server's address, for example minipc.local", text: $address)
        .textFieldStyle(.roundedBorder)
      TextField("Move code, for example ABCD-EFGH-JKMN", text: $code)
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())
        .onSubmit { if canStart { Task { await start() } } }
    case .file:
      HStack {
        Text(file?.lastPathComponent ?? "No file chosen")
          .foregroundStyle(file == nil ? .secondary : .primary)
          .lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("Choose…") { chooseFile() }
      }
      SecureField("Passphrase of the moving file", text: $passphrase)
        .textFieldStyle(.roundedBorder)
        .onSubmit { if canStart { Task { await start() } } }
    }
  }

  @ViewBuilder private var mapping: some View {
    if let source = status?.source {
      Label("Data from “\(source.name)” is here.", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    }
    let locations = status?.locations ?? []
    if locations.isEmpty {
      Text("The old server had no storage locations.").foregroundStyle(.secondary)
    }
    ForEach(locations) { location in
      VStack(alignment: .leading, spacing: 8) {
        Text(location.name).font(.headline)
        Text("Was: \(location.oldPath)").font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
        ForEach(location.suggestions.prefix(3)) { suggestion in
          Button {
            choices[location.id] = suggestion.path
            previews[location.id] = StorageRelocationPreview(
              sampled: location.sampled, matched: suggestion.matched)
          } label: {
            HStack {
              Image(
                systemName: choices[location.id] == suggestion.path
                  ? "largecircle.fill.circle" : "circle")
              VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.path).lineLimit(1).truncationMode(.middle)
                Text(ServerMoveText.match(suggestion.matched, of: location.sampled))
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        HStack {
          TextField(
            "Folder on this Mac",
            text: Binding(
              get: { choices[location.id] ?? "" },
              set: {
                choices[location.id] = $0
                previews[location.id] = nil
              })
          )
          .textFieldStyle(.roundedBorder)
          Button("Choose…") { chooseFolder(for: location) }
          Button("Later") {
            choices[location.id] = nil
            previews[location.id] = nil
          }
          .help("Keep it offline for now and use Storage Location Moved later")
        }
        if let preview = previews[location.id] {
          Text(ServerMoveText.match(preview.matched, of: preview.sampled))
            .font(.caption)
            .foregroundStyle(preview.matched > 0 ? Color.secondary : Color.orange)
        } else if (choices[location.id] ?? "").isEmpty {
          Text("Later: its titles stay, offline, until you point it at its folder.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(12)
      .background(
        .white.opacity(0.04), in: RoundedRectangle(cornerRadius: TarvenDesign.compactRadius))
    }
  }

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK { file = panel.url }
  }

  private func chooseFolder(for location: SetupMoveStatus.Location) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    choices[location.id] = url.path
    Task {
      guard let client = try? await model.localSetupMoveClient() else { return }
      previews[location.id] = try? await client.preview(locationId: location.id, path: url.path)
    }
  }

  private func start() async {
    working = true
    defer { working = false }
    do {
      let client = try await model.localSetupMoveClient()
      switch method {
      case .network:
        status = try await client.startNetwork(
          address: SetupMovePlan.normalizedAddress(address), code: code)
      case .file:
        guard let file else { return }
        status = try await client.openFile(file, passphrase: passphrase)
        passphrase = ""
      }
      problem = nil
      adoptSuggestions()
    } catch {
      problem = error.localizedDescription
    }
  }

  private func finish() async {
    let locations = status?.locations ?? []
    working = true
    defer { working = false }
    do {
      let client = try await model.localSetupMoveClient()
      status = try await client.finish(SetupMovePlan.mappings(for: locations, choices: choices))
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }

  private func cancel() {
    if status?.state == "received" || status?.state == "failed" {
      Task {
        try? await model.localSetupMoveClient().discard()
        dismiss()
      }
    } else {
      dismiss()
    }
  }

  private func adoptSuggestions() {
    guard let locations = status?.locations, choices.isEmpty else { return }
    choices = SetupMovePlan.initialChoices(for: locations)
    for location in locations {
      if let path = choices[location.id],
        let match = location.suggestions.first(where: { $0.path == path })
      {
        previews[location.id] = StorageRelocationPreview(
          sampled: location.sampled, matched: match.matched)
      }
    }
  }

  /// While data arrives, the status moves on by itself; a failure shows its reason.
  private func poll() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      guard status?.isWorking == true,
        let client = try? await model.localSetupMoveClient(),
        let current = try? await client.status()
      else { continue }
      status = current
      if current.state == "failed" {
        problem = SetupMovePlan.failureText(nil, message: current.error)
        status = nil
      }
      adoptSuggestions()
    }
  }
}
