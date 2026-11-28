import AppKit
@preconcurrency import Foundation
import Security

enum OperatingMode: String, Codable, Sendable {
  case host
  case client
}

enum NativeHostState: String, Codable, Sendable {
  case starting
  case setupRequired
  case running
  case restarting
  case stopping
  case stopped
  case failed
  /// The server stopped itself after its unused minutes; opening Tarven starts it again.
  case idle
}

struct NativeHostSnapshot: Codable, Equatable, Sendable {
  let state: NativeHostState
  let message: String?
  let bootstrapToken: String?
  let serverInfo: ServerInfoResponse?

  static let stopped = NativeHostSnapshot(
    state: .stopped,
    message: nil,
    bootstrapToken: nil,
    serverInfo: nil)
}

struct NativeHostSettings: Codable, Equatable, Sendable {
  let version: Int
  let serverName: String
  let lanAccessEnabled: Bool
  let lanHttpsPort: Int
}

enum NativeServerHostError: LocalizedError, Equatable {
  case helperMissing
  case couldNotLaunch
  case startupFailed(String)
  case rendezvousTimedOut
  case invalidResponse
  case rejected
  case alreadyStarting
  case localServerNotReady

  var errorDescription: String? {
    switch self {
    case .helperMissing: "The bundled Tarven Server Host is missing."
    case .couldNotLaunch: "Tarven Server Host could not be launched."
    case .startupFailed(let message): message
    case .rendezvousTimedOut: "Tarven Server Host did not become ready."
    case .invalidResponse: "Tarven Server Host returned an invalid response."
    case .rejected: "Tarven Server Host rejected the request."
    case .alreadyStarting: "Tarven Server Host is already starting."
    case .localServerNotReady:
      "Tarven Server on this Mac is not running yet, so your password was not sent. Try again in a moment."
    }
  }
}

@MainActor
final class NativeServerHost {
  private struct ControlEndpoint {
    let port: Int
    let secret: String
  }

  private var controlEndpoint: ControlEndpoint?
  private var runningApplication: NSRunningApplication?
  private var rendezvousURL: URL?
  private var isStarting = false

  func start(
    serverName: String, lanPort: Int = AppEdition.defaultLanPort, skipKickstart: Bool = false
  ) async throws
    -> NativeHostSnapshot
  {
    guard !NativePreflightIsolation.isRequested || NativePreflightIsolation.isActive else {
      throw NativeServerHostError.rejected
    }
    if !NativePreflightIsolation.isActive, BackgroundHostingController.permitted,
      let settings = try? HostServiceSettings.load(),
      let directory = try? HostBootstrapLocation.directory()
    {
      HostStartupErrorRecord.clear(in: directory)
      let rendezvous = directory.appendingPathComponent(
        HostServiceSettings.backgroundRendezvousName)
      for attempt in 0..<120 {
        if (try? HostLaunchSecurity.validateConfigurationFile(
          at: rendezvous.path, bootstrapDirectory: directory)) != nil,
          let data = try? Data(contentsOf: rendezvous),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = object["port"] as? Int, (1...65535).contains(port),
          let snapshot = try? await status(port: port, secret: settings.controlSecret),
          snapshot.state != .stopped
        {
          controlEndpoint = ControlEndpoint(port: port, secret: settings.controlSecret)
          runningApplication = nil
          return snapshot
        }
        if attempt >= 15, let startupError = HostStartupErrorRecord.readRecent(from: directory) {
          throw NativeServerHostError.startupFailed(startupError.message)
        }
        if !skipKickstart && attempt == 15 {
          try? await BackgroundHostingController.startRegisteredService(forceRestart: false)
        } else if !skipKickstart && attempt == 60 {
          try? await BackgroundHostingController.startRegisteredService(forceRestart: true)
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      if let startupError = HostStartupErrorRecord.readRecent(from: directory) {
        throw NativeServerHostError.startupFailed(startupError.message)
      }
      throw NativeServerHostError.couldNotLaunch
    }
    if let controlEndpoint {
      do {
        let snapshot = try await status(port: controlEndpoint.port, secret: controlEndpoint.secret)
        // A live host may have deliberately exhausted its recovery budget.
        // Reattaching must preserve that failure until the user chooses Restart.
        if snapshot.state != .stopped { return snapshot }
        await discardCurrentHelper(requestShutdown: true)
      } catch {
        await discardCurrentHelper(requestShutdown: false)
      }
    }
    guard !isStarting else { throw NativeServerHostError.alreadyStarting }
    isStarting = true
    defer { isStarting = false }

    let secret = try Self.randomSecret()
    let cache: URL
    do { cache = try HostBootstrapLocation.directory() } catch {
      throw NativeServerHostError.couldNotLaunch
    }
    HostLaunchSecurity.pruneStaleHandoffFiles(in: cache)
    HostStartupErrorRecord.clear(in: cache)
    let rendezvous = cache.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
    let helperURL = try helperApplicationURL()
    let launchHandoff = try HostLaunchHandoff(
      secret: secret,
      directory: cache,
      rendezvous: rendezvous,
      serverName: serverName,
      lanPort: lanPort,
      environment: ProcessInfo.processInfo.environment)
    defer { launchHandoff.remove() }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = true

    let application: NSRunningApplication
    do {
      application = try await NSWorkspace.shared.openApplication(
        at: helperURL,
        configuration: configuration)
    } catch {
      throw NativeServerHostError.couldNotLaunch
    }
    runningApplication = application
    rendezvousURL = rendezvous

    do {
      for _ in 0..<100 {
        try Task.checkCancellation()
        if application.isTerminated {
          if let startupError = HostStartupErrorRecord.readRecent(from: cache) {
            throw NativeServerHostError.startupFailed(startupError.message)
          }
          throw NativeServerHostError.couldNotLaunch
        }
        if (try? HostLaunchSecurity.validateConfigurationFile(
          at: rendezvous.path,
          bootstrapDirectory: cache)) != nil,
          let data = try? Data(contentsOf: rendezvous),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = object["port"] as? Int,
          port > 0, port <= 65_535
        {
          try? FileManager.default.removeItem(at: rendezvous)
          controlEndpoint = ControlEndpoint(port: port, secret: secret)
          for _ in 0..<60 {
            try Task.checkCancellation()
            if application.isTerminated {
              if let startupError = HostStartupErrorRecord.readRecent(from: cache) {
                throw NativeServerHostError.startupFailed(startupError.message)
              }
              throw NativeServerHostError.couldNotLaunch
            }
            if let snapshot = try? await status(port: port, secret: secret) { return snapshot }
            try await Task.sleep(for: .milliseconds(100))
          }
          throw NativeServerHostError.rendezvousTimedOut
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw NativeServerHostError.rendezvousTimedOut
    } catch {
      application.forceTerminate()
      clearLaunchState()
      try? FileManager.default.removeItem(at: rendezvous)
      if error is CancellationError { throw error }
      throw error
    }
  }

  func status() async throws -> NativeHostSnapshot {
    // A vanished helper stays a failure until start() or stop() discards it.
    // Clearing it here would turn the next poll into a planned `.stopped`
    // reply that no helper sent, bypassing the UI's bounded recovery.
    if runningApplication?.isTerminated == true {
      throw NativeServerHostError.couldNotLaunch
    }
    guard let controlEndpoint else {
      return .stopped
    }
    return try await status(port: controlEndpoint.port, secret: controlEndpoint.secret)
  }

  func configure(name: String, lanPort: Int) async throws {
    let settings = NativeHostSettings(
      version: 1,
      serverName: name,
      lanAccessEnabled: true,
      lanHttpsPort: lanPort)
    let body = try JSONEncoder().encode(settings)
    _ = try await request(action: "configure", method: "POST", body: body)
  }

  func restart() async throws {
    _ = try await request(action: "restart", method: "POST")
  }
  func recoverOwnerPIN(password: String, pin: String) async throws {
    _ = try await request(
      action: "owner-pin-recovery", method: "POST",
      body: JSONEncoder().encode(["password": password, "pin": pin]))
  }
  func hostingSettingsApplied(operationID: UUID, permitted: Bool) async throws {
    _ = try await request(
      action: "hosting-applied", method: "POST",
      body: JSONEncoder().encode([
        "id": operationID.uuidString, "state": permitted ? "completed" : "awaitingPermission",
      ]))
  }
  var isBackgroundService: Bool {
    controlEndpoint != nil && runningApplication == nil && BackgroundHostingController.permitted
  }
  func handoffToBackground() async throws {
    _ = try await request(action: "handoff-background", method: "POST")
    for _ in 0..<100 {
      if runningApplication?.isTerminated == true { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard runningApplication?.isTerminated != false else { throw NativeServerHostError.rejected }
    clearLaunchState()
  }

  func stop() async {
    if controlEndpoint == nil {
      runningApplication?.forceTerminate()
      clearLaunchState()
      return
    }
    _ = try? await request(action: "shutdown", method: "POST")
    for _ in 0..<100 {
      if let application = runningApplication {
        if application.isTerminated { break }
      } else if let controlEndpoint,
        (try? await status(port: controlEndpoint.port, secret: controlEndpoint.secret)) == nil
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    if runningApplication?.isTerminated == false { runningApplication?.forceTerminate() }
    let cleanup = rendezvousURL
    clearLaunchState()
    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
  }

  func resetTestEditionServerData() async {
    guard AppEdition.isTest else { return }
    if let controlEndpoint {
      if (try? await request(action: "reset-test-data", method: "POST", timeout: 15)) != nil {
        await waitForCurrentHelperExit(controlEndpoint: controlEndpoint)
        return
      }
      await stop()
    } else if runningApplication != nil {
      await stop()
    }
    if !NativePreflightIsolation.isActive, BackgroundHostingController.permitted,
      let settings = try? HostServiceSettings.load(),
      let directory = try? HostBootstrapLocation.directory()
    {
      let rendezvous = directory.appendingPathComponent(
        HostServiceSettings.backgroundRendezvousName)
      if (try? HostLaunchSecurity.validateConfigurationFile(
        at: rendezvous.path, bootstrapDirectory: directory)) != nil,
        let data = try? Data(contentsOf: rendezvous),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let port = object["port"] as? Int, (1...65_535).contains(port),
        (try? await request(
          port: port, secret: settings.controlSecret, action: "reset-test-data", method: "POST",
          timeout: 15)) != nil
      {
        for _ in 0..<50 {
          if (try? await status(port: port, secret: settings.controlSecret)) == nil { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return
      }
    }
    guard let secret = try? Self.randomSecret(),
      let cache = try? HostBootstrapLocation.directory(),
      let helperURL = try? helperApplicationURL()
    else { return }
    HostLaunchSecurity.pruneStaleHandoffFiles(in: cache)
    let rendezvous = cache.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
    guard
      let launchHandoff = try? HostLaunchHandoff(
        secret: secret,
        directory: cache,
        rendezvous: rendezvous,
        serverName: AppEdition.displayName,
        lanPort: AppEdition.defaultLanPort,
        environment: ProcessInfo.processInfo.environment,
        resetTestData: true)
    else { return }
    defer {
      launchHandoff.remove()
      try? FileManager.default.removeItem(at: rendezvous)
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = true
    guard
      let application = try? await NSWorkspace.shared.openApplication(
        at: helperURL, configuration: configuration)
    else { return }
    defer {
      if !application.isTerminated { application.forceTerminate() }
      clearLaunchState()
    }

    for _ in 0..<50 {
      if application.isTerminated { return }
      if (try? HostLaunchSecurity.validateConfigurationFile(
        at: rendezvous.path, bootstrapDirectory: cache)) != nil,
        let data = try? Data(contentsOf: rendezvous),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let port = object["port"] as? Int, (1...65_535).contains(port)
      {
        try? FileManager.default.removeItem(at: rendezvous)
        _ = try? await request(
          port: port, secret: secret, action: "reset-test-data", method: "POST", timeout: 15)
        for _ in 0..<50 {
          if application.isTerminated { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  private func waitForCurrentHelperExit(controlEndpoint: ControlEndpoint) async {
    for _ in 0..<50 {
      if let application = runningApplication {
        if application.isTerminated { break }
      } else if (try? await status(port: controlEndpoint.port, secret: controlEndpoint.secret))
        == nil
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    if runningApplication?.isTerminated == false { runningApplication?.forceTerminate() }
    let cleanup = rendezvousURL
    clearLaunchState()
    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
  }

  private func status(port: Int, secret: String) async throws -> NativeHostSnapshot {
    let data = try await request(port: port, secret: secret, action: "status", method: "GET")
    do { return try JSONDecoder().decode(NativeHostSnapshot.self, from: data) } catch {
      throw NativeServerHostError.invalidResponse
    }
  }

  private func request(
    action: String, method: String, body: Data? = nil, timeout: TimeInterval = 3
  ) async throws -> Data {
    guard let controlEndpoint else {
      throw NativeServerHostError.invalidResponse
    }
    return try await request(
      port: controlEndpoint.port, secret: controlEndpoint.secret, action: action, method: method,
      body: body, timeout: timeout)
  }

  private func request(
    port: Int, secret: String, action: String, method: String, body: Data? = nil,
    timeout: TimeInterval = 3
  ) async throws -> Data {
    guard let url = URL(string: "http://127.0.0.1:\(port)/auth/\(action)") else {
      throw NativeServerHostError.invalidResponse
    }
    let payload = body ?? Data()
    let nonce = try HostControlAuth.makeNonce()
    let timestamp = Int64(Date().timeIntervalSince1970)
    let signature = HostControlAuth.requestSignature(
      secret: secret, method: method, action: action, nonce: nonce, timestamp: timestamp,
      body: payload)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = timeout
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    request.setValue(nonce, forHTTPHeaderField: HostControlAuth.nonceHeader)
    request.setValue(String(timestamp), forHTTPHeaderField: HostControlAuth.timestampHeader)
    request.setValue(signature, forHTTPHeaderField: HostControlAuth.signatureHeader)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw NativeServerHostError.invalidResponse
    }
    let expectedProof = HostControlAuth.responseProof(
      secret: secret, nonce: nonce, status: http.statusCode, body: data)
    guard let proof = http.value(forHTTPHeaderField: HostControlAuth.proofHeader),
      HostControlAuth.constantTimeEquals(proof, expectedProof)
    else { throw NativeServerHostError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else { throw NativeServerHostError.rejected }
    return data
  }

  nonisolated static var allowsEnvironmentOverrides: Bool {
    #if DEBUG
      return true
    #else
      return NativePreflightIsolation.isActive
    #endif
  }

  nonisolated static func resolvedHelperApplicationURL(
    bundleURL: URL = Bundle.main.bundleURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    allowEnvironmentOverrides: Bool = allowsEnvironmentOverrides
  ) throws -> URL {
    if allowEnvironmentOverrides, let override = environment["TARVEN_HELPER_PATH"] {
      return URL(fileURLWithPath: override)
    }
    let url = bundleURL.appendingPathComponent("Contents/Helpers/Tarven Server Host.app")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw NativeServerHostError.helperMissing
    }
    return url
  }

  private func helperApplicationURL() throws -> URL {
    try Self.resolvedHelperApplicationURL()
  }

  private func clearLaunchState() {
    controlEndpoint = nil
    runningApplication = nil
    rendezvousURL = nil
  }

  private func discardCurrentHelper(requestShutdown: Bool) async {
    let application = runningApplication
    if requestShutdown {
      _ = try? await request(action: "shutdown", method: "POST")
    }
    for _ in 0..<20 {
      if application?.isTerminated ?? true { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    if application?.isTerminated == false { application?.forceTerminate() }
    let cleanup = rendezvousURL
    clearLaunchState()
    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
  }

  private static func randomSecret() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw NativeServerHostError.couldNotLaunch
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

final class HostLaunchHandoff {
  let configurationURL: URL
  let secretPipeURL: URL
  private var descriptor: Int32 = -1

  init(
    secret: String,
    directory: URL,
    rendezvous: URL,
    serverName: String,
    lanPort: Int,
    environment: [String: String],
    processID: Int32 = ProcessInfo.processInfo.processIdentifier,
    allowDirectoryOverrides: Bool = NativeServerHost.allowsEnvironmentOverrides,
    resetTestData: Bool = false
  ) throws {
    configurationURL = directory.appendingPathComponent("launch-\(processID).json")
    secretPipeURL = directory.appendingPathComponent("launch-\(processID).pipe")
    unlink(secretPipeURL.path)
    try? FileManager.default.removeItem(at: configurationURL)
    guard mkfifo(secretPipeURL.path, S_IRUSR | S_IWUSR) == 0 else {
      throw NativeServerHostError.couldNotLaunch
    }
    descriptor = secretPipeURL.path.withCString { tarvenOpenPipe($0, O_RDWR | O_NONBLOCK) }
    guard descriptor >= 0 else {
      unlink(secretPipeURL.path)
      throw NativeServerHostError.couldNotLaunch
    }
    let data = Data(secret.utf8)
    let written = data.withUnsafeBytes { bytes in
      write(descriptor, bytes.baseAddress, bytes.count)
    }
    guard written == data.count else {
      close(descriptor)
      descriptor = -1
      unlink(secretPipeURL.path)
      throw NativeServerHostError.couldNotLaunch
    }
    let description = HostLaunchDescription(
      version: 1,
      parentProcessID: processID,
      rendezvousPath: rendezvous.path,
      secretPipePath: secretPipeURL.path,
      dataDirectory: allowDirectoryOverrides ? environment["TARVEN_DATA_DIR"] : nil,
      logDirectory: allowDirectoryOverrides ? environment["TARVEN_LOG_DIR"] : nil,
      serverName: serverName,
      lanPort: lanPort,
      resetTestData: resetTestData ? true : nil)
    do {
      try JSONEncoder().encode(description).write(
        to: configurationURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    } catch {
      remove()
      throw NativeServerHostError.couldNotLaunch
    }
  }

  func remove() {
    if descriptor >= 0 {
      close(descriptor)
      descriptor = -1
    }
    unlink(secretPipeURL.path)
    try? FileManager.default.removeItem(at: configurationURL)
  }

  deinit {
    remove()
  }
}
