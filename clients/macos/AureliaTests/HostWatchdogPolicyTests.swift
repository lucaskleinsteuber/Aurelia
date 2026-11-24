import AppKit
import Foundation
import Testing

@testable import Aurelia

struct HostWatchdogPolicyTests {
  private let now: TimeInterval = 1_000

  @Test func threeTransportFailuresTriggerOneRestart() {
    var policy = HostWatchdogPolicy()
    #expect(policy.transportCompleted(receivedHTTPResponse: false, at: now) == .none)
    #expect(policy.transportCompleted(receivedHTTPResponse: false, at: now) == .none)
    #expect(policy.transportCompleted(receivedHTTPResponse: false, at: now) == .restart)
    #expect(policy.restartDates.count == 1)
    #expect(policy.consecutiveFailures == 0)
  }

  @Test func anyHTTPResponseClearsFailuresIncludingReadinessAndRateLimitErrors() {
    var policy = HostWatchdogPolicy()
    _ = policy.transportCompleted(receivedHTTPResponse: false, at: now)
    _ = policy.transportCompleted(receivedHTTPResponse: false, at: now)
    #expect(policy.transportCompleted(receivedHTTPResponse: true, at: now) == .none)
    #expect(policy.consecutiveFailures == 0)
    #expect(policy.restartDates.isEmpty)
  }

  @Test func crashAndHangUseOneTenMinuteBudget() {
    var policy = HostWatchdogPolicy()
    #expect(policy.requestAutomaticRecovery(at: now) == .restart)
    #expect(policy.requestAutomaticRecovery(at: now + 100) == .restart)
    for _ in 0..<2 { _ = policy.transportCompleted(receivedHTTPResponse: false, at: now + 200) }
    #expect(policy.transportCompleted(receivedHTTPResponse: false, at: now + 200) == .restart)
    #expect(policy.requestAutomaticRecovery(at: now + 599) == .limitReached)
    #expect(policy.requestAutomaticRecovery(at: now + 600) == .restart)
  }

  @Test func sleepAndWakeGraceIgnoreInterruptedRequests() {
    var policy = HostWatchdogPolicy()
    policy.willSleep()
    #expect(!policy.mayProbe(at: now, ready: true, operationActive: false))
    #expect(policy.transportCompleted(receivedHTTPResponse: false, at: now) == .none)
    policy.didWake(at: now)
    #expect(!policy.mayProbe(at: now + 59, ready: true, operationActive: false))
    #expect(policy.transportCompleted(receivedHTTPResponse: false, at: now + 59) == .none)
    #expect(policy.mayProbe(at: now + 60, ready: true, operationActive: false))
    #expect(policy.consecutiveFailures == 0)
  }

  @Test func startupAndPlannedOperationsNeverProbe() {
    let policy = HostWatchdogPolicy()
    #expect(!policy.mayProbe(at: now, ready: false, operationActive: false))
    #expect(!policy.mayProbe(at: now, ready: true, operationActive: true))
    #expect(policy.mayProbe(at: now, ready: true, operationActive: false))
  }

  @Test func becomingReadyPreservesBudgetAndManualRetryResetsIt() {
    var policy = HostWatchdogPolicy()
    for _ in 0..<3 { _ = policy.requestAutomaticRecovery(at: now) }
    policy.didBecomeReady()
    #expect(policy.requestAutomaticRecovery(at: now) == .limitReached)
    policy.manualRetry()
    #expect(policy.requestAutomaticRecovery(at: now) == .restart)
  }

  @Test func backgroundPreflightRequiresTheHelperInsideItsStagedAureliaBundle() {
    let root = "/private/tmp/Aurelia/synthetic-watchdog"
    let helper = URL(
      fileURLWithPath: root + "/Aurelia.app/Contents/Helpers/Aurelia Server Host.app")
    #expect(
      HostPreflightBackgroundSecurity.enclosingApplication(helperBundleURL: helper)?.path
        == root + "/Aurelia.app")
    let unrelated = [
      "/Applications/Aurelia.app/Contents/Helpers/Aurelia Server Host.app",
      root + "/Other.app/Contents/Helpers/Aurelia Server Host.app",
      root + "/Aurelia.app/Contents/Other/Aurelia Server Host.app",
      root + "/Aurelia.app/Contents/Helpers/Other.app",
    ]
    for path in unrelated {
      #expect(
        HostPreflightBackgroundSecurity.enclosingApplication(
          helperBundleURL: URL(fileURLWithPath: path)) == nil)
    }
  }

  @Test func backgroundPreflightRejectsMissingGateOverridesAndUnrelatedConfiguration() {
    let helper = URL(
      fileURLWithPath:
        "/private/tmp/Aurelia/synthetic-watchdog/Aurelia.app/Contents/Helpers/Aurelia Server Host.app"
    )
    #expect(throws: HostLaunchSecurityError.invalidDescription) {
      try HostPreflightBackgroundSecurity.load(environment: [:], helperBundleURL: helper)
    }
    #expect(throws: HostLaunchSecurityError.invalidDescription) {
      try HostPreflightBackgroundSecurity.load(
        environment: [
          "AURELIA_PREFLIGHT_TEST": "1", "AURELIA_SERVER_EXECUTABLE": "/unrelated/server",
        ], helperBundleURL: helper)
    }
    #expect(throws: HostLaunchSecurityError.invalidPathLocation) {
      try HostPreflightBackgroundSecurity.load(
        environment: [
          "AURELIA_PREFLIGHT_TEST": "1",
          "AURELIA_HOST_PREFLIGHT_CONFIG": "/private/tmp/Aurelia/another-run/Host/preflight.json",
        ], helperBundleURL: helper)
    }
  }

  @Test func idleOrStoppedServerNeverKeepsMacAwake() {
    #expect(
      HostWatchdogPolicy.shouldPreventIdleSleep(
        settingEnabled: true, isShuttingDown: false, isProcessRunning: true, isIdle: false))
    #expect(
      !HostWatchdogPolicy.shouldPreventIdleSleep(
        settingEnabled: true, isShuttingDown: false, isProcessRunning: false, isIdle: true))
    #expect(
      !HostWatchdogPolicy.shouldPreventIdleSleep(
        settingEnabled: true, isShuttingDown: false, isProcessRunning: true, isIdle: true))
    #expect(
      !HostWatchdogPolicy.shouldPreventIdleSleep(
        settingEnabled: true, isShuttingDown: true, isProcessRunning: true, isIdle: false))
    #expect(
      !HostWatchdogPolicy.shouldPreventIdleSleep(
        settingEnabled: false, isShuttingDown: false, isProcessRunning: true, isIdle: false))
  }

  @MainActor
  @Test func systemLogoutReturnsTerminateLaterAndRepliesAfterShutdown() async {
    let coordinator = ApplicationTerminationCoordinator()
    var shutdownFinished = false
    var replied: Bool?
    var terminateCalls = 0
    let reply = coordinator.request(
      isSystemPowerEvent: true,
      shutdown: {
        try? await Task.sleep(for: .milliseconds(10))
        shutdownFinished = true
      },
      terminate: { terminateCalls += 1 },
      reply: { replied = $0 }
    )
    #expect(reply == .terminateLater)
    for _ in 0..<200 where replied == nil {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(shutdownFinished)
    #expect(replied == true)
    #expect(terminateCalls == 0)
  }

  @MainActor
  @Test func switchToClientModeDisablesBackgroundHosting() async {
    var disabledBackgroundHosting = 0
    let model = AppModel(
      store: InMemoryServerProfileStore(),
      backgroundHostingDisabler: { disabledBackgroundHosting += 1 }
    )
    await model.switchToClientMode()
    #expect(disabledBackgroundHosting == 1)
    #expect(model.operatingMode == .client)
  }

  @Test func hostControlAuthSignsRequestsVerifiesProofsAndBlocksReplays() throws {
    let secret = String(repeating: "a1", count: 32)
    let nonce = try HostControlAuth.makeNonce()
    let body = Data("{\"ok\":true}".utf8)
    let signature = HostControlAuth.requestSignature(
      secret: secret, method: "POST", action: "restart", nonce: nonce, timestamp: 1_700_000_000,
      body: body)
    let same = HostControlAuth.requestSignature(
      secret: secret, method: "POST", action: "restart", nonce: nonce, timestamp: 1_700_000_000,
      body: body)
    let tampered = HostControlAuth.requestSignature(
      secret: secret, method: "POST", action: "shutdown", nonce: nonce, timestamp: 1_700_000_000,
      body: body)
    #expect(HostControlAuth.constantTimeEquals(signature, same))
    #expect(!HostControlAuth.constantTimeEquals(signature, tampered))
    #expect(!HostControlAuth.constantTimeEquals("abc", "abcd"))

    let proof = HostControlAuth.responseProof(secret: secret, nonce: nonce, status: 200, body: body)
    let wrongProof = HostControlAuth.responseProof(
      secret: "other-secret", nonce: nonce, status: 200, body: body)
    #expect(!HostControlAuth.constantTimeEquals(proof, wrongProof))

    var guardState = HostControlNonceReplayGuard()
    let firstAccepted = guardState.accept(
      nonce: nonce, timestamp: 1_700_000_000, now: 1_700_000_010)
    let replayAccepted = guardState.accept(
      nonce: nonce, timestamp: 1_700_000_000, now: 1_700_000_011)
    let staleAccepted = guardState.accept(
      nonce: "0123456789abcdef", timestamp: 1_700_000_000, now: 1_700_000_120)
    #expect(firstAccepted)
    #expect(!replayAccepted)
    #expect(!staleAccepted)
  }

  @Test func hostStartupErrorRecordRoundTripsAndClears() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaStartupErrorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }

    HostStartupErrorRecord.write(
      category: "data-directory-unavailable",
      message: "External drive unavailable.",
      in: dir)
    let record = HostStartupErrorRecord.readRecent(from: dir)
    #expect(record?.category == "data-directory-unavailable")
    #expect(record?.message == "External drive unavailable.")

    HostStartupErrorRecord.clear(in: dir)
    #expect(HostStartupErrorRecord.readRecent(from: dir) == nil)
  }

  @Test func staleLaunchHandoffFilesArePrunedWhileActiveAndBackgroundFilesStay() throws {
    let fileManager = FileManager.default
    let dir = fileManager.temporaryDirectory
      .appendingPathComponent("AureliaHandoffPruneTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fileManager.removeItem(at: dir) }

    let deadJSON = dir.appendingPathComponent("launch-40001.json")
    let deadPipe = dir.appendingPathComponent("launch-40001.pipe")
    let aliveJSON = dir.appendingPathComponent("launch-40002.json")
    let ownJSON = dir.appendingPathComponent("launch-40003.json")
    let staleRendezvous = dir.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
    let freshRendezvous = dir.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
    let backgroundSettings = dir.appendingPathComponent("background-settings.json")
    let backgroundRendezvous = dir.appendingPathComponent(
      HostServiceSettings.backgroundRendezvousName)

    for file in [
      deadJSON, aliveJSON, ownJSON, staleRendezvous, freshRendezvous, backgroundSettings,
      backgroundRendezvous,
    ] {
      try Data("{}".utf8).write(to: file)
    }
    #expect(mkfifo(deadPipe.path, S_IRUSR | S_IWUSR) == 0)
    let now = Date()
    try fileManager.setAttributes(
      [.modificationDate: now.addingTimeInterval(-7_200)], ofItemAtPath: staleRendezvous.path)
    try fileManager.setAttributes(
      [.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: freshRendezvous.path)

    HostLaunchSecurity.pruneStaleHandoffFiles(
      in: dir, currentProcessID: 40_003, now: now, staleRendezvousAge: 3_600,
      processIsAlive: { pid in pid == 40_002 })

    #expect(!fileManager.fileExists(atPath: deadJSON.path))
    #expect(!fileManager.fileExists(atPath: deadPipe.path))
    #expect(!fileManager.fileExists(atPath: staleRendezvous.path))
    #expect(fileManager.fileExists(atPath: aliveJSON.path))
    #expect(fileManager.fileExists(atPath: ownJSON.path))
    #expect(fileManager.fileExists(atPath: freshRendezvous.path))
    #expect(fileManager.fileExists(atPath: backgroundSettings.path))
    #expect(fileManager.fileExists(atPath: backgroundRendezvous.path))
  }

  @Test func releaseModeIgnoresHelperPathAndDirectoryEnvironmentOverrides() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("AureliaOverrideGuardTests-\(UUID().uuidString)", isDirectory: true)
    let appBundle = root.appendingPathComponent("Aurelia.app", isDirectory: true)
    let bundledHelper = appBundle.appendingPathComponent(
      "Contents/Helpers/Aurelia Server Host.app", isDirectory: true)
    try fileManager.createDirectory(at: bundledHelper, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let customHelper = "/private/tmp/CustomHelper.app"
    let environment = [
      "AURELIA_HELPER_PATH": customHelper,
      "AURELIA_DATA_DIR": "/private/tmp/CustomData",
      "AURELIA_LOG_DIR": "/private/tmp/CustomLogs",
    ]
    let guardedURL = try NativeServerHost.resolvedHelperApplicationURL(
      bundleURL: appBundle, environment: environment, allowEnvironmentOverrides: false)
    #expect(guardedURL.standardizedFileURL == bundledHelper.standardizedFileURL)

    let allowedURL = try NativeServerHost.resolvedHelperApplicationURL(
      bundleURL: appBundle, environment: environment, allowEnvironmentOverrides: true)
    #expect(allowedURL.path == customHelper)

    let handoff = try HostLaunchHandoff(
      secret: String(repeating: "K", count: 43),
      directory: root,
      rendezvous: root.appendingPathComponent("rendezvous.json"),
      serverName: "Test Server",
      lanPort: 43_111,
      environment: environment,
      processID: 42_100,
      allowDirectoryOverrides: false)
    defer { handoff.remove() }
    let description = try JSONDecoder().decode(
      HostLaunchDescription.self, from: Data(contentsOf: handoff.configurationURL))
    #expect(description.dataDirectory == nil)
    #expect(description.logDirectory == nil)
  }
}
