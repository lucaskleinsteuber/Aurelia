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
}
