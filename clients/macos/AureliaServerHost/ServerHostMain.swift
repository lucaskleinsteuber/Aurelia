import AppKit
@preconcurrency import Foundation
@preconcurrency import Network
import OSLog
import Security

@main
final class ServerHostApplication: NSObject, NSApplicationDelegate {
  private static let logger = Logger(
    subsystem: "com.lucas.aurelia.media.server-host", category: "lifecycle")
  private var runtime: ServerHostRuntime?
  private var terminationAuthorized = false

  static func main() {
    let application = NSApplication.shared
    let delegate = ServerHostApplication()
    application.delegate = delegate
    application.setActivationPolicy(.prohibited)
    application.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    ProcessInfo.processInfo.disableAutomaticTermination(
      "Aurelia Server Host is managing the local server")
    ProcessInfo.processInfo.disableSuddenTermination()
    do {
      runtime = try ServerHostRuntime(
        environment: ProcessInfo.processInfo.environment,
        terminationHandler: { [weak self] in self?.finishTermination() })
      try runtime?.start()
    } catch {
      let category = (error as? HostError)?.diagnosticCategory ?? "runtime-initialization"
      Self.logger.error("Server host startup failed: \(category, privacy: .public)")
      FileHandle.standardError.write(
        Data("Aurelia Server Host could not start (\(category)).\n".utf8))
      finishTermination()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard terminationAuthorized else { return .terminateCancel }
    ProcessInfo.processInfo.enableSuddenTermination()
    ProcessInfo.processInfo.enableAutomaticTermination(
      "Aurelia Server Host completed shutdown")
    return .terminateNow
  }

  @MainActor private func finishTermination() {
    dispatchPrecondition(condition: .onQueue(.main))
    terminationAuthorized = true
    NSApplication.shared.terminate(nil)
  }
}

private enum HostState: String, Codable {
  case starting
  case setupRequired
  case running
  case restarting
  case stopping
  case stopped
  case failed
}

private struct HostServerInfo: Codable {
  let serverId: UUID
  let name: String
  let version: String
  let isSetup: Bool
  let lanAccessEnabled: Bool
  let lanHttpsPort: Int?
  let publicKeyFingerprint: String?
  let displayFingerprint: String?
}

private struct HostStatus: Codable {
  let state: HostState
  let message: String?
  let bootstrapToken: String?
  let serverInfo: HostServerInfo?
}

private struct HostSettings: Codable {
  let version: Int
  let serverName: String
  let lanAccessEnabled: Bool
  let lanHttpsPort: Int
}

private struct ResolvedHostLaunch {
  let secret: String
  let parentProcessID: Int32
  let rendezvousURL: URL
  let dataDirectory: URL
  let logDirectory: URL
  let serverName: String
  let lanPort: Int
}

private final class ServerHostRuntime: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.lucas.aurelia.media.server-host")
  private let secret: String
  private let parentProcessID: Int32
  private let rendezvousURL: URL
  private let dataDirectory: URL
  private let logDirectory: URL
  private let terminationHandler: @MainActor @Sendable () -> Void
  private var listener: NWListener?
  private var process: Process?
  private var logSink: BoundedLogSink?
  private var parentTimer: DispatchSourceTimer?
  private var status = HostStatus(
    state: .starting, message: nil, bootstrapToken: nil, serverInfo: nil)
  private var pendingRestartLAN: Bool?
  private var shuttingDown = false
  private var restartDates: [Date] = []
  private var readinessGeneration: UInt64 = 0

  init(
    environment: [String: String],
    terminationHandler: @escaping @MainActor @Sendable () -> Void
  ) throws {
    let launch = try Self.resolveLaunch(environment: environment)
    do {
      try ServerDataMigrator.migrateBuild11IfNeeded(to: launch.dataDirectory)
    } catch {
      throw HostError.dataMigration
    }
    self.secret = launch.secret
    self.parentProcessID = launch.parentProcessID
    self.rendezvousURL = launch.rendezvousURL
    self.dataDirectory = launch.dataDirectory
    self.logDirectory = launch.logDirectory
    self.terminationHandler = terminationHandler

    if !FileManager.default.fileExists(atPath: settingsURL.path) {
      do {
        try saveSettings(
          HostSettings(
            version: 1,
            serverName: launch.serverName,
            lanAccessEnabled: true,
            lanHttpsPort: launch.lanPort))
      } catch {
        throw HostError.settingsStorage
      }
    }
  }

  func start() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener: NWListener
    do { listener = try NWListener(using: parameters) } catch { throw HostError.controlListener }
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
    listener.start(queue: queue)
    startParentMonitor()
  }

  func shutdown() {
    queue.async { [weak self] in self?.beginShutdown() }
  }

  private var settingsURL: URL {
    dataDirectory.appendingPathComponent("server-settings.json")
  }

  private static func resolveLaunch(environment: [String: String]) throws -> ResolvedHostLaunch {
    let mainContents = Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let expectedExecutable = mainContents.appendingPathComponent("MacOS/Aurelia")
      .standardizedFileURL
    let bootstrapDirectory = try bootstrapDirectory(environment: environment)
    do { try HostLaunchSecurity.validateBootstrapDirectory(at: bootstrapDirectory) } catch {
      throw HostError.invalidBootstrapDirectory
    }
    var foundTrustedParent = false
    for application in NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.lucas.aurelia.media")
    {
      guard
        HostLaunchSecurity.acceptsApplication(
          processIdentifier: application.processIdentifier,
          executableURL: application.executableURL,
          isTerminated: application.isTerminated,
          expectedExecutableURL: expectedExecutable)
      else { continue }
      foundTrustedParent = true
      let configurationURL = bootstrapDirectory.appendingPathComponent(
        "launch-\(application.processIdentifier).json")
      guard FileManager.default.fileExists(atPath: configurationURL.path) else { continue }
      do {
        try HostLaunchSecurity.validateConfigurationFile(
          at: configurationURL.path,
          bootstrapDirectory: bootstrapDirectory)
      } catch {
        throw HostError.invalidLaunchDescription
      }
      guard let data = try? Data(contentsOf: configurationURL) else {
        throw HostError.invalidLaunchDescription
      }
      guard let description = try? JSONDecoder().decode(HostLaunchDescription.self, from: data)
      else { throw HostError.invalidLaunchDescription }
      let validated: ValidatedHostLaunchPaths
      do {
        validated = try HostLaunchSecurity.validate(
          description,
          expectedParentProcessID: application.processIdentifier,
          bootstrapDirectory: bootstrapDirectory)
      } catch HostLaunchSecurityError.invalidPathLocation {
        throw HostError.invalidLaunchPathLocation
      } catch {
        throw HostError.invalidLaunchDescription
      }
      defer { try? FileManager.default.removeItem(at: configurationURL) }
      let secret: String
      do { secret = try HostLaunchSecurity.readSecretPipe(at: validated.pipeURL.path) } catch {
        throw HostError.missingControlSecret
      }
      return ResolvedHostLaunch(
        secret: secret,
        parentProcessID: description.parentProcessID,
        rendezvousURL: validated.rendezvousURL,
        dataDirectory: description.dataDirectory.map(URL.init(fileURLWithPath:))
          ?? defaultDataDirectory,
        logDirectory: description.logDirectory.map(URL.init(fileURLWithPath:))
          ?? defaultLogDirectory,
        serverName: description.serverName,
        lanPort: description.lanPort)
    }
    throw foundTrustedParent ? HostError.missingLaunchConfiguration : HostError.missingTrustedParent
  }

  private static func bootstrapDirectory(environment: [String: String]) throws -> URL {
    guard let override = environment["AURELIA_HOST_BOOTSTRAP_DIR"] else {
      do { return try HostBootstrapLocation.directory() } catch {
        throw HostError.invalidBootstrapDirectory
      }
    }

    let directory = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    let resolvedDirectory = directory.resolvingSymlinksInPath()
    let smokeRoot = URL(fileURLWithPath: "/private/tmp/Aurelia", isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard resolvedDirectory.path.hasPrefix(smokeRoot.path + "/"),
      resolvedDirectory.lastPathComponent == "Host",
      FileManager.default.fileExists(atPath: resolvedDirectory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw HostError.invalidBootstrapDirectory }
    return directory
  }

  private static var defaultDataDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Aurelia Server", isDirectory: true)
  }

  private static var defaultLogDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Aurelia Server", isDirectory: true)
  }

  private func listenerChanged(_ listenerState: NWListener.State) {
    switch listenerState {
    case .ready:
      guard let port = listener?.port else {
        beginShutdown()
        return
      }
      do {
        try writeRendezvous(port: port.rawValue)
        startServer(lan: false)
      } catch {
        updateStatus(.failed, message: "The local host control channel could not be prepared.")
      }
    case .failed:
      updateStatus(.failed, message: "The local host control channel could not start.")
      beginShutdown()
    default:
      break
    }
  }

  private func startServer(lan: Bool) {
    guard !shuttingDown else { return }
    readinessGeneration &+= 1
    let generation = readinessGeneration
    do {
      let executable = try serverExecutableURL()
      let settings = try loadSettings()
      let bootstrapToken = lan ? nil : try Self.randomSecret()
      updateStatus(lan ? .restarting : .starting, bootstrapToken: bootstrapToken)

      let logSink = try BoundedLogSink(directory: logDirectory)
      self.logSink = logSink
      let child = Process()
      child.executableURL = executable
      var arguments = [
        "run", "--data-dir", dataDirectory.path,
        "--host-parent-pid", String(ProcessInfo.processInfo.processIdentifier),
      ]
      if lan {
        arguments += ["--lan", "--lan-port", String(settings.lanHttpsPort)]
      }
      child.arguments = arguments
      var environment = ProcessInfo.processInfo.environment
      environment["AURELIA_SERVER_NAME"] = settings.serverName
      environment["AURELIA_LAN_ENABLED"] = lan ? "true" : "false"
      environment["AURELIA_BOOTSTRAP_TOKEN"] = bootstrapToken
      child.environment = environment
      child.standardOutput = logSink.pipe
      child.standardError = logSink.pipe
      child.terminationHandler = { [weak self] terminated in
        guard let runtime = self else { return }
        let terminationStatus = terminated.terminationStatus
        runtime.queue.async { runtime.serverTerminated(status: terminationStatus) }
      }
      process = child
      try child.run()
      waitForServer(lan: lan, bootstrapToken: bootstrapToken, generation: generation)
    } catch {
      updateStatus(.failed, message: "The bundled Aurelia Server could not be started.")
    }
  }

  private func waitForServer(lan: Bool, bootstrapToken: String?, generation: UInt64) {
    Task { [weak self] in
      for _ in 0..<75 {
        guard let self, !self.shuttingDown else { return }
        if let info = try? await Self.readServerInfo() {
          self.queue.async {
            guard self.readinessGeneration == generation else { return }
            guard self.process?.isRunning == true else { return }
            if !lan && info.isSetup {
              self.restart(lan: true)
            } else {
              self.status = HostStatus(
                state: info.isSetup ? .running : .setupRequired,
                message: nil,
                bootstrapToken: info.isSetup ? nil : bootstrapToken,
                serverInfo: info)
            }
          }
          return
        }
        try? await Task.sleep(for: .milliseconds(200))
      }
      guard let runtime = self else { return }
      runtime.queue.async {
        guard runtime.readinessGeneration == generation else { return }
        runtime.updateStatus(.failed, message: "Aurelia Server did not become ready.")
      }
    }
  }

  private func restart(lan: Bool) {
    guard !shuttingDown else { return }
    if pendingRestartLAN != nil {
      pendingRestartLAN = lan
      return
    }
    readinessGeneration &+= 1
    pendingRestartLAN = lan
    updateStatus(.restarting)
    if let process, process.isRunning {
      process.terminate()
    } else {
      pendingRestartLAN = nil
      startServer(lan: lan)
    }
  }

  private func serverTerminated(status terminationStatus: Int32) {
    process = nil
    logSink?.close()
    logSink = nil
    if shuttingDown {
      updateStatus(.stopped)
      DispatchQueue.main.async { [terminationHandler] in terminationHandler() }
      return
    }
    if let requestedLAN = pendingRestartLAN {
      pendingRestartLAN = nil
      startServer(lan: requestedLAN)
      return
    }

    let now = Date()
    restartDates = restartDates.filter { now.timeIntervalSince($0) < 60 }
    guard restartDates.count < 3 else {
      updateStatus(
        .failed,
        message: "Aurelia Server stopped repeatedly (exit \(terminationStatus)).")
      return
    }
    restartDates.append(now)
    updateStatus(.restarting, message: "Aurelia Server stopped unexpectedly. Restarting…")
    queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startServer(lan: false) }
  }

  private func beginShutdown() {
    guard !shuttingDown else { return }
    shuttingDown = true
    readinessGeneration &+= 1
    updateStatus(.stopping)
    parentTimer?.cancel()
    parentTimer = nil
    listener?.cancel()
    listener = nil
    try? FileManager.default.removeItem(at: rendezvousURL)
    guard let process, process.isRunning else {
      updateStatus(.stopped)
      DispatchQueue.main.async { [terminationHandler] in terminationHandler() }
      return
    }
    let processIdentifier = process.processIdentifier
    process.terminate()
    queue.asyncAfter(deadline: .now() + 10) { [weak process] in
      if process?.isRunning == true {
        kill(processIdentifier, SIGKILL)
      }
    }
  }

  private func startParentMonitor() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      if kill(self.parentProcessID, 0) != 0 && errno == ESRCH {
        self.beginShutdown()
      }
    }
    timer.resume()
    parentTimer = timer
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(connection, accumulated: Data())
  }

  private func receive(_ connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      var received = accumulated
      if let data { received.append(data) }
      if error != nil || received.count > 65_536 {
        self.respond(connection, status: 400, body: Data())
        return
      }
      if let request = HostRequest.parse(received), request.isComplete {
        self.handle(request, on: connection)
      } else if complete {
        self.respond(connection, status: 400, body: Data())
      } else {
        self.receive(connection, accumulated: received)
      }
    }
  }

  private func handle(_ request: HostRequest, on connection: NWConnection) {
    guard request.secret == secret else {
      respond(connection, status: 404, body: Data())
      return
    }
    switch (request.method, request.action) {
    case ("GET", "status"):
      let body = (try? JSONEncoder().encode(status)) ?? Data()
      respond(connection, status: 200, body: body)
    case ("POST", "restart"):
      restart(lan: true)
      respond(connection, status: 202, body: Data())
    case ("POST", "configure"):
      do {
        let settings = try JSONDecoder().decode(HostSettings.self, from: request.body)
        try saveSettings(settings)
        respond(connection, status: 204, body: Data())
      } catch {
        respond(connection, status: 400, body: Data())
      }
    case ("POST", "shutdown"):
      respond(connection, status: 202, body: Data())
      queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.beginShutdown() }
    default:
      respond(connection, status: 404, body: Data())
    }
  }

  private func respond(_ connection: NWConnection, status: Int, body: Data) {
    let reason =
      status == 200
      ? "OK"
      : status == 204
        ? "No Content" : status == 202 ? "Accepted" : status == 404 ? "Not Found" : "Bad Request"
    var response = Data(
      "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        .utf8)
    response.append(body)
    connection.send(
      content: response,
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  private func updateStatus(
    _ state: HostState,
    message: String? = nil,
    bootstrapToken: String? = nil
  ) {
    status = HostStatus(
      state: state,
      message: message,
      bootstrapToken: bootstrapToken,
      serverInfo: status.serverInfo)
  }

  private func loadSettings() throws -> HostSettings {
    try JSONDecoder().decode(HostSettings.self, from: Data(contentsOf: settingsURL))
  }

  private func saveSettings(_ settings: HostSettings) throws {
    let name = settings.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard settings.version == 1, !name.isEmpty, name.count <= 128,
      settings.lanHttpsPort >= 1_024, settings.lanHttpsPort <= 65_535
    else { throw HostError.invalidSettings }
    try FileManager.default.createDirectory(
      at: dataDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let canonical = HostSettings(
      version: 1,
      serverName: name,
      lanAccessEnabled: true,
      lanHttpsPort: settings.lanHttpsPort)
    let data = try JSONEncoder().encode(canonical)
    try data.write(to: settingsURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
  }

  private func writeRendezvous(port: UInt16) throws {
    let data = try JSONSerialization.data(withJSONObject: ["port": Int(port)])
    try data.write(to: rendezvousURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: rendezvousURL.path)
  }

  private func serverExecutableURL() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["AURELIA_SERVER_EXECUTABLE"] {
      return URL(fileURLWithPath: override)
    }
    #if arch(arm64)
      let runtime = "osx-arm64"
    #else
      let runtime = "osx-x64"
    #endif
    let mainContents = Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let url =
      mainContents
      .appendingPathComponent("Resources/Server/\(runtime)/Aurelia.Server")
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      FileManager.default.isExecutableFile(atPath: url.path)
    else { throw HostError.missingServer }
    return url
  }

  private static func readServerInfo() async throws -> HostServerInfo {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:43110/api/v1/server/info")!)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 1
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HostError.notReady }
    return try JSONDecoder().decode(HostServerInfo.self, from: data)
  }

  private static func randomSecret() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw HostError.randomFailure
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

private final class BoundedLogSink: @unchecked Sendable {
  let pipe = Pipe()

  private static let maximumFileSize = 1_048_576
  private let queue = DispatchQueue(label: "com.lucas.aurelia.media.server-host.log")
  private let currentURL: URL
  private let previousURL: URL
  private var handle: FileHandle?
  private var currentSize = 0
  private var isClosed = false

  init(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    currentURL = directory.appendingPathComponent("server.log")
    previousURL = directory.appendingPathComponent("server.previous.log")
    if (try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      >= Self.maximumFileSize
    {
      try? FileManager.default.removeItem(at: previousURL)
      try? FileManager.default.moveItem(at: currentURL, to: previousURL)
    }
    if !FileManager.default.fileExists(atPath: currentURL.path) {
      FileManager.default.createFile(
        atPath: currentURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600])
    }
    handle = try FileHandle(forWritingTo: currentURL)
    if let end = try handle?.seekToEnd(), let size = Int(exactly: end) {
      currentSize = size
    }
    pipe.fileHandleForReading.readabilityHandler = { [weak self] source in
      let data = source.availableData
      guard !data.isEmpty, let sink = self else { return }
      sink.queue.async { sink.append(data) }
    }
  }

  func close() {
    pipe.fileHandleForReading.readabilityHandler = nil
    queue.sync {
      guard !isClosed else { return }
      isClosed = true
      try? handle?.synchronize()
      try? handle?.close()
      handle = nil
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
  }

  private func append(_ data: Data) {
    guard !isClosed else { return }
    var offset = 0
    while offset < data.count {
      if currentSize >= Self.maximumFileSize {
        rotate()
      }
      let count = min(Self.maximumFileSize - currentSize, data.count - offset)
      guard count > 0 else { return }
      try? handle?.write(contentsOf: data[offset..<(offset + count)])
      currentSize += count
      offset += count
    }
  }

  private func rotate() {
    try? handle?.close()
    handle = nil
    try? FileManager.default.removeItem(at: previousURL)
    try? FileManager.default.moveItem(at: currentURL, to: previousURL)
    FileManager.default.createFile(
      atPath: currentURL.path,
      contents: nil,
      attributes: [.posixPermissions: 0o600])
    handle = try? FileHandle(forWritingTo: currentURL)
    currentSize = 0
  }
}

private struct HostRequest {
  let method: String
  let secret: String
  let action: String
  let body: Data
  let isComplete: Bool

  static func parse(_ data: Data) -> HostRequest? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: delimiter),
      let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
    else { return nil }
    let lines = header.components(separatedBy: "\r\n")
    guard let first = lines.first else { return nil }
    let parts = first.split(separator: " ")
    guard parts.count == 3, parts[2] == "HTTP/1.1" else { return nil }
    let pathParts = parts[1].split(separator: "/")
    guard pathParts.count == 2 else { return nil }
    let contentLength =
      lines.dropFirst().compactMap { line -> Int? in
        let pieces = line.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2, pieces[0].lowercased() == "content-length" else { return nil }
        return Int(pieces[1].trimmingCharacters(in: .whitespaces))
      }.first ?? 0
    guard contentLength >= 0, contentLength <= 32_768 else { return nil }
    let bodyStart = headerRange.upperBound
    let available = data.count - bodyStart
    let body =
      available >= contentLength
      ? Data(data[bodyStart..<(bodyStart + contentLength)])
      : Data()
    return HostRequest(
      method: String(parts[0]),
      secret: String(pathParts[0]),
      action: String(pathParts[1]),
      body: body,
      isComplete: available >= contentLength)
  }
}

private enum HostError: Error {
  case missingControlSecret
  case missingTrustedParent
  case missingLaunchConfiguration
  case invalidBootstrapDirectory
  case invalidLaunchDescription
  case invalidLaunchPathLocation
  case invalidSettings
  case settingsStorage
  case controlListener
  case missingServer
  case notReady
  case randomFailure
  case dataMigration

  var diagnosticCategory: String {
    switch self {
    case .missingControlSecret: "missing-control-secret"
    case .missingTrustedParent: "missing-trusted-parent"
    case .missingLaunchConfiguration: "missing-launch-configuration"
    case .invalidBootstrapDirectory: "invalid-bootstrap-directory"
    case .invalidLaunchDescription: "invalid-launch-description"
    case .invalidLaunchPathLocation: "invalid-launch-path-location"
    case .invalidSettings: "invalid-settings"
    case .settingsStorage: "settings-storage"
    case .controlListener: "control-listener"
    case .missingServer: "missing-server"
    case .notReady: "server-not-ready"
    case .randomFailure: "random-source"
    case .dataMigration: "data-migration"
    }
  }
}
