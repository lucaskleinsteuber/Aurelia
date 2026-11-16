import AppKit
import SwiftUI

/// Settings › Server › Move to a New Server: the old server hands its data, identity and sign-ins
/// to a new computer, over the network with a move code or with an encrypted moving file.
struct ServerMoveSection: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var status: ServerMoveStatusResponse?
  @State private var unsupported = false
  @State private var showingSheet = false
  @State private var working = false
  @State private var problem: String?

  var body: some View {
    if !unsupported {
      AureliaSettingsSection(
        "Move to a New Server", symbol: "shippingbox.and.arrow.backward",
        description:
          "Moves everything to another computer: titles, progress, profiles, settings and every device's sign-in. Media files are not copied; on the new computer you point each storage location at its folder."
      ) {
        VStack(alignment: .leading, spacing: 12) {
          content
          if let problem {
            ErrorBanner(message: problem, retry: { Task { await load() } }, inline: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .task { await load() }
      .sheet(
        isPresented: $showingSheet, onDismiss: { Task { await load() } },
        content: { ServerMoveSheet(client: client, resuming: status?.isWaiting == true) })
    }
  }

  @ViewBuilder private var content: some View {
    if let status, status.isMoved {
      Text(ServerMoveText.movedSummary(status))
        .fixedSize(horizontal: false, vertical: true)
      Button("Undo Move…", role: .destructive) { undo() }
        .disabled(working)
    } else if let status, status.isWaiting {
      Text(
        status.method == "file"
          ? "A moving file was made. Set up the new server with it."
          : "A move code is waiting for the new server."
      )
      HStack {
        Button(status.method == "file" ? "Show Moving File Steps…" : "Show Move Code…") {
          showingSheet = true
        }
        Button("Cancel Move") { Task { await perform { try await $0.cancelServerMove() } } }
          .disabled(working)
      }
    } else if status != nil {
      Button("Move to a New Server…") { showingSheet = true }
        .buttonStyle(AureliaPrimaryActionButtonStyle(compact: true))
        .accessibilityIdentifier("server-move-start")
    } else {
      AureliaDelayedProgress(controlSize: .small)
    }
  }

  private func load() async {
    do {
      status = try await client.serverMoveStatus()
      problem = nil
    } catch let failure as APIClientError where failure.httpStatus == 404 {
      // Servers before 2.18 can't move; the section stays away instead of showing an error.
      unsupported = true
    } catch {
      problem = "Couldn't load the move state. \(error.localizedDescription)"
    }
  }

  private func undo() {
    guard
      AureliaConfirm.ask(
        "Undo the Move?",
        "This server takes over again. Turn the new server off first: two copies of the same server must never run at once.",
        action: "Undo Move")
    else { return }
    Task { await perform { try await $0.cancelServerMove() } }
  }

  private func perform(_ work: @escaping @Sendable (APIClient) async throws -> Void) async {
    working = true
    defer { working = false }
    do {
      try await work(client)
      problem = nil
    } catch let failure as APIClientError where failure.isManagementLocked {
      guard await model.unlockManagementInteractively() else { return }
      await perform(work)
      return
    } catch {
      problem = error.localizedDescription
    }
    await load()
  }
}

/// Choosing how to move, then the move code with its countdown or the moving file.
struct ServerMoveSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let client: APIClient
  let resuming: Bool

  private enum Step: Equatable {
    case choose
    case network
    case file
  }

  @State private var step: Step = .choose
  @State private var code: String?
  @State private var expiry: Date?
  @State private var status: ServerMoveStatusResponse?
  @State private var passphrase = ""
  @State private var repeated = ""
  @State private var savedFile: URL?
  @State private var working = false
  @State private var problem: String?

  var body: some View {
    AureliaSheet(
      title: "Move to a New Server",
      subtitle: subtitle,
      symbol: "shippingbox.and.arrow.backward",
      errorMessage: problem,
      primary: primary,
      cancelTitle: step == .choose ? "Cancel" : "Close",
      onCancel: { dismiss() },
      leading: { leading }
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          switch step {
          case .choose: chooser
          case .network: networkStep
          case .file: fileStep
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: 580, height: 520)
    .task(id: step) { await pollWhileWaiting() }
    .task {
      // Reopened while a code waits: show it again instead of starting over.
      if resuming, let current = try? await client.serverMoveStatus(), current.isWaiting {
        step = current.method == "file" ? .file : .network
        status = current
        expiry = current.expiresAt.flatMap(ISO8601DateFormatter.flexibleDate)
      }
    }
  }

  private var subtitle: String {
    switch step {
    case .choose: "Take this server to another computer, with everything on it."
    case .network: "Enter this code on the new server while both are switched on."
    case .file: "Carry an encrypted file to the new server, for example on a USB stick."
    }
  }

  private var primary: AureliaSheetAction? {
    switch step {
    case .choose: return nil
    case .network:
      guard code == nil || isExpired else { return nil }
      return AureliaSheetAction(
        title: code == nil ? "Show Move Code" : "New Code", busyTitle: "Starting…",
        isBusy: working, action: { Task { await startNetwork() } })
    case .file:
      guard savedFile == nil else { return nil }
      return AureliaSheetAction(
        title: "Save Moving File…", busyTitle: "Saving…", isBusy: working,
        isDisabled: !passphraseIsValid, action: { Task { await saveFile() } })
    }
  }

  @ViewBuilder private var leading: some View {
    if step != .choose, status?.isMoved != true {
      Button("Cancel Move", role: .destructive) {
        Task {
          await run { try await $0.cancelServerMove() }
          dismiss()
        }
      }
      .disabled(working || (code == nil && savedFile == nil && status?.isWaiting != true))
    }
  }

  private var chooser: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "On the new computer, set up Aurelia and choose Move from another Aurelia server. It takes over this server's name, identity and sign-ins, so your devices keep working. This server then steps aside."
      )
      .fixedSize(horizontal: false, vertical: true)
      choice(
        "Over the Network", symbol: "wifi",
        detail: "Both computers are on, in the same home network. The new one asks for a code.",
        to: .network)
      choice(
        "With a Moving File", symbol: "doc.zipper",
        detail:
          "An encrypted file with a passphrase you choose, for when the computers can't reach each other.",
        to: .file)
    }
  }

  private func choice(_ title: String, symbol: String, detail: String, to target: Step)
    -> some View
  {
    Button {
      step = target
      if target == .network { Task { await startNetwork() } }
    } label: {
      HStack(spacing: 14) {
        Image(systemName: symbol).font(.title2).frame(width: 36)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.headline)
          Text(detail).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").foregroundStyle(.secondary)
      }
      .padding(14)
      .contentShape(Rectangle())
      .background(
        .white.opacity(0.05), in: RoundedRectangle(cornerRadius: AureliaDesign.compactRadius))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("server-move-\(target == .network ? "network" : "file")")
  }

  @ViewBuilder private var networkStep: some View {
    if status?.isMoved == true, let status {
      movedNotice(status)
    } else if let code, !isExpired {
      Text("Move code").font(.callout).foregroundStyle(.secondary)
      Text(ServerMoveText.grouped(code))
        .font(.system(size: 40, weight: .semibold, design: .monospaced))
        .textSelection(.enabled)
        .accessibilityLabel("Move code \(code.map { String($0) }.joined(separator: " "))")
      if let expiry {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(ServerMoveText.remaining(until: expiry, now: context.date) ?? "The code ran out")
            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
      }
      Text(
        status?.state == "transferring"
          ? "The new server is taking over the data…"
          : "Keep this window open or close it: the code stays valid until it runs out. The code works once."
      )
      .font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } else if code != nil {
      Text("The code ran out. Make a new one when the new server is ready.")
    } else if working {
      AureliaDelayedProgress(controlSize: .small)
    }
  }

  @ViewBuilder private var fileStep: some View {
    if status?.isMoved == true, let status {
      movedNotice(status)
    } else if let savedFile {
      Text("Moving file saved: \(savedFile.lastPathComponent)").font(.headline)
      Text(
        "On the new computer, choose Move from another Aurelia server, then this file and its passphrase. When the new server runs and this one still answers, use Mark as Moved."
      )
      .fixedSize(horizontal: false, vertical: true)
      Button("Mark as Moved…") { markMoved() }.disabled(working)
    } else {
      Text(
        "The file holds the whole server: its database, settings, identity, sign-ins and your own images. Anyone with the file and the passphrase could run your server, so choose a strong passphrase and delete the file after the move."
      )
      .font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      SecureField("Passphrase (at least 12 characters)", text: $passphrase)
      SecureField("Repeat Passphrase", text: $repeated)
      if !repeated.isEmpty, passphrase != repeated {
        Text("The passphrases don't match.").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func movedNotice(_ status: ServerMoveStatusResponse) -> some View {
    Label {
      Text(ServerMoveText.movedSummary(status)).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    }
  }

  private var passphraseIsValid: Bool { passphrase.count >= 12 && passphrase == repeated }

  private var isExpired: Bool {
    guard let expiry else { return false }
    return expiry <= Date()
  }

  private func startNetwork() async {
    working = true
    defer { working = false }
    guard let started = await run({ try await $0.startNetworkServerMove() }) else { return }
    code = started.code
    expiry = started.expiresAt.flatMap(ISO8601DateFormatter.flexibleDate)
  }

  private func saveFile() async {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Aurelia-Server.aureliamove"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let file = panel.url else { return }
    working = true
    defer { working = false }
    let phrase = passphrase
    guard
      await run({ try await $0.exportServerMovingFile(passphrase: phrase, to: file) }) != nil
    else { return }
    passphrase = ""
    repeated = ""
    savedFile = file
  }

  private func markMoved() {
    guard
      AureliaConfirm.ask(
        "Mark This Server as Moved?",
        "Do this only when the new server runs. This server stops offering itself and sends devices to the new one; Undo Move brings it back.",
        action: "Mark as Moved")
    else { return }
    Task {
      _ = await run { try await $0.markServerMoved() }
      status = try? await client.serverMoveStatus()
    }
  }

  /// While a code or file waits, the sheet notices when the new server took over.
  private func pollWhileWaiting() async {
    guard step != .choose else { return }
    while !Task.isCancelled {
      if code != nil || savedFile != nil || status?.isWaiting == true,
        let current = try? await client.serverMoveStatus()
      {
        status = current
        if current.isMoved { return }
      }
      try? await Task.sleep(for: .seconds(2))
    }
  }

  @discardableResult
  private func run<T: Sendable>(_ work: @escaping @Sendable (APIClient) async throws -> T) async
    -> T?
  {
    do {
      let value = try await work(client)
      problem = nil
      return value
    } catch let failure as APIClientError where failure.isManagementLocked {
      guard await model.unlockManagementInteractively() else { return nil }
      return await run(work)
    } catch {
      problem = error.localizedDescription
      return nil
    }
  }
}

/// Storage Location Moved: the files of a storage location now live in another folder (a new
/// disk, or a new computer after a move). Aurelia points the location there; nothing is copied.
struct StorageLocationMovedSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let library: LibrarySummary

  @State private var suggestions: StorageRelocationSuggestions?
  @State private var path = ""
  @State private var preview: StorageRelocationPreview?
  @State private var previewedPath: String?
  @State private var loading = true
  @State private var working = false
  @State private var problem: String?

  var body: some View {
    AureliaSheet(
      title: "Storage Location Moved",
      subtitle: "Point “\(library.name)” at the folder where its files are now.",
      symbol: "externaldrive.badge.checkmark",
      errorMessage: problem,
      primary: AureliaSheetAction(
        title: "Move Storage Location", busyTitle: "Moving…", isBusy: working,
        isDisabled: preview == nil || previewedPath != trimmedPath,
        action: { Task { await relocate() } }),
      onCancel: { dismiss() }
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          LabeledContent("Old folder") {
            Text(library.path).textSelection(.enabled).lineLimit(2)
          }
          suggestionList
          Text("New folder").font(.headline)
          HStack {
            TextField("/path/to/the/folder", text: $path)
              .textFieldStyle(.roundedBorder)
              .onSubmit { Task { await runPreview() } }
            if model.isLocalHost {
              Button("Choose…") { choose() }
            }
            Button("Check") { Task { await runPreview() } }
              .disabled(trimmedPath.isEmpty || working)
          }
          if let preview, previewedPath == trimmedPath {
            Label(
              ServerMoveText.match(preview.matched, of: preview.sampled),
              systemImage: preview.matched > 0
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(preview.matched > 0 ? .primary : Color.orange)
          }
          Text(
            "Titles, progress and favorites stay with this storage location. Aurelia then scans the new folder; the files themselves are only read."
          )
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: 600, height: 540)
    .task { await loadSuggestions() }
  }

  @ViewBuilder private var suggestionList: some View {
    if loading {
      HStack(spacing: 8) {
        AureliaDelayedProgress(controlSize: .small)
        Text("Looking for the files…").foregroundStyle(.secondary)
      }
    } else if let suggestions, !suggestions.suggestions.isEmpty {
      Text("Found on the server").font(.headline)
      ForEach(suggestions.suggestions.prefix(5)) { suggestion in
        Button {
          path = suggestion.path
          preview = StorageRelocationPreview(
            sampled: suggestions.sampled, matched: suggestion.matched)
          previewedPath = suggestion.path
        } label: {
          HStack {
            Image(systemName: path == suggestion.path ? "largecircle.fill.circle" : "circle")
            VStack(alignment: .leading, spacing: 2) {
              Text(suggestion.path).lineLimit(1).truncationMode(.middle)
              Text(ServerMoveText.match(suggestion.matched, of: suggestions.sampled))
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    } else if suggestions != nil {
      Text("No folder with these files was found on the server. Type the new folder below.")
        .foregroundStyle(.secondary)
    }
  }

  private var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    path = url.path
    Task { await runPreview() }
  }

  private func loadSuggestions() async {
    guard let client = model.profileClient() else { return }
    loading = true
    defer { loading = false }
    do {
      let found = try await client.storageRelocationSuggestions(libraryId: library.id)
      suggestions = found
      if path.isEmpty, let best = found.suggestions.first, best.matched > 0 {
        path = best.path
        preview = StorageRelocationPreview(sampled: found.sampled, matched: best.matched)
        previewedPath = best.path
      }
    } catch {
      suggestions = StorageRelocationSuggestions(sampled: 0, suggestions: [])
      problem = "Couldn't search for the files. \(error.localizedDescription)"
    }
  }

  private func runPreview() async {
    guard let client = model.profileClient(), !trimmedPath.isEmpty else { return }
    let checked = trimmedPath
    working = true
    defer { working = false }
    do {
      preview = try await client.previewStorageRelocation(libraryId: library.id, path: checked)
      previewedPath = checked
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }

  private func relocate() async {
    guard let client = model.profileClient(), let preview else { return }
    var force = false
    if preview.matched == 0 {
      guard
        AureliaConfirm.ask(
          "None of the Files Are There",
          "Aurelia found none of this storage location's sample files in that folder. Its titles stay offline until their files appear. Move it anyway?",
          action: "Move Anyway")
      else { return }
      force = true
    }
    working = true
    defer { working = false }
    do {
      try await client.relocateStorage(libraryId: library.id, path: trimmedPath, force: force)
      await model.refreshFromUI()
      dismiss()
    } catch let failure as APIClientError where failure.isManagementLocked {
      guard await model.unlockManagementInteractively() else { return }
      await relocate()
    } catch {
      problem = error.localizedDescription
    }
  }
}
