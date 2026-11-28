import Foundation
import Testing

@testable import Tarven

/// Following a server update started on this Mac, with invented statuses; no server is updated.
@Suite("Server update follow-up")
struct ServerUpdateFollowTests {
  static func status(
    installed: String, newest: String? = nil, available: Bool = false, state: String = "idle",
    checkedAt: String? = nil, message: String? = nil, progressPercent: Int? = nil,
    phase: String? = nil
  ) -> ServerUpdateStatus {
    ServerUpdateStatus(
      available: true, installed: installed, newest: newest, updateAvailable: available,
      state: state, checkedAt: checkedAt, message: message, progressPercent: progressPercent,
      phase: phase)
  }

  @Test func anInstallationEndsOnceTheNewVersionRuns() {
    let start = Date(timeIntervalSince1970: 1000)
    let before = Self.status(installed: "2.11.0 (160)", newest: "2.12.0 (161)", available: true)
    let install = ServerUpdateOperation(kind: .install, before: before, startedAt: start)
    let busy = Self.status(
      installed: "2.11.0 (160)", newest: "2.12.0 (161)", available: true, state: "installing")
    #expect(install.outcome(of: busy, now: start.addingTimeInterval(30)) == nil)
    let done = Self.status(installed: "2.12.0 (161)", newest: "2.12.0 (161)")
    #expect(
      install.outcome(of: done, now: start.addingTimeInterval(80)) == .installed("2.12.0 (161)"))
    #expect(install.outcome(serverVersion: "2.12.0") == .installed("2.12.0"))
    #expect(install.outcome(serverVersion: "2.11.0") == nil)
    let failed = Self.status(installed: "2.11.0 (160)", state: "failed", message: "No signature.")
    #expect(
      install.outcome(of: failed, now: start.addingTimeInterval(40)) == .failed("No signature."))
    #expect(install.outcome(of: busy, now: start.addingTimeInterval(700)) == .notFinished)
  }

  @Test func aCheckSaysWhatItFound() {
    let start = Date(timeIntervalSince1970: 1000)
    let check = ServerUpdateOperation(
      kind: .check, before: Self.status(installed: "2.12.0 (161)"), startedAt: start)
    #expect(
      check.outcome(
        of: Self.status(installed: "2.12.0 (161)", state: "checking"),
        now: start.addingTimeInterval(5)) == nil)
    #expect(
      check.outcome(of: Self.status(installed: "2.12.0 (161)"), now: start.addingTimeInterval(9))
        == .upToDate("2.12.0 (161)"))
    #expect(
      check.outcome(
        of: Self.status(installed: "2.12.0 (161)", newest: "2.13.0 (162)", available: true),
        now: start.addingTimeInterval(9))
        == .available("2.13.0 (162)"))
    #expect(ServerUpdateResult.upToDate("2.12.0 (161)").text.hasPrefix("No new version found"))
    #expect(ServerUpdateResult.installed("2.12.0 (161)").text.contains("installed and running"))
  }

  @Test func progressFractionAndPhaseTextFollowServerStepsAndReconnection() throws {
    let before = Self.status(installed: "2.11.0 (160)", newest: "2.12.0 (161)", available: true)
    let operation = ServerUpdateOperation(kind: .install, before: before)

    let checking = Self.status(
      installed: "2.11.0 (160)", state: "checking", progressPercent: 20, phase: "checking")
    #expect(checking.progressFraction() == 0.2)
    #expect(checking.displayPercent() == 20)
    #expect(checking.phaseText() == "Checking GitHub for updates…")

    let verifying = Self.status(
      installed: "2.11.0 (160)", state: "installing", progressPercent: 30, phase: "verifying")
    #expect(verifying.phaseText() == "Verifying release signature…")

    let downloading = Self.status(
      installed: "2.11.0 (160)", newest: "2.12.0 (161)", available: true, state: "installing",
      progressPercent: 54, phase: "downloading")
    #expect(downloading.progressFraction() == 0.54)
    #expect(downloading.displayPercent() == 54)
    #expect(
      operation.progressText(status: downloading, reconnecting: false)
        == "Downloading server update… 54%")

    let unpacking = Self.status(
      installed: "2.11.0 (160)", state: "installing", progressPercent: 82, phase: "unpacking")
    #expect(unpacking.phaseText() == "Verifying checksum and unpacking…")

    let restarting = Self.status(
      installed: "2.11.0 (160)", state: "installing", progressPercent: 92, phase: "restarting")
    #expect(restarting.phaseText() == "Installing and restarting server…")
    #expect(restarting.progressFraction(reconnecting: true) == 0.95)
    #expect(restarting.displayPercent(reconnecting: true) == 95)
    #expect(
      operation.progressText(status: restarting, reconnecting: true)
        == "Waiting for server to restart…")

    // Older servers omit progressPercent and phase; clamping handles out-of-range numbers.
    let older = try JSONDecoder().decode(
      ServerUpdateStatus.self,
      from: Data(
        #"{"available":true,"installed":"2.11.0","newest":"2.12.0","updateAvailable":true,"state":"installing","checkedAt":null,"message":null}"#
          .utf8))
    #expect(older.progressFraction() == nil)
    #expect(older.displayPercent() == nil)
    #expect(older.progressFraction(reconnecting: true) == 0.95)
    let over = Self.status(installed: "2.11.0", state: "installing", progressPercent: 140)
    #expect(over.clampedPercent == 100)
  }
}
