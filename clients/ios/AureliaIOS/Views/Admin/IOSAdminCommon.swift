import SwiftUI

/// Settings › Server Administration on iPhone and iPad: who may manage what, the ten-minute
/// management unlock with the Server Password, and one place that shows progress and errors.
/// A locked request asks for the password once and is sent again; nothing is stored.
@MainActor
final class IOSAdministrationModel: ObservableObject {
  @Published private(set) var managementExpiresAt: Date?
  @Published var unlockRequested = false
  @Published private(set) var unlocking = false
  @Published var unlockError: String?
  /// What runs now, such as "Scanning Films…", shown as a small banner.
  @Published private(set) var activity: String?
  @Published var alert: String?
  /// Counts finished changes, so open screens reload what changed.
  @Published private(set) var revision = 0

  private weak var app: IOSAppModel?
  private var unlockWaiters: [CheckedContinuation<Bool, Never>] = []
  private var profileID: UUID?
  private var expiryTask: Task<Void, Never>?

  func attach(_ app: IOSAppModel) {
    self.app = app
    let current = app.session?.user.id
    if current != profileID {
      profileID = current
      managementExpiresAt = nil
      expiryTask?.cancel()
    }
  }

  var client: IOSAPIClient? { app?.client }
  var permissions: IOSAdminPermissions {
    IOSAdminPermissions(role: app?.session?.user.role, accessMode: app?.session?.user.accessMode)
  }
  var isUnlocked: Bool { (managementExpiresAt ?? .distantPast) > Date() }

  /// Runs a request; a locked server asks for the Server Password once and the request is sent
  /// again. Throws `CancellationError` when the password prompt was cancelled.
  func run<Value: Sendable>(_ work: @Sendable (IOSAPIClient) async throws -> Value) async throws
    -> Value
  {
    guard let client else { throw IOSCoreError.profileRequired }
    do {
      return try await work(client)
    } catch let failure as IOSCoreError where failure.isManagementLocked {
      managementExpiresAt = nil
      guard await requestUnlock(), let fresh = self.client else { throw CancellationError() }
      return try await work(fresh)
    } catch let failure as IOSCoreError where failure.endsSession {
      app?.handleSessionFailure(failure)
      throw failure
    }
  }

  /// A change with progress and errors handled here; returns whether it worked.
  @discardableResult
  func perform(_ activity: String? = nil, _ work: @Sendable (IOSAPIClient) async throws -> Void)
    async -> Bool
  {
    self.activity = activity
    defer { self.activity = nil }
    do {
      try await run(work)
      revision += 1
      return true
    } catch is CancellationError {
      return false
    } catch {
      alert = Self.message(error)
      return false
    }
  }

  /// A change whose progress and errors the caller shows itself, such as a button that reports
  /// right in its row. Open screens reload when it worked.
  func runChange(_ work: @Sendable (IOSAPIClient) async throws -> Void) async throws {
    try await run(work)
    revision += 1
  }

  /// Like `perform`, for a request whose answer the screen needs; nil when it failed.
  func value<Value: Sendable>(
    _ activity: String? = nil, _ work: @Sendable (IOSAPIClient) async throws -> Value
  ) async -> Value? {
    self.activity = activity
    defer { self.activity = nil }
    do {
      let value = try await run(work)
      revision += 1
      return value
    } catch is CancellationError {
      return nil
    } catch {
      alert = Self.message(error)
      return nil
    }
  }

  static func message(_ error: Error) -> String {
    if let failure = error as? IOSCoreError { return failure.localizedDescription }
    if let failure = error as? LocalizedError, let text = failure.errorDescription { return text }
    if error is URLError { return "The server isn’t answering. Check that it’s on and try again." }
    return "Something went wrong. Try again."
  }

  private func requestUnlock() async -> Bool {
    unlockError = nil
    unlockRequested = true
    return await withCheckedContinuation { unlockWaiters.append($0) }
  }

  /// Unlocks with the typed password; the field is cleared by the sheet either way.
  func unlock(password: String) async {
    guard let client, !unlocking else { return }
    unlocking = true
    defer { unlocking = false }
    do {
      let expiry = try await client.unlockManagement(password: password)
      managementExpiresAt = expiry
      scheduleExpiry(expiry)
      unlockRequested = false
      finishUnlock(true)
    } catch {
      switch (error as? IOSCoreError)?.code {
      case "invalid_credentials": unlockError = "The Server Password is incorrect."
      case "passkey_required":
        unlockError =
          "This server asks for Face ID or Touch ID instead of the Server Password. Set it up on this \(IOSDesign.deviceName) from the server computer, or unlock there."
      default: unlockError = Self.message(error)
      }
    }
  }

  /// This profile's Face ID / Touch ID key on this device, if it has one.
  var storedPasskey: IOSStoredPasskey? {
    guard IOSSecureEnclaveSigner.isAvailable, let server = app?.connection?.serverID,
      let profile = app?.session?.user.id
    else { return nil }
    return IOSPasskeyStore.load(server: server, profile: profile)
  }

  /// Unlocks with Face ID or Touch ID instead of the Server Password.
  func unlockWithPasskey() async {
    guard let client, let passkey = storedPasskey, !unlocking else { return }
    unlocking = true
    defer { unlocking = false }
    do {
      let expiry = try await client.unlockManagement(passkeyId: passkey.passkeyId, signer: passkey.signer)
      managementExpiresAt = expiry
      scheduleExpiry(expiry)
      unlockRequested = false
      finishUnlock(true)
    } catch {
      if (error as? IOSCoreError)?.code == "passkey_invalid", let server = app?.connection?.serverID,
        let profile = app?.session?.user.id
      {
        // The server no longer knows this key (removed elsewhere): forget it here too.
        IOSPasskeyStore.remove(server: server, profile: profile)
        unlockError = "This \(IOSDesign.deviceName)'s key was removed on the server. Use the Server Password and set it up again."
      } else if (error as? CancellationError) == nil {
        unlockError = Self.message(error)
      }
    }
  }

  func cancelUnlock() {
    unlockRequested = false
    finishUnlock(false)
  }

  /// Locks management again before the ten minutes are over.
  func lock() async {
    expiryTask?.cancel()
    managementExpiresAt = nil
    _ = try? await client?.lockManagement()
  }

  private func finishUnlock(_ success: Bool) {
    let waiters = unlockWaiters
    unlockWaiters.removeAll()
    for waiter in waiters { waiter.resume(returning: success) }
  }

  private func scheduleExpiry(_ date: Date) {
    expiryTask?.cancel()
    expiryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
      guard !Task.isCancelled else { return }
      self?.managementExpiresAt = nil
    }
  }
}

/// The Server Password sheet. The password lives only in this sheet and is sent once.
struct IOSManagementUnlockSheet: View {
  @ObservedObject var admin: IOSAdministrationModel
  let serverName: String
  @State private var password = ""
  @FocusState private var focused: Bool

  var body: some View {
    NavigationStack {
      Form {
        if admin.storedPasskey != nil {
          Section {
            Button {
              Task { await admin.unlockWithPasskey() }
            } label: {
              Label("Unlock with \(IOSSecureEnclaveSigner.biometryName)", systemImage: "faceid")
            }
            .disabled(admin.unlocking)
            .accessibilityIdentifier("admin-unlock-passkey")
          }
        }
        Section {
          SecureField("Server Password", text: $password)
            .textContentType(.password)
            .focused($focused)
            .submitLabel(.go)
            .onSubmit(submit)
            .accessibilityIdentifier("admin-unlock-password")
        } header: {
          Text("Unlock Server Management")
        } footer: {
          VStack(alignment: .leading, spacing: 6) {
            Text(
              "Enter the Server Password for “\(serverName)” to manage it for ten minutes. Your Profile PIN can’t unlock management, and the password isn’t stored on this \(IOSDesign.deviceName)."
            )
            if let error = admin.unlockError { Text(error).foregroundStyle(.orange) }
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle("Server Password")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { admin.cancelUnlock() }
        }
        ToolbarItem(placement: .confirmationAction) {
          if admin.unlocking {
            ProgressView()
          } else {
            Button("Unlock", action: submit).disabled(password.isEmpty)
              .accessibilityIdentifier("admin-unlock")
          }
        }
      }
      .onAppear {
        if admin.storedPasskey != nil {
          Task { await admin.unlockWithPasskey() }
        } else {
          focused = true
        }
      }
      .onDisappear { password = "" }
    }
    .presentationDetents([.medium])
    .interactiveDismissDisabled(admin.unlocking)
  }

  private func submit() {
    guard !password.isEmpty else { return }
    let typed = password
    Task {
      await admin.unlock(password: typed)
      if admin.managementExpiresAt != nil { password = "" }
    }
  }
}

/// Loads one screen's data with the administration model and shows waiting and errors the same
/// way everywhere. Pull to refresh reloads it; a finished change elsewhere reloads it too.
struct IOSAdminLoader<Value: Sendable, Content: View>: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let load: @Sendable (IOSAPIClient) async throws -> Value
  @ViewBuilder let content: (Value, _ reload: @escaping () async -> Void) -> Content
  @State private var value: Value?
  @State private var error: String?
  @State private var locked = false

  var body: some View {
    Group {
      if let value {
        content(value, reload)
      } else if locked {
        ContentUnavailableView {
          Label("Management Is Locked", systemImage: "lock")
        } description: {
          Text("Unlock server management with the Server Password to see this.")
        } actions: {
          Button("Unlock…") { Task { await reload() } }.buttonStyle(.borderedProminent)
        }
      } else if let error {
        ContentUnavailableView {
          Label("Couldn’t Load", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("Try Again") { Task { await reload() } }
        }
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task { await reload() }
    .onChange(of: admin.revision) { _, _ in Task { await reload() } }
  }

  private func reload() async {
    do {
      value = try await admin.run(load)
      error = nil
      locked = false
    } catch is CancellationError {
      if value == nil { locked = true }
    } catch {
      if value == nil { self.error = IOSAdministrationModel.message(error) }
    }
  }
}

/// A form screen with the app's dark canvas, as every settings page.
struct IOSAdminForm<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    Form { content() }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
  }
}

/// A confirmation with a destructive button, described in one sentence.
struct IOSAdminConfirmation: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let action: String
  let perform: () -> Void
}

extension View {
  func adminConfirmation(_ item: Binding<IOSAdminConfirmation?>) -> some View {
    alert(
      item.wrappedValue?.title ?? "", isPresented: Binding(
        get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
      presenting: item.wrappedValue
    ) { confirmation in
      Button(confirmation.action, role: .destructive) { confirmation.perform() }
      Button("Cancel", role: .cancel) {}
    } message: { confirmation in
      Text(confirmation.message)
    }
  }
}

enum IOSAdminFormat {
  static func date(_ text: String?) -> String {
    guard let text, let date = IOSServerDate.parse(text) else { return "—" }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
  static func relative(_ text: String?) -> String {
    guard let text, let date = IOSServerDate.parse(text) else { return "—" }
    return date.formatted(.relative(presentation: .named))
  }
}

/// The first lines of a settings page: its icon, its name and one sentence about what it does,
/// as on the Mac. Placed as the form's first section.
struct IOSAdminPageHeader: View {
  let systemImage: String
  let title: String
  let text: String
  var tint: Color = .indigo

  init(systemImage: String, title: String, text: String, tint: Color = .indigo) {
    self.systemImage = systemImage
    self.title = title
    self.text = text
    self.tint = tint
  }

  init(page: IOSSettingsPage, text: String) {
    self.init(
      systemImage: page.systemImage, title: page.title, text: text,
      tint: IOSSettingsRowLabel.tint(page.group))
  }

  var body: some View {
    Section {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: systemImage)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.headline)
          Text(text).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.vertical, 4)
      .accessibilityElement(children: .combine)
    }
  }
}

/// A switch's label with a line that says what it does.
struct IOSAdminToggleLabel: View {
  let title: String
  let detail: String

  init(_ title: String, _ detail: String) {
    self.title = title
    self.detail = detail
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      // A fixed gray, so the line stays gray inside a tinted button too.
      Text(detail).font(.caption).foregroundStyle(Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A button for a server action that shows its own progress, then "Done" or the problem right
/// in its row, so you see what happened where you tapped.
struct IOSAdminActionButton: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let title: String
  let systemImage: String
  var detail: String?
  var role: ButtonRole?
  var doneText = "Done"
  let work: @Sendable (IOSAPIClient) async throws -> Void
  @State private var state: Phase = .idle

  enum Phase: Equatable { case idle, running, done, failed(String) }

  init(
    _ title: String, systemImage: String, detail: String? = nil, role: ButtonRole? = nil,
    doneText: String = "Done", work: @escaping @Sendable (IOSAPIClient) async throws -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.detail = detail
    self.role = role
    self.doneText = doneText
    self.work = work
  }

  var body: some View {
    Button(role: role) {
      Task { await run() }
    } label: {
      HStack(alignment: .center, spacing: 10) {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if case .failed(let message) = state {
              Text(message).font(.caption).foregroundStyle(.orange)
            } else if let detail {
              Text(detail).font(.caption).foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        } icon: {
          Image(systemName: systemImage)
        }
        Spacer(minLength: 8)
        switch state {
        case .running: ProgressView()
        case .done:
          Label(doneText, systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold)).foregroundStyle(.green)
        default: EmptyView()
        }
      }
    }
    .disabled(state == .running)
    .animation(.easeOut(duration: 0.2), value: state)
  }

  private func run() async {
    state = .running
    do {
      try await admin.runChange(work)
      state = .done
      try? await Task.sleep(for: .seconds(3))
      if state == .done { state = .idle }
    } catch is CancellationError {
      state = .idle
    } catch {
      state = .failed(IOSAdministrationModel.message(error))
    }
  }
}

/// A section that could not load, while the rest of the page still works.
struct IOSAdminSectionProblem: View {
  let message: String
  let retry: () async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Couldn’t load this part", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
      Text(message).font(.caption).foregroundStyle(.secondary)
      Button("Try Again") { Task { await retry() } }.buttonStyle(.borderless)
    }
  }
}
