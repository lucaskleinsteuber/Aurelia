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
  case rendezvousTimedOut
  case invalidResponse
  case rejected
  case alreadyStarting

  var errorDescription: String? {
    switch self {
    case .helperMissing: "The bundled Aurelia Server Host is missing."
    case .couldNotLaunch: "Aurelia Server Host could not be launched."
    case .rendezvousTimedOut: "Aurelia Server Host did not become ready."
    case .invalidResponse: "Aurelia Server Host returned an invalid response."
    case .rejected: "Aurelia Server Host rejected the request."
    case .alreadyStarting: "Aurelia Server Host is already starting."
    }
  }
}

@MainActor
final class NativeServerHost {
  private var controlURL: URL?
  private var runningApplication: NSRunningApplication?
  private var rendezvousURL: URL?
  private var isStarting = false

  func start(serverName: String, lanPort: Int = 43_111) async throws -> NativeHostSnapshot {
    guard !NativePreflightIsolation.isRequested || NativePreflightIsolation.isActive else {
      throw NativeServerHostError.rejected
    }
    if !NativePreflightIsolation.isActive, BackgroundHostingController.permitted,
      let settings = try? HostServiceSettings.load(),
      let directory = try? HostBootstrapLocation.directory()
    {
      let rendezvous = directory.appendingPathComponent(
        HostServiceSettings.backgroundRendezvousName)
      for attempt in 0..<80 {
        if (try? HostLaunchSecurity.validateConfigurationFile(
          at: rendezvous.path, bootstrapDirectory: directory)) != nil,
          let data = try? Data(contentsOf: rendezvous),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = object["port"] as? Int, (1...65535).contains(port),
          let url = URL(string: "http://127.0.0.1:\(port)/\(settings.controlSecret)"),
          let snapshot = try? await status(at: url),
          snapshot.state != .stopped
        {
          controlURL = url
          runningApplication = nil
          return snapshot
        }
        if attempt == 0 { try await BackgroundHostingController.startRegisteredService() }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw NativeServerHostError.couldNotLaunch
    }
    if let controlURL {
      do {
        let snapshot = try await status(at: controlURL)
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
        guard !application.isTerminated else { throw NativeServerHostError.couldNotLaunch }
        if (try? HostLaunchSecurity.validateConfigurationFile(
          at: rendezvous.path,
          bootstrapDirectory: cache)) != nil,
          let data = try? Data(contentsOf: rendezvous),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = object["port"] as? Int,
          port > 0, port <= 65_535,
          let url = URL(string: "http://127.0.0.1:\(port)/\(secret)")
        {
          try? FileManager.default.removeItem(at: rendezvous)
          controlURL = url
          for _ in 0..<60 {
            try Task.checkCancellation()
            guard !application.isTerminated else { throw NativeServerHostError.couldNotLaunch }
            if let snapshot = try? await status(at: url) { return snapshot }
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
    if runningApplication?.isTerminated == true {
      clearLaunchState()
      throw NativeServerHostError.couldNotLaunch
    }
    guard let controlURL else {
      return .stopped
    }
    return try await status(at: controlURL)
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
    controlURL != nil && runningApplication == nil && BackgroundHostingController.permitted
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
    if controlURL == nil {
      runningApplication?.forceTerminate()
      clearLaunchState()
      return
    }
    _ = try? await request(action: "shutdown", method: "POST")
    for _ in 0..<100 {
      if let application = runningApplication {
        if application.isTerminated { break }
      } else if let controlURL, (try? await status(at: controlURL)) == nil {
        break
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    if runningApplication?.isTerminated == false { runningApplication?.forceTerminate() }
    let cleanup = rendezvousURL
    clearLaunchState()
    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
  }

  private func status(at url: URL) async throws -> NativeHostSnapshot {
    let data = try await request(baseURL: url, action: "status", method: "GET")
    do { return try JSONDecoder().decode(NativeHostSnapshot.self, from: data) } catch {
      throw NativeServerHostError.invalidResponse
    }
  }

  private func request(action: String, method: String, body: Data? = nil) async throws -> Data {
    guard let controlURL else {
      throw NativeServerHostError.invalidResponse
    }
    return try await request(baseURL: controlURL, action: action, method: method, body: body)
  }

  private func request(baseURL: URL, action: String, method: String, body: Data? = nil) async throws
    -> Data
  {
    let url = baseURL.appendingPathComponent(action)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 3
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
    else { throw NativeServerHostError.rejected }
    return data
  }

  private func helperApplicationURL() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["AURELIA_HELPER_PATH"] {
      return URL(fileURLWithPath: override)
    }
    let url = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/Aurelia Server Host.app")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw NativeServerHostError.helperMissing
    }
    return url
  }

  private func clearLaunchState() {
    controlURL = nil
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
    processID: Int32 = ProcessInfo.processInfo.processIdentifier
  ) throws {
    configurationURL = directory.appendingPathComponent("launch-\(processID).json")
    secretPipeURL = directory.appendingPathComponent("launch-\(processID).pipe")
    unlink(secretPipeURL.path)
    try? FileManager.default.removeItem(at: configurationURL)
    guard mkfifo(secretPipeURL.path, S_IRUSR | S_IWUSR) == 0 else {
      throw NativeServerHostError.couldNotLaunch
    }
    descriptor = secretPipeURL.path.withCString { aureliaOpenPipe($0, O_RDWR | O_NONBLOCK) }
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
      dataDirectory: environment["AURELIA_DATA_DIR"],
      logDirectory: environment["AURELIA_LOG_DIR"],
      serverName: serverName,
      lanPort: lanPort)
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
