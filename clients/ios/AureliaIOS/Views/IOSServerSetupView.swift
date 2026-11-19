import SwiftUI
import UniformTypeIdentifiers

/// A server without an owner, set up from this iPhone or iPad with the setup code from the server
/// computer (setup-code-v1): a new owner with the Server Password and a viewing PIN, or the whole
/// server moved here from another computer (docs/SERVER_MOVE.md).
struct IOSServerSetupView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var moving = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if dynamicTypeSize.isAccessibilitySize {
            Picker("Set Up", selection: $moving) {
              Text("New Server").tag(false)
              Text("Move from Another Server").tag(true)
            }
            .pickerStyle(.menu)
            .disabled(model.setupSignedIn != nil)
          } else {
            Picker("Set Up", selection: $moving) {
              Text("New Server").tag(false)
              Text("Move Server").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(model.setupSignedIn != nil)
          }
        } header: {
          Text(model.inspected?.info.name ?? "Aurelia Server")
        } footer: {
          Text(
            "This server has no owner yet. Its setup code is on the server computer: run sudo aurelia setup --browser (Docker: docker compose exec aurelia aurelia setup-code)."
          )
        }
        if moving {
          IOSSetupMoveForm()
        } else {
          IOSNewServerForm()
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle("Set Up Server")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Back") { model.cancelPairing() }.disabled(model.isBusy)
        }
      }
    }
    .tint(.blue)
  }
}

private struct IOSNewServerForm: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var code = ""
  @State private var ownerName = ""
  @State private var password = ""
  @State private var again = ""
  @State private var pin = ""
  @FocusState private var pinFocused: Bool

  private var problem: String? {
    IOSServerMoveText.setupProblem(
      code: code, ownerName: ownerName, password: password, repeat: again, pin: pin)
  }

  var body: some View {
    Section {
      TextField("Setup Code", text: $code, prompt: Text("ABCDE-FGHJK"))
        .textInputAutocapitalization(.characters).autocorrectionDisabled()
        .font(.body.monospaced())
        .accessibilityIdentifier("setup-code")
        .disabled(model.setupSignedIn != nil)
    } header: {
      Text("Setup Code")
    }
    Section {
      TextField("Owner Name", text: $ownerName)
        .textContentType(.username).autocorrectionDisabled()
        .accessibilityIdentifier("setup-owner")
      SecureField("Server Password", text: $password).textContentType(.newPassword)
        .accessibilityIdentifier("setup-password")
      SecureField("Repeat Server Password", text: $again).textContentType(.newPassword)
        .accessibilityIdentifier("setup-password-again")
    } header: {
      Text("Owner")
    } footer: {
      Text(
        "The owner manages the server. The Server Password, at least 12 characters, confirms important changes; keep it somewhere safe."
      )
    }
    Section {
      SecureField("Viewing PIN", text: $pin).keyboardType(.numberPad)
        .focused($pinFocused)
        .onChange(of: pin) { _, value in
          let digits = String(value.filter(\.isNumber).prefix(8))
          if digits != value { pin = digits }
        }
        .accessibilityIdentifier("setup-pin")
    } header: {
      Text("Viewing PIN")
    } footer: {
      Text("4 to 8 digits. It opens the owner's profile for watching on every device.")
    }
    Section {
      Button {
        pinFocused = false
        model.setUpServer(code: code, ownerName: ownerName, password: password, pin: pin)
      } label: {
        HStack {
          Text(model.setupSignedIn == nil ? "Set Up Server" : "Save PIN and Continue")
          if model.isBusy {
            Spacer()
            ProgressView().tint(.black).accessibilityLabel("Setting up server")
          }
        }
      }
      .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
      .listRowBackground(Color.clear)
      .disabled(problem != nil || model.isBusy)
      .accessibilityIdentifier("setup-submit")
    } footer: {
      if let error = model.error {
        Text(error).foregroundStyle(.orange)
      } else if let problem, !code.isEmpty || !ownerName.isEmpty || !password.isEmpty {
        Text(problem)
      } else {
        Text("Storage locations are added next, in Settings › Library.")
      }
    }
    .iosNumberPadDone { pinFocused = false }
  }
}

/// Moving a whole server here: the setup code, then the old server's move code and address or its
/// moving file and passphrase, then where the storage locations are on this computer.
private struct IOSSetupMoveForm: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var setupCode = ""
  @State private var withFile = false
  @State private var address = ""
  @State private var moveCode = ""
  @State private var passphrase = ""
  @State private var file: URL?
  @State private var importing = false
  @State private var status: IOSSetupMoveStatus?
  @State private var paths: [UUID: String] = [:]
  @State private var previews: [UUID: IOSMoveLocationMatch] = [:]
  @State private var busy = false
  @State private var error: String?
  @State private var finished = false

  private var code: String? { IOSServerMoveText.setupCode(setupCode) }

  var body: some View {
    if finished {
      Section {
        Label("The server is moving.", systemImage: "checkmark.circle.fill")
        Text(
          "It restarts with the old server's titles, profiles and settings. Devices that used the old server follow it by themselves; connect this one again when it is back."
        )
        .foregroundStyle(.secondary)
        Button("Done") { model.finishedMoveIntoServer() }
      }
    } else if let status, status.state == "received" {
      locations(status)
    } else {
      start
    }
  }

  @ViewBuilder private var start: some View {
    Section("Setup Code") {
      TextField("Setup Code, such as ABCDE-FGHJK", text: $setupCode)
        .textInputAutocapitalization(.characters).autocorrectionDisabled()
        .font(.body.monospaced())
    }
    Section {
      Picker("From", selection: $withFile) {
        Text("Move Code").tag(false)
        Text("Moving File").tag(true)
      }
      .pickerStyle(.segmented)
      if withFile {
        Button(file?.lastPathComponent ?? "Choose Moving File…", systemImage: "doc") {
          importing = true
        }
        SecureField("Passphrase", text: $passphrase)
      } else {
        TextField("Old Server's Address, such as 192.168.1.20", text: $address)
          .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        TextField("Move Code", text: $moveCode)
          .textInputAutocapitalization(.characters).autocorrectionDisabled()
      }
      Button {
        Task { await begin() }
      } label: {
        HStack {
          Text("Start Moving")
          if busy {
            Spacer()
            ProgressView()
          }
        }
      }
      .disabled(
        busy || code == nil
          || (withFile ? file == nil || passphrase.isEmpty : address.isEmpty || moveCode.isEmpty))
    } header: {
      Text("Old Server")
    } footer: {
      if let error {
        Text(error).foregroundStyle(.orange)
      } else if let status, status.state == "receiving" {
        Text(receivingText(status.progress))
      } else {
        Text(
          "On the old server, choose Settings › Server › Move to a New Server…. It shows a move code, or saves a moving file with a passphrase. Media files are not copied."
        )
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url):
        file = url
        error = nil
      case .failure(let failure):
        error = failure.localizedDescription
      }
    }
  }

  @ViewBuilder private func locations(_ status: IOSSetupMoveStatus) -> some View {
    Section {
      Text("From \(status.source?.name ?? "the old server")")
    } footer: {
      Text(
        "Where are the storage locations' files on this computer? Choose a suggestion or type the folder; Later keeps a location to point at its folder afterwards."
      )
    }
    ForEach(status.locations) { location in
      Section(location.name) {
        Text("Was \(location.oldPath)").font(.footnote).foregroundStyle(.secondary)
        ForEach(location.suggestions) { suggestion in
          let selected = paths[location.id] == suggestion.path
          Button {
            paths[location.id] = suggestion.path
            previews[location.id] = IOSMoveLocationMatch(
              sampled: location.sampled, matched: suggestion.matched)
          } label: {
            HStack {
              VStack(alignment: .leading) {
                Text(suggestion.path).font(.footnote.monospaced())
                Text(IOSRelocateDecision.matchText(suggestion.matched, of: location.sampled))
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
          }
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
        TextField(
          "Folder on This Computer",
          text: Binding(
            get: { paths[location.id] ?? "" },
            set: {
              paths[location.id] = $0
              previews[location.id] = nil
            })
        )
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        if dynamicTypeSize.isAccessibilitySize {
          Button("Check Folder") { Task { await preview(location) } }
            .disabled((paths[location.id] ?? "").isEmpty || busy)
          Button("Later") {
            paths[location.id] = nil
            previews[location.id] = nil
          }
        } else {
          HStack {
            Button("Check Folder") { Task { await preview(location) } }
              .buttonStyle(.borderless)
              .frame(minHeight: 44)
              .disabled((paths[location.id] ?? "").isEmpty || busy)
            Spacer()
            Button("Later") {
              paths[location.id] = nil
              previews[location.id] = nil
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
          }
        }
        if let match = previews[location.id] {
          Text(IOSRelocateDecision.matchText(match.matched, of: match.sampled)).font(.footnote)
        }
      }
    }
    Section {
      Button {
        Task { await finish(status) }
      } label: {
        HStack {
          Text("Finish Move")
          if busy {
            Spacer()
            ProgressView()
          }
        }
      }
      .disabled(busy)
      Button("Start Over", role: .destructive) { Task { await discard() } }
    } footer: {
      if let error { Text(error).foregroundStyle(.orange) }
    }
  }

  private func receivingText(_ progress: IOSSetupMoveProgress?) -> String {
    guard let progress else { return "Receiving the old server's data…" }
    let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
    if let expected = progress.expected, expected > 0 {
      return
        "Receiving… \(received) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
    }
    return "Receiving… \(received)"
  }

  private func begin() async {
    guard let api = model.inspectedClient(), let code else { return }
    busy = true
    defer { busy = false }
    error = nil
    do {
      if withFile, let file {
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        status = try await api.setupMoveFile(file, passphrase: passphrase, setupCode: code)
      } else {
        status = try await api.setupMoveNetwork(
          address: address.trimmingCharacters(in: .whitespaces),
          code: moveCode.trimmingCharacters(in: .whitespaces), setupCode: code)
      }
      await follow(api: api, code: code)
    } catch {
      self.error = IOSServerMoveText.message(error)
    }
  }

  /// The old server's data arrives in the background; this waits until it is there.
  private func follow(api: IOSAPIClient, code: String) async {
    while let current = status, current.state == "receiving", !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      status = try? await api.setupMoveStatus(setupCode: code)
    }
    if status?.state == "failed" { error = status?.error ?? "The move stopped. Start it again." }
    for location in status?.locations ?? [] where paths[location.id] == nil {
      if let best = location.suggestions.max(by: { $0.matched < $1.matched }), best.matched > 0 {
        paths[location.id] = best.path
        previews[location.id] = IOSMoveLocationMatch(
          sampled: location.sampled, matched: best.matched)
      }
    }
  }

  private func preview(_ location: IOSSetupMoveLocation) async {
    guard let api = model.inspectedClient(), let code, let path = paths[location.id] else { return }
    busy = true
    defer { busy = false }
    do {
      previews[location.id] = try await api.setupMovePreview(
        location: location.id, path: path, setupCode: code)
      error = nil
    } catch {
      self.error = IOSServerMoveText.message(error)
    }
  }

  private func finish(_ status: IOSSetupMoveStatus) async {
    guard let api = model.inspectedClient(), let code else { return }
    busy = true
    defer { busy = false }
    let mappings = status.locations.map { location in
      IOSMovePathMapping(
        id: location.id,
        path: paths[location.id].flatMap {
          $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        })
    }
    do {
      try await api.finishSetupMove(mappings, setupCode: code)
      finished = true
    } catch {
      self.error = IOSServerMoveText.message(error)
    }
  }

  private func discard() async {
    guard let api = model.inspectedClient(), let code else { return }
    try? await api.discardSetupMove(setupCode: code)
    status = nil
    paths = [:]
    previews = [:]
  }
}
