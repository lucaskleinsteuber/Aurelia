import SwiftUI

/// Server administration on the Apple TV: who may manage what, unlocking management for ten
/// minutes (Confirm on Another Device, or the Server Password with the TV keyboard), and one
/// place for errors. A locked request asks once and is sent again; nothing is stored.
@MainActor
final class TVAdministrationModel: ObservableObject {
  @Published var unlockRequested = false
  @Published var alert: String?
  @Published private(set) var managementExpiresAt: Date?
  /// Counts finished changes, so open pages reload what changed.
  @Published private(set) var revision = 0

  private weak var app: TVAppModel?
  private var waiters: [CheckedContinuation<Bool, Never>] = []

  /// The pages read `permissions` while they are drawn, before `onAppear` attaches the app, so
  /// attaching asks them to draw again; before, an owner's own rows (Power, Updates…) stayed hidden.
  func attach(_ app: TVAppModel) {
    guard self.app !== app else { return }
    self.app = app
    objectWillChange.send()
  }

  var client: TVAPIClient? { app?.client }
  var permissions: TVAdminPermissions {
    TVAdminPermissions(role: app?.session?.user.role, accessMode: app?.session?.user.accessMode)
  }

  /// Runs a request; a locked server asks to unlock once and the request is sent again. Throws
  /// `CancellationError` when unlocking was cancelled.
  func run<Value: Sendable>(_ work: @Sendable (TVAPIClient) async throws -> Value) async throws
    -> Value
  {
    guard let client else { throw TVCoreError.profileRequired }
    do {
      do {
        return try await work(client)
      } catch let failure as TVCoreError where failure.isManagementLocked {
        managementExpiresAt = nil
        guard await requestUnlock(), let fresh = self.client else { throw CancellationError() }
        return try await work(fresh)
      }
    } catch let failure as TVCoreError where failure.endsSession {
      app?.handleSessionFailure(failure)
      throw failure
    }
  }

  /// A change whose errors appear in the alert; returns whether it worked.
  @discardableResult
  func perform(_ work: @Sendable (TVAPIClient) async throws -> Void) async -> Bool {
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

  /// A value the page needs; nil when it failed, with the error in the alert.
  func value<Value: Sendable>(_ work: @Sendable (TVAPIClient) async throws -> Value) async
    -> Value?
  {
    do {
      return try await run(work)
    } catch is CancellationError {
      return nil
    } catch {
      alert = Self.message(error)
      return nil
    }
  }

  static func message(_ error: Error) -> String {
    if let failure = error as? TVCoreError {
      if failure.code == "passkey_required" {
        return
          "This server asks for Face ID or Touch ID. Use Confirm on Another Device and confirm on an iPhone, iPad or Mac."
      }
      return failure.serverMessage ?? failure.localizedDescription
    }
    if error is URLError { return "The server isn’t answering. Check that it’s on and try again." }
    return (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Try again."
  }

  private func requestUnlock() async -> Bool {
    unlockRequested = true
    return await withCheckedContinuation { waiters.append($0) }
  }

  /// Management is unlocked until `expires`; waiting requests go on.
  func unlocked(until expires: Date?) {
    managementExpiresAt = expires
    unlockRequested = false
    resume(true)
  }

  func cancelUnlock() {
    unlockRequested = false
    resume(false)
  }

  private func resume(_ value: Bool) {
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume(returning: value) }
  }
}

/// Unlocking management on the TV: confirm on an iPhone, iPad or Mac with Face ID or Touch ID, or
/// type the Server Password with the TV keyboard or the iPhone's remote.
struct TVManagementUnlockView: View {
  @ObservedObject var admin: TVAdministrationModel
  let serverName: String
  @State private var request: TVRemoteUnlockStart?
  @State private var status: TVRemoteUnlockStatus?
  @State private var usingPassword = false
  @State private var password = ""
  @State private var working = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 36) {
      Image(systemName: "lock.shield").font(.system(size: 90)).foregroundStyle(.secondary)
      Text("Unlock Management").font(.system(size: 52, weight: .bold))
      Text("Changes to \(serverName) need a confirmation. It lasts ten minutes.")
        .font(.system(size: 26)).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if let request, !usingPassword {
        VStack(spacing: 14) {
          Text(request.code).font(.system(size: 110, weight: .bold, design: .monospaced))
            .accessibilityIdentifier("unlock-code")
          Text(status?.text ?? TVRemoteUnlockStatus.waitingText)
            .font(.system(size: 26)).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Text("On the iPhone, iPad or Mac, check that it shows this code.")
            .font(.system(size: 22)).foregroundStyle(.tertiary)
        }
      } else if usingPassword {
        SecureField("Server Password", text: $password)
          .frame(width: 760).accessibilityIdentifier("unlock-password")
          .onSubmit { Task { await unlockWithPassword() } }
      }
      if let error { TVErrorText(message: error) }
      HStack(spacing: 30) {
        if usingPassword {
          Button("Unlock") { Task { await unlockWithPassword() } }
            .disabled(password.isEmpty || working)
          Button("Confirm on Another Device") {
            usingPassword = false
            Task { await askAnotherDevice() }
          }
        } else {
          Button("Use Server Password") {
            usingPassword = true
            error = nil
          }
          .accessibilityIdentifier("unlock-use-password")
          if status?.isFinished == true, status?.unlocked != true {
            Button("Ask Again") { Task { await askAnotherDevice() } }
          }
        }
        Button("Cancel", role: .cancel) { admin.cancelUnlock() }
      }
      .buttonStyle(TVButtonStyle())
    }
    .padding(80)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TVDesign.canvas.ignoresSafeArea())
    .task { await askAnotherDevice() }
    .task(id: request?.id) { await follow() }
    .onExitCommand { admin.cancelUnlock() }
  }

  private func askAnotherDevice() async {
    guard let client = admin.client else { return }
    error = nil
    status = nil
    do {
      request = try await client.requestRemoteUnlock()
    } catch {
      self.error = TVAdministrationModel.message(error)
      usingPassword = true
    }
  }

  /// Asks the server every two seconds until the other device decided or the request expired.
  private func follow() async {
    guard let id = request?.id else { return }
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard let client = admin.client, request?.id == id else { return }
      guard let current = try? await client.remoteUnlockStatus(id: id) else { continue }
      status = current
      if current.unlocked {
        admin.unlocked(until: current.managementExpiresAt.flatMap(TVServerDate.parse))
        return
      }
      if current.isFinished { return }
    }
  }

  private func unlockWithPassword() async {
    guard let client = admin.client, !working else { return }
    working = true
    defer {
      working = false
      password = ""
    }
    do {
      let expires = try await client.unlockManagement(password: password)
      admin.unlocked(until: expires)
    } catch {
      self.error = TVAdministrationModel.message(error)
    }
  }
}

extension TVRemoteUnlockStatus {
  static let waitingText =
    "Waiting for confirmation on an iPhone, iPad or Mac with Face ID or Touch ID…"
}

/// A settings page for the remote: a large symbol, title and explanation on the left, rows on the
/// right, as Playback Settings.
struct TVSettingsPage<Content: View>: View {
  let symbol: String
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  var body: some View {
    HStack(alignment: .top, spacing: 90) {
      VStack(spacing: 26) {
        Image(systemName: symbol).font(.system(size: 130))
          .symbolRenderingMode(.hierarchical).foregroundStyle(.white.opacity(0.85))
        Text(title).font(.system(size: 46, weight: .bold)).multilineTextAlignment(.center)
        Text(subtitle).font(.system(size: 24)).foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(width: 520).padding(.top, 120)
      ScrollView {
        VStack(spacing: 14) { content }
          .padding(.vertical, 30).padding(.horizontal, 20)
      }
      .frame(maxWidth: .infinity).focusSection()
    }
    .padding(.horizontal, TVDesign.pagePadding).padding(.top, 20)
    .background(TVDesign.canvas.ignoresSafeArea())
  }
}

/// One row: Select toggles it or moves to the next value; without an action it only shows.
struct TVSettingsRow: View {
  let title: String
  var value: String? = nil
  var id: String = ""
  var role: ButtonRole? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    Button(role: role) {
      action?()
    } label: {
      HStack(spacing: 20) {
        Text(title).multilineTextAlignment(.leading)
        Spacer(minLength: 20)
        if let value {
          Text(value).opacity(0.7).monospacedDigit().multilineTextAlignment(.trailing)
        }
      }
      .padding(.horizontal, 30).frame(maxWidth: .infinity, minHeight: 72)
    }
    .buttonStyle(TVButtonStyle(kind: .row))
    .accessibilityIdentifier(id)
    .accessibilityValue(value ?? "")
  }

  static func next<Value: Equatable>(after current: Value, in values: [Value]) -> Value {
    guard let index = values.firstIndex(of: current) else { return values[0] }
    return values[(index + 1) % values.count]
  }
}

/// A small heading between groups of rows.
struct TVSettingsHeader: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 24, weight: .semibold)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 22).padding(.horizontal, 10)
  }
}

/// An explanation under a group of rows.
struct TVSettingsNote: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 22)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
  }
}

/// Shows the unlock screen and the alert of an administration model on a page.
struct TVAdministrationPresentation: ViewModifier {
  @EnvironmentObject private var model: TVAppModel
  @ObservedObject var admin: TVAdministrationModel

  func body(content: Content) -> some View {
    content
      .onAppear { admin.attach(model) }
      .fullScreenCover(isPresented: $admin.unlockRequested) {
        TVManagementUnlockView(admin: admin, serverName: model.connection?.name ?? "Tarven")
      }
      .alert(
        "Server",
        isPresented: Binding(get: { admin.alert != nil }, set: { if !$0 { admin.alert = nil } })
      ) {
        Button("OK") { admin.alert = nil }
      } message: {
        Text(admin.alert ?? "")
      }
  }
}

extension View {
  func tvAdministration(_ admin: TVAdministrationModel) -> some View {
    modifier(TVAdministrationPresentation(admin: admin))
  }
}
