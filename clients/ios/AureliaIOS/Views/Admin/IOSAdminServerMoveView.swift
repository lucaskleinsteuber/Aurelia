import SwiftUI

/// Settings › Server › Move to a New Server, for the owner: a move code the new server types, or
/// an encrypted moving file with a passphrase. Titles, progress, profiles, settings and every
/// device's sign-in come along; media files are not copied (docs/SERVER_MOVE.md).
struct IOSAdminServerMoveView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var status: IOSServerMoveStatus?
  @State private var started: IOSServerMoveStarted?
  @State private var withFile = false
  @State private var passphrase = ""
  @State private var again = ""
  @State private var movingFile: URL?
  @State private var busy = false
  @State private var error: String?
  @State private var confirmMoved = false

  var body: some View {
    Form {
      if let status, status.state == "moved" {
        Section {
          Label(
            "Moved to \(status.movedTo?.name ?? "the new server")",
            systemImage: "checkmark.circle.fill")
          Text(
            "Devices that connect here are sent to the new server. This server stays as it was, so the move can be undone."
          )
          .foregroundStyle(.secondary)
          Button("Undo the Move", role: .destructive) { Task { await cancel() } }
        }
      } else if let started, started.method == "network", let code = started.code {
        Section {
          Text(code).font(.system(.largeTitle, design: .monospaced, weight: .semibold))
            .frame(maxWidth: .infinity).textSelection(.enabled)
            .accessibilityLabel(code.map(String.init).joined(separator: " "))
            .accessibilityIdentifier("move-code")
          if let expires = started.expiresAt.flatMap(IOSServerDate.parse) {
            Text("Valid until \(expires.formatted(date: .omitted, time: .shortened)).")
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Move Code")
        } footer: {
          Text(
            "On the new computer, set up the server and choose Move from Another Server. Type this code and this server's address there. This page updates when the move is done."
          )
        }
        waitingActions
      } else if let status, status.state == "waiting" {
        Section {
          Text(
            status.method == "file"
              ? "A moving file is out. Open it on the new server with its passphrase."
              : "A move code is out. Its code was shown when the move started.")
        }
        if let movingFile {
          Section {
            ShareLink(item: movingFile) {
              Label("Save Moving File…", systemImage: "square.and.arrow.up")
            }
          }
        }
        waitingActions
      } else {
        startForm
      }
      if let error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Move to a New Server")
    .navigationBarTitleDisplayMode(.inline)
    .disabled(busy)
    .task { await refresh() }
    .task(id: started?.code) { await follow() }
    .confirmationDialog(
      "Mark this server as moved?", isPresented: $confirmMoved, titleVisibility: .visible
    ) {
      Button("Mark as Moved", role: .destructive) { Task { await markMoved() } }
    } message: {
      Text(
        "Do this once the new server runs with the moving file. Devices that connect here are then sent there."
      )
    }
  }

  @ViewBuilder private var startForm: some View {
    Section {
      let methodPicker = Picker("How", selection: $withFile) {
        Text("Over the Network").tag(false)
        Text("With a Moving File").tag(true)
      }
      if dynamicTypeSize >= .xLarge || sizeClass == .compact {
        methodPicker.pickerStyle(.menu)
      } else {
        methodPicker.pickerStyle(.segmented)
      }
      if withFile {
        SecureField("Passphrase", text: $passphrase).textContentType(.newPassword)
        SecureField("Repeat Passphrase", text: $again).textContentType(.newPassword)
      }
      Button {
        Task { await start() }
      } label: {
        HStack {
          Text(withFile ? "Make Moving File" : "Show Move Code")
          if busy {
            Spacer()
            ProgressView()
          }
        }
      }
      .disabled(withFile && (passphrase.count < 12 || passphrase != again))
      .accessibilityIdentifier("move-start")
    } footer: {
      Text(
        withFile
          ? "The file is encrypted with the passphrase (at least 12 characters); save it, carry it to the new computer and open it there."
          : "Both computers must reach each other on the network. The new server fetches everything itself."
      )
    }
  }

  @ViewBuilder private var waitingActions: some View {
    Section {
      if status?.method == "file" || started?.method == "file" {
        Button("Mark as Moved…") { confirmMoved = true }
      }
      Button("Cancel the Move", role: .destructive) { Task { await cancel() } }
    }
  }

  private func refresh() async {
    status = try? await admin.run { try await $0.serverMoveStatus() }
  }

  private func start() async {
    busy = true
    defer { busy = false }
    error = nil
    let method = withFile ? "file" : "network"
    let secret = withFile ? passphrase : nil
    do {
      let result = try await admin.run {
        try await $0.startServerMove(method: method, passphrase: secret)
      }
      started = result
      if let transfer = result.transferId {
        let destination = FileManager.default.temporaryDirectory
          .appendingPathComponent("Aurelia-Moving-File.aurelia-move")
        try? FileManager.default.removeItem(at: destination)
        try await admin.run { try await $0.downloadMovingFile(transfer: transfer, to: destination) }
        movingFile = destination
      }
      passphrase = ""
      again = ""
      await refresh()
    } catch is CancellationError {
    } catch {
      self.error = IOSServerMoveText.message(error)
    }
  }

  /// A network move ends on its own once the new server has the data.
  private func follow() async {
    guard started?.method == "network" else { return }
    while !Task.isCancelled, status?.state != "moved" {
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      await refresh()
    }
  }

  private func markMoved() async {
    busy = true
    defer { busy = false }
    do {
      try await admin.run { try await $0.markServerMoved() }
      await refresh()
    } catch is CancellationError {
    } catch {
      self.error = IOSServerMoveText.message(error)
    }
  }

  private func cancel() async {
    busy = true
    defer { busy = false }
    do {
      try await admin.run { try await $0.cancelServerMove() }
      started = nil
      movingFile = nil
      await refresh()
    } catch is CancellationError {
    } catch {
      self.error = IOSServerMoveText.message(error)
    }
  }
}
