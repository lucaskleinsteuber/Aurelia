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

  var errorDescription: String? {
    switch self {
    case .helperMissing: "The bundled Aurelia Home Server Host is missing."
    case .couldNotLaunch: "Aurelia Home Server Host could not be launched."
    case .rendezvousTimedOut: "Aurelia Home Server Host did not become ready."
    case .invalidResponse: "Aurelia Home Server Host returned an invalid response."
    case .rejected: "Aurelia Home Server Host rejected the request."
    }
  }
}

final class NativeServerHost: @unchecked Sendable {
  private let lock = NSLock()
  private var controlURL: URL?
  private var runningApplication: NSRunningApplication?
  private var rendezvousURL: URL?

  func start(serverName: String, lanPort: Int = 43_111) async throws -> NativeHostSnapshot {
    if let existing = lock.withLock({ controlURL }) {
      return try await status(at: existing)
    }

    let secret = try Self.randomSecret()
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AureliaHome/Host", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
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
    lock.withLock {
      runningApplication = application
      rendezvousURL = rendezvous
    }

    for _ in 0..<100 {
      if let data = try? Data(contentsOf: rendezvous),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let port = object["port"] as? Int,
        port > 0, port <= 65_535,
        let url = URL(string: "http://127.0.0.1:\(port)/\(secret)")
      {
        try? FileManager.default.removeItem(at: rendezvous)
        lock.withLock { controlURL = url }
        for _ in 0..<60 {
          if let snapshot = try? await status(at: url) { return snapshot }
          try await Task.sleep(for: .milliseconds(100))
        }
        throw NativeServerHostError.rendezvousTimedOut
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    application.terminate()
    throw NativeServerHostError.rendezvousTimedOut
  }

  func status() async throws -> NativeHostSnapshot {
    guard let url = lock.withLock({ controlURL }) else {
      return .stopped
    }
    return try await status(at: url)
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

  func stop() async {
    _ = try? await request(action: "shutdown", method: "POST")
    for _ in 0..<100 {
      if lock.withLock({ runningApplication?.isTerminated ?? true }) { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    let cleanup = lock.withLock { () -> URL? in
      let result = rendezvousURL
      controlURL = nil
      runningApplication = nil
      rendezvousURL = nil
      return result
    }
    if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
  }

  private func status(at url: URL) async throws -> NativeHostSnapshot {
    let data = try await request(baseURL: url, action: "status", method: "GET")
    do { return try JSONDecoder().decode(NativeHostSnapshot.self, from: data) }
    catch { throw NativeServerHostError.invalidResponse }
  }

  private func request(action: String, method: String, body: Data? = nil) async throws -> Data {
    guard let url = lock.withLock({ controlURL }) else {
      throw NativeServerHostError.invalidResponse
    }
    return try await request(baseURL: url, action: action, method: method, body: body)
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
    if let override = ProcessInfo.processInfo.environment["AURELIA_HOME_HELPER_PATH"] {
      return URL(fileURLWithPath: override)
    }
    let url = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/Aurelia Home Server Host.app")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw NativeServerHostError.helperMissing
    }
    return url
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
      dataDirectory: environment["AURELIA_HOME_DATA_DIR"],
      logDirectory: environment["AURELIA_HOME_LOG_DIR"],
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
