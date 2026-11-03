import AppKit
@preconcurrency import Foundation
import IOKit.pwr_mgt
@preconcurrency import Network
import OSLog
import Security

@main
final class ServerHostApplication: NSObject, NSApplicationDelegate {
  private static let logger = Logger(
    subsystem: "com.lucas.aurelia.media.server-host", category: "lifecycle")
  private var runtime: ServerHostRuntime?
  private var terminationAuthorized = false
  private var workspaceObservers: [NSObjectProtocol] = []

  static func main() {
    if UpdateWorkerLaunch.runIfRequested(
      CommandLine.arguments, work: { _ = UpdateInstaller.runPendingIfRequested() })
    {
      return
    }
    // The app starts this helper in a second role to install an update it downloaded.
    if UpdateInstaller.runIfRequested(CommandLine.arguments) { return }
    let application = NSApplication.shared
    let delegate = ServerHostApplication()
    application.delegate = delegate
    application.setActivationPolicy(.prohibited)
    application.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if UpdateInstaller.hasPendingRequest() {
      // The GUI helper is subordinate to Aurelia: loginwindow force-quits it
      // when Aurelia exits, even after a successful handshake. Only the independent
      // one-shot worker claims/acknowledges the request and performs installation.
      Task { @MainActor [self] in
        do {
          guard let executable = Bundle.main.executableURL else {
            throw CocoaError(.executableNotLoadable)
          }
          try UpdateWorkerLaunch.submit(executable: executable)
        } catch {
          Self.logger.error("Could not start the independent update worker.")
        }
        finishTermination()
      }
      return
    }
    ProcessInfo.processInfo.disableAutomaticTermination(
      "Aurelia Server Host is managing the local server")
    ProcessInfo.processInfo.disableSuddenTermination()
    do {
      runtime = try ServerHostRuntime(
        environment: ProcessInfo.processInfo.environment,
        terminationHandler: { [weak self] in self?.finishTermination() })
      try runtime?.start()
      let center = NSWorkspace.shared.notificationCenter
      workspaceObservers = [
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
          [weak runtime] _ in runtime?.systemWillSleep()
        },
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
          [weak runtime] _ in runtime?.systemDidWake()
        },
      ]
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
  var isolatedBackground = false
}

private enum ChildServerReadiness: Equatable {
  case waiting
  case ready
  case stopping
}

private final class ServerHostRuntime: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.lucas.aurelia.media.server-host")
  private let secret: String
  private let parentProcessID: Int32
  private let rendezvousURL: URL
  private let dataDirectory: URL
  private let logDirectory: URL
  private let terminationHandler: @MainActor @Sendable () -> Void
  private let isolatedBackground: Bool
  private var listener: NWListener?
  private var process: Process?
  private var serverLifeline: Pipe?
  private var logSink: BoundedLogSink?
  private var parentTimer: DispatchSourceTimer?
  private var status = HostStatus(
    state: .starting, message: nil, bootstrapToken: nil, serverInfo: nil)
  private var pendingRestartLAN: Bool?
  private var pendingRestoreID: UUID?
  private var restoreProcess: Process?
  private var pendingBackgroundHandoff = false
  private var sleepAssertion: IOPMAssertionID = 0
  private var shuttingDown = false
  private var watchdog = HostWatchdogPolicy()
  private var watchdogTimer: DispatchSourceTimer?
  private var watchdogRequest: Task<Void, Never>?
  private var watchdogRequestID: UUID?
  private var readinessGeneration: UInt64 = 0
  private var serverReadyGeneration: UInt64?
  private var serverStoppingGeneration: UInt64?

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
    self.isolatedBackground = launch.isolatedBackground

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
    updateSleepAssertion()
  }

  func shutdown() {
    queue.async { [weak self] in self?.beginShutdown() }
  }

  func systemWillSleep() {
    queue.async { [weak self] in
      guard let self else { return }
      self.watchdog.willSleep()
      self.cancelWatchdogRequest()
    }
  }

  func systemDidWake() {
    queue.async { [weak self] in
      guard let self else { return }
      self.watchdog.didWake(at: ProcessInfo.processInfo.systemUptime)
      self.cancelWatchdogRequest()
    }
  }

  private var settingsURL: URL {
    dataDirectory.appendingPathComponent("server-settings.json")
  }

  private static func resolveLaunch(environment: [String: String]) throws -> ResolvedHostLaunch {
    if ProcessInfo.processInfo.arguments.contains("--preflight-background") {
      guard ProcessInfo.processInfo.arguments.contains("--background") else {
        throw HostError.invalidLaunchDescription
      }
      let preflight: ValidatedHostPreflightBackground
      do {
        preflight = try HostPreflightBackgroundSecurity.load(
          environment: environment, helperBundleURL: Bundle.main.bundleURL)
      } catch { throw HostError.invalidLaunchDescription }
      return ResolvedHostLaunch(
        secret: preflight.secret, parentProcessID: 0, rendezvousURL: preflight.rendezvousURL,
        dataDirectory: preflight.dataDirectory, logDirectory: preflight.logDirectory,
        serverName: "Synthetic Watchdog", lanPort: 43_111, isolatedBackground: true)
    }
    if ProcessInfo.processInfo.arguments.contains("--background") {
      let settings = try HostServiceSettings.load()
      guard settings.backgroundEnabled else { throw HostError.invalidLaunchDescription }
      return ResolvedHostLaunch(
        secret: settings.controlSecret, parentProcessID: 0,
        rendezvousURL: try HostBootstrapLocation.directory().appendingPathComponent(
          HostServiceSettings.backgroundRendezvousName),
        dataDirectory: defaultDataDirectory, logDirectory: defaultLogDirectory,
        serverName: "Aurelia", lanPort: 43_111)
    }
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
    stopWatchdog()
    readinessGeneration &+= 1
    let generation = readinessGeneration
    serverReadyGeneration = nil
    serverStoppingGeneration = nil
    do {
      let executable = try serverExecutableURL()
      let settings = try loadSettings()
      let bootstrapToken = lan ? nil : try Self.randomSecret()
      let readinessNonce = try Self.randomSecret()
      updateStatus(lan ? .restarting : .starting, bootstrapToken: bootstrapToken)

      let logSink = try BoundedLogSink(
        directory: logDirectory,
        readinessNonce: readinessNonce,
        onServerStopping: { [weak self] in
          guard let runtime = self else { return }
          runtime.queue.async {
            guard runtime.readinessGeneration == generation else { return }
            runtime.serverReadyGeneration = nil
            runtime.serverStoppingGeneration = generation
            runtime.stopWatchdog()
          }
        },
        onServerReady: { [weak self] in
          guard let runtime = self else { return }
          runtime.queue.async {
            guard runtime.readinessGeneration == generation,
              runtime.process?.isRunning == true
            else { return }
            runtime.serverReadyGeneration = generation
          }
        }
      )
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
      environment["AURELIA_HOST_READY_NONCE"] = readinessNonce
      environment["AURELIA_HOST_LIFELINE"] = "1"
      if let port = listener?.port {
        environment["AURELIA_HOST_CONTROL_URL"] = "http://127.0.0.1:\(port.rawValue)/\(secret)"
      }
      child.environment = environment
      let lifeline = Pipe()
      serverLifeline = lifeline
      child.standardInput = lifeline
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
      closeServerLifeline()
      updateStatus(.failed, message: "The bundled Aurelia Server could not be started.")
    }
  }

  private func waitForServer(lan: Bool, bootstrapToken: String?, generation: UInt64) {
    Task { [weak self] in
      for _ in 0..<150 {
        guard let self else { return }
        switch await self.serverReadinessState(generation: generation) {
        case .waiting:
          try? await Task.sleep(for: .milliseconds(200))
          continue
        case .stopping:
          return
        case .ready:
          break
        }
        if let info = try? await Self.readServerInfo() {
          guard await self.serverReadinessState(generation: generation) == .ready else { return }
          self.queue.async {
            guard self.readinessGeneration == generation,
              self.serverReadyGeneration == generation,
              self.serverStoppingGeneration != generation,
              self.process?.isRunning == true
            else { return }
            if !lan && info.isSetup && (try? self.loadSettings().lanAccessEnabled) == true {
              self.restart(lan: true)
            } else {
              self.status = HostStatus(
                state: info.isSetup ? .running : .setupRequired,
                message: nil,
                bootstrapToken: info.isSetup ? nil : bootstrapToken,
                serverInfo: info)
              if var operation = try? self.readOperation(),
                operation["state"] as? String == "restarting"
              {
                operation["state"] = "completed"
                try? self.writeOperation(operation)
              }
              self.startWatchdog(generation: generation)
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

  private func serverReadinessState(generation: UInt64) async -> ChildServerReadiness {
    await withCheckedContinuation { continuation in
      queue.async {
        guard !self.shuttingDown,
          self.readinessGeneration == generation,
          self.process?.isRunning == true,
          self.serverStoppingGeneration != generation
        else {
          continuation.resume(returning: .stopping)
          return
        }
        continuation.resume(
          returning: self.serverReadyGeneration == generation ? .ready : .waiting)
      }
    }
  }

  private func startWatchdog(generation: UInt64) {
    stopWatchdog()
    watchdog.didBecomeReady()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 15, repeating: 15)
    timer.setEventHandler { [weak self] in self?.probeServerLiveness(generation: generation) }
    watchdogTimer = timer
    timer.resume()
  }

  private func stopWatchdog() {
    watchdogTimer?.cancel()
    watchdogTimer = nil
    cancelWatchdogRequest()
  }

  private func cancelWatchdogRequest() {
    watchdogRequest?.cancel()
    watchdogRequest = nil
    watchdogRequestID = nil
  }

  private func watchdogMayProbe(generation: UInt64) -> Bool {
    let operation = try? readOperation()
    let plannedOperation = ["restarting", "awaitingConfirmation", "awaitingMacApproval"]
      .contains(operation?["state"] as? String ?? "")
    return watchdog.mayProbe(
      at: ProcessInfo.processInfo.systemUptime,
      ready: readinessGeneration == generation && serverReadyGeneration == generation
        && serverStoppingGeneration != generation && process?.isRunning == true
        && (status.state == .running || status.state == .setupRequired),
      operationActive: shuttingDown || pendingRestartLAN != nil || pendingRestoreID != nil
        || restoreProcess != nil || pendingBackgroundHandoff || plannedOperation)
  }

  private func probeServerLiveness(generation: UInt64) {
    guard watchdogRequest == nil, watchdogMayProbe(generation: generation) else { return }
    let requestID = UUID()
    watchdogRequestID = requestID
    watchdogRequest = Task { [weak self] in
      let receivedResponse = await Self.serverAnsweredLivenessProbe()
      guard !Task.isCancelled, let self else { return }
      self.queue.async {
        guard self.watchdogRequestID == requestID else { return }
        self.watchdogRequest = nil
        self.watchdogRequestID = nil
        guard self.watchdogMayProbe(generation: generation) else { return }
        switch self.watchdog.transportCompleted(
          receivedHTTPResponse: receivedResponse, at: ProcessInfo.processInfo.systemUptime)
        {
        case .none:
          break
        case .restart:
          self.recordRecovery("host_transport_restart")
          self.restart(lan: (try? self.loadSettings().lanAccessEnabled) ?? false)
        case .limitReached:
          self.recordRecovery("host_restart_limit")
          self.stopWatchdog()
          self.updateStatus(
            .failed,
            message:
              "Aurelia Server did not respond after repeated recovery attempts. Choose Restart to try again."
          )
        }
      }
    }
  }

  private static func serverAnsweredLivenessProbe() async -> Bool {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:43110/api/v1/health/live")!)
    // HEAD completes after headers, even if a faulty service stalls its body.
    // Every valid HTTP status (including 429/503) confirms transport liveness.
    request.httpMethod = "HEAD"
    request.timeoutInterval = 3
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForResource = 3
    let session = URLSession(
      configuration: configuration, delegate: LivenessRedirectPolicy(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (_, response) = try await session.data(for: request)
      return response is HTTPURLResponse
    } catch { return false }
  }

  private final class LivenessRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      // A redirect already proves that the local service can answer HTTP.
      completionHandler(nil)
    }
  }

  private struct RecoveryEvent: Codable {
    let at: Date
    let code: String
  }

  private func recordRecovery(_ code: String) {
    let allowed = [
      "host_transport_restart", "host_process_restart", "host_restart_limit", "host_manual_retry",
    ]
    guard allowed.contains(code) else { return }
    let url = dataDirectory.appendingPathComponent("host-recovery.json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var events: [RecoveryEvent] = []
    if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
      values.isSymbolicLink != true, (values.fileSize ?? 0) <= 65_536,
      let data = try? Data(contentsOf: url),
      let previous = try? decoder.decode([RecoveryEvent].self, from: data)
    {
      events = Array(previous.filter { allowed.contains($0.code) }.suffix(19))
    }
    events.append(RecoveryEvent(at: Date(), code: code))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    do {
      let data = try encoder.encode(events)
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      // Recovery must not depend on writable diagnostics storage.
    }
  }

  private func restart(lan: Bool) {
    guard !shuttingDown else { return }
    stopWatchdog()
    if pendingRestartLAN != nil {
      pendingRestartLAN = lan
      return
    }
    readinessGeneration &+= 1
    serverReadyGeneration = nil
    serverStoppingGeneration = nil
    pendingRestartLAN = lan
    updateStatus(.restarting)
    if let process, process.isRunning {
      let processIdentifier = process.processIdentifier
      process.terminate()
      queue.asyncAfter(deadline: .now() + 10) { [weak process] in
        if process?.isRunning == true { kill(processIdentifier, SIGKILL) }
      }
    } else {
      pendingRestartLAN = nil
      startServer(lan: lan)
    }
  }

  private func serverTerminated(status terminationStatus: Int32) {
    stopWatchdog()
    process = nil
    closeServerLifeline()
    serverReadyGeneration = nil
    serverStoppingGeneration = nil
    logSink?.close()
    logSink = nil
    if shuttingDown {
      updateStatus(.stopped)
      DispatchQueue.main.async { [terminationHandler] in terminationHandler() }
      return
    }
    if let restoreID = pendingRestoreID {
      pendingRestoreID = nil
      applyPreparedRestore(restoreID)
      return
    }
    if pendingBackgroundHandoff {
      pendingBackgroundHandoff = false
      do {
        let settings = try HostServiceSettings.load()
        guard settings.backgroundEnabled else { throw HostError.invalidSettings }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launcher.arguments = ["kickstart", "-k", "gui/\(getuid())/\(settings.agentName)"]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        launcher.terminationHandler = { [weak self] command in
          self?.queue.async { [weak self] in
            guard let self else { return }
            if command.terminationStatus == 0 {
              self.beginShutdown()
            } else {
              self.updateStatus(
                .failed,
                message: "The background service could not start. Check its macOS permission.")
            }
          }
        }
        try launcher.run()
        queue.asyncAfter(deadline: .now() + 5) { [weak launcher] in
          if launcher?.isRunning == true { launcher?.terminate() }
        }
      } catch {
        updateStatus(
          .failed, message: "The background service could not start. Check its macOS permission.")
      }
      return
    }
    if let requestedLAN = pendingRestartLAN {
      pendingRestartLAN = nil
      startServer(lan: requestedLAN)
      return
    }

    guard watchdog.requestAutomaticRecovery(at: ProcessInfo.processInfo.systemUptime) == .restart
    else {
      recordRecovery("host_restart_limit")
      updateStatus(
        .failed,
        message: "Aurelia Server stopped repeatedly. Check Server Settings, then choose Restart.")
      return
    }
    recordRecovery("host_process_restart")
    updateStatus(.restarting, message: "Aurelia Server stopped unexpectedly. Restarting…")
    queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startServer(lan: false) }
  }

  private func closeServerLifeline() {
    try? serverLifeline?.fileHandleForWriting.close()
    try? serverLifeline?.fileHandleForReading.close()
    serverLifeline = nil
  }

  private func beginShutdown() {
    guard !shuttingDown else { return }
    shuttingDown = true
    stopWatchdog()
    readinessGeneration &+= 1
    serverReadyGeneration = nil
    serverStoppingGeneration = nil
    updateStatus(.stopping)
    parentTimer?.cancel()
    parentTimer = nil
    if sleepAssertion != 0 {
      IOPMAssertionRelease(sleepAssertion)
      sleepAssertion = 0
    }
    listener?.cancel()
    listener = nil
    try? FileManager.default.removeItem(at: rendezvousURL)
    if restoreProcess?.isRunning == true { return }
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
      self.rollbackExpiredNetworkChange()
      self.updateSleepAssertion()
      if self.parentProcessID > 1 && kill(self.parentProcessID, 0) != 0 && errno == ESRCH {
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
    if isolatedBackground,
      !((request.method == "GET" && request.action == "status")
        || (request.method == "POST" && ["restart", "shutdown"].contains(request.action)))
    {
      respond(connection, status: 404, body: Data())
      return
    }
    switch (request.method, request.action) {
    case ("POST", "owner-pin-recovery"):
      guard status.state == .running, request.body.count <= 4096 else {
        respond(connection, status: 409, body: Data())
        return
      }
      var forwarded = URLRequest(url: URL(string: "http://127.0.0.1:43110/api/v1/local/owner-pin")!)
      forwarded.httpMethod = "POST"
      forwarded.httpBody = request.body
      forwarded.timeoutInterval = 10
      forwarded.setValue("application/json", forHTTPHeaderField: "Content-Type")
      forwarded.setValue(secret, forHTTPHeaderField: "X-Aurelia-Host-Recovery")
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      let session = URLSession(configuration: configuration)
      session.dataTask(with: forwarded) { [weak self] data, response, _ in
        session.invalidateAndCancel()
        self?.queue.async { [weak self] in
          guard let self else { return }
          let status = (response as? HTTPURLResponse)?.statusCode ?? 503
          self.respond(
            connection, status: status, body: data.map { Data($0.prefix(4096)) } ?? Data())
        }
      }.resume()
    case ("POST", "hosting-authorized"):
      do {
        let settings = try JSONDecoder().decode(HostServiceRequest.self, from: request.body)
        guard settings.backgroundEnabled || !settings.startAtLogin,
          let operation = try? readOperation(),
          (operation["id"] as? String)?.lowercased() == settings.id.uuidString.lowercased(),
          operation["kind"] as? String == "hosting"
        else { throw HostError.invalidSettings }
        try settings.save()
        respond(connection, status: 204, body: Data())
      } catch { respond(connection, status: 400, body: Data()) }
    case ("POST", "hosting-applied"):
      guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
        let state = body["state"] as? String, ["completed", "awaitingPermission"].contains(state),
        let id = body["id"] as? String,
        var operation = try? readOperation(), operation["kind"] as? String == "hosting",
        (operation["id"] as? String)?.lowercased() == id.lowercased(),
        let pending = try? HostServiceRequest.load(),
        pending.id.uuidString.lowercased() == id.lowercased()
      else {
        respond(connection, status: 409, body: Data())
        return
      }
      do {
        operation["state"] = state
        try writeOperation(operation)
        if state == "completed" {
          try? FileManager.default.removeItem(at: HostServiceRequest.location())
        }
        respond(connection, status: 204, body: Data())
      } catch { respond(connection, status: 500, body: Data()) }
    case ("GET", "hosting-status"):
      let settings = (try? HostServiceSettings.load()) ?? HostServiceSettings()
      let operation = try? readOperation()
      let state =
        operation?["kind"] as? String == "hosting"
        ? (operation?["state"] as? String ?? "unknown") : "unchanged"
      let body = try? JSONSerialization.data(withJSONObject: [
        "backgroundEnabled": parentProcessID == 0,
        "backgroundRequested": settings.backgroundEnabled, "startAtLogin": settings.startAtLogin,
        "preventIdleSleep": settings.preventIdleSleep, "state": state,
      ])
      respond(connection, status: 200, body: body ?? Data())
    case ("GET", "status"):
      let body = (try? JSONEncoder().encode(status)) ?? Data()
      respond(connection, status: 200, body: body)
    case ("POST", "restart"):
      watchdog.manualRetry()
      recordRecovery("host_manual_retry")
      respond(connection, status: 202, body: Data())
      queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self else { return }
        self.restart(lan: (try? self.loadSettings().lanAccessEnabled) ?? false)
      }
    case ("POST", "network-trial"):
      guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
        let id = body["id"] as? String, let operation = try? readOperation(),
        (operation["id"] as? String)?.lowercased() == id.lowercased(),
        operation["state"] as? String == "awaitingConfirmation"
      else {
        respond(connection, status: 409, body: Data())
        return
      }
      respond(connection, status: 202, body: Data())
      queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self else { return }
        self.restart(lan: (try? self.loadSettings().lanAccessEnabled) ?? false)
      }
    case ("POST", "network-confirm"):
      guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
        let id = body["id"] as? String, var operation = try? readOperation(),
        (operation["id"] as? String)?.lowercased() == id.lowercased(),
        operation["state"] as? String == "awaitingConfirmation",
        let deadline = operation["confirmBefore"] as? String,
        Self.operationDate(deadline).map({ $0 > Date() }) == true
      else {
        respond(connection, status: 409, body: Data())
        return
      }
      do {
        operation["state"] = "completed"
        operation["confirmBefore"] = NSNull()
        operation["previousSettings"] = NSNull()
        try writeOperation(operation)
        respond(connection, status: 204, body: Data())
      } catch { respond(connection, status: 500, body: Data()) }
    case ("POST", "restore-prepared"):
      guard restoreProcess == nil, pendingRestoreID == nil,
        let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
        let idString = body["id"] as? String, let id = UUID(uuidString: idString),
        let operation = try? readOperation(), operation["kind"] as? String == "restore",
        (operation["id"] as? String)?.lowercased() == idString.lowercased()
      else {
        respond(connection, status: 409, body: Data())
        return
      }
      respond(connection, status: 202, body: Data())
      queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self else { return }
        self.stopWatchdog()
        self.updateStatus(
          .restarting,
          message: "Restoring verified server state. All devices will need to sign in again.")
        if let process = self.process, process.isRunning {
          self.pendingRestoreID = id
          process.terminate()
        } else {
          self.applyPreparedRestore(id)
        }
      }
    case ("POST", "handoff-background"):
      guard parentProcessID > 1, (try? HostServiceSettings.load().backgroundEnabled) == true,
        restoreProcess == nil, pendingRestoreID == nil
      else {
        respond(connection, status: 409, body: Data())
        return
      }
      respond(connection, status: 202, body: Data())
      queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self else { return }
        self.stopWatchdog()
        self.pendingBackgroundHandoff = true
        if let process = self.process, process.isRunning {
          process.terminate()
        } else {
          self.serverTerminated(status: 0)
        }
      }
    case ("POST", "configure"):
      // Only initial owner setup may use the legacy bootstrap command. After setup,
      // versioned settings belong to the authenticated .NET management API.
      guard status.serverInfo?.isSetup == false else {
        respond(connection, status: 409, body: Data())
        return
      }
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
    if state == .failed, var operation = try? readOperation(),
      operation["state"] as? String == "restarting"
    {
      operation["state"] = "failed"
      try? writeOperation(operation)
    }
    status = HostStatus(
      state: state,
      message: message,
      bootstrapToken: bootstrapToken,
      serverInfo: status.serverInfo)
  }

  private func loadSettings() throws -> HostSettings {
    try JSONDecoder().decode(HostSettings.self, from: Data(contentsOf: settingsURL))
  }

  private var operationURL: URL { dataDirectory.appendingPathComponent("host-operation.json") }
  private func updateSleepAssertion() {
    guard !isolatedBackground else { return }
    let requested = (try? HostServiceSettings.load().preventIdleSleep) == true
    if requested && sleepAssertion == 0 {
      var assertion: IOPMAssertionID = 0
      if IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Aurelia Server hosting" as CFString, &assertion)
        == kIOReturnSuccess
      {
        sleepAssertion = assertion
      }
    } else if !requested && sleepAssertion != 0 {
      IOPMAssertionRelease(sleepAssertion)
      sleepAssertion = 0
    }
  }
  private func applyPreparedRestore(_ id: UUID) {
    do {
      let child = Process()
      child.executableURL = try serverExecutableURL()
      child.arguments = [
        "database", "restore-prepared", "--id", id.uuidString, "--data-dir", dataDirectory.path,
      ]
      child.standardOutput = FileHandle.nullDevice
      child.standardError = FileHandle.nullDevice
      child.terminationHandler = { [weak self] completed in
        guard let runtime = self else { return }
        let succeeded = completed.terminationStatus == 0
        runtime.queue.async {
          runtime.restoreProcess = nil
          if var operation = try? runtime.readOperation() {
            operation["state"] = succeeded ? "completed" : "failed"
            try? runtime.writeOperation(operation)
          }
          if runtime.shuttingDown {
            DispatchQueue.main.async { [handler = runtime.terminationHandler] in handler() }
          } else {
            runtime.startServer(lan: (try? runtime.loadSettings().lanAccessEnabled) ?? false)
          }
        }
      }
      restoreProcess = child
      try child.run()
    } catch {
      restoreProcess = nil
      updateStatus(
        .failed,
        message:
          "The verified restore could not be applied. Start the host again to recover safely.")
    }
  }
  private func readOperation() throws -> [String: Any] {
    try HostLaunchSecurity.validateConfigurationFile(
      at: operationURL.path, bootstrapDirectory: dataDirectory)
    guard
      let value = try JSONSerialization.jsonObject(with: Data(contentsOf: operationURL))
        as? [String: Any],
      value["version"] as? Int == 1
    else { throw HostError.invalidSettings }
    return value
  }
  private func writeOperation(_ value: [String: Any]) throws {
    try JSONSerialization.data(withJSONObject: value).write(to: operationURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: operationURL.path)
  }
  private static func operationDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
  private func rollbackExpiredNetworkChange() {
    guard var operation = try? readOperation(),
      operation["state"] as? String == "awaitingConfirmation",
      let deadline = operation["confirmBefore"] as? String,
      Self.operationDate(deadline).map({ $0 <= Date() }) == true,
      let previous = operation["previousSettings"] as? [String: Any]
    else { return }
    do {
      try JSONSerialization.data(withJSONObject: previous).write(
        to: settingsURL, options: [.atomic])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
      operation["state"] = "rolledBack"
      operation["confirmBefore"] = NSNull()
      operation["previousSettings"] = NSNull()
      try writeOperation(operation)
      restart(lan: (try loadSettings()).lanAccessEnabled)
    } catch {
      updateStatus(.failed, message: "The previous network settings could not be restored.")
    }
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
      lanAccessEnabled: settings.lanAccessEnabled,
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
    // The Mac app is built for Apple silicon only.
    let runtime = "osx-arm64"
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
  private let readinessMarker: Data
  private let stoppingMarker: Data
  private let onServerStopping: @Sendable () -> Void
  private let onServerReady: @Sendable () -> Void
  private var handle: FileHandle?
  private var currentSize = 0
  private var isClosed = false
  private var pendingOutput = Data()
  private var didSignalReadiness = false
  private var didSignalStopping = false

  init(
    directory: URL,
    readinessNonce: String,
    onServerStopping: @escaping @Sendable () -> Void,
    onServerReady: @escaping @Sendable () -> Void
  ) throws {
    readinessMarker = Data("AURELIA_SERVER_READY:\(readinessNonce)".utf8)
    stoppingMarker = Data("AURELIA_SERVER_STOPPING:\(readinessNonce)".utf8)
    self.onServerStopping = onServerStopping
    self.onServerReady = onServerReady
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
      if !pendingOutput.isEmpty {
        appendToLog(pendingOutput)
        pendingOutput.removeAll(keepingCapacity: false)
      }
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
    pendingOutput.append(data)
    while let newline = pendingOutput.firstIndex(of: 0x0A) {
      let line = Data(pendingOutput[..<newline])
      let afterNewline = pendingOutput.index(after: newline)
      pendingOutput.removeSubrange(pendingOutput.startIndex..<afterNewline)
      var comparableLine = line
      if comparableLine.last == 0x0D {
        comparableLine.removeLast()
      }
      if comparableLine == readinessMarker {
        if !didSignalReadiness {
          didSignalReadiness = true
          onServerReady()
        }
      } else if comparableLine == stoppingMarker {
        if !didSignalStopping {
          didSignalStopping = true
          onServerStopping()
        }
      } else {
        var logLine = line
        logLine.append(0x0A)
        appendToLog(logLine)
      }
    }

    let preservedTailCount = readinessMarker.count + 2
    if pendingOutput.count > 16_384 {
      let flushCount = pendingOutput.count - preservedTailCount
      if flushCount > 0 {
        appendToLog(Data(pendingOutput.prefix(flushCount)))
        pendingOutput.removeSubrange(0..<flushCount)
      }
    }
  }

  private func appendToLog(_ data: Data) {
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
