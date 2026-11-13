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
      unlockError =
        (error as? IOSCoreError)?.code == "invalid_credentials"
        ? "The Server Password is incorrect." : Self.message(error)
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
      .onAppear { focused = true }
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

/// The Settings tab: a list on iPhone, and on iPad the Mac's layout with the categories in a
/// sidebar and the chosen one beside it.
struct IOSSettingsTab: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.horizontalSizeClass) private var sizeClass
  @StateObject private var admin = IOSAdministrationModel()

  var body: some View {
    Group {
      if sizeClass == .regular {
        NavigationSplitView {
          IOSConnectionMenu()
        } detail: {
          ContentUnavailableView(
            "Settings", systemImage: "gearshape",
            description: Text("Choose a category on the left."))
        }
        .navigationSplitViewStyle(.balanced)
      } else {
        NavigationStack { IOSConnectionMenu() }
      }
    }
    .environmentObject(admin)
    .onAppear { admin.attach(model) }
    .onChange(of: model.session?.sessionId) { _, _ in admin.attach(model) }
    .sheet(isPresented: $admin.unlockRequested, onDismiss: { admin.cancelUnlock() }) {
      IOSManagementUnlockSheet(admin: admin, serverName: model.connection?.name ?? "Aurelia")
    }
    .alert(
      "Server Administration",
      isPresented: Binding(get: { admin.alert != nil }, set: { if !$0 { admin.alert = nil } })
    ) {
      Button("OK") { admin.alert = nil }
    } message: {
      Text(admin.alert ?? "")
    }
    .overlay(alignment: .bottom) {
      if let activity = admin.activity {
        HStack(spacing: 10) {
          ProgressView()
          Text(activity).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
      }
    }
    .animation(.easeOut(duration: 0.2), value: admin.activity)
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
