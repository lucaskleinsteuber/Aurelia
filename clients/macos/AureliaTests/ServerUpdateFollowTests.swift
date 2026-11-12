import Foundation
import Testing

@testable import Aurelia

/// Following a server update started on this Mac, with invented statuses; no server is updated.
@Suite("Server update follow-up")
struct ServerUpdateFollowTests {
  static func status(
    installed: String, newest: String? = nil, available: Bool = false, state: String = "idle",
    checkedAt: String? = nil, message: String? = nil
  ) -> ServerUpdateStatus {
    ServerUpdateStatus(
      available: true, installed: installed, newest: newest, updateAvailable: available,
      state: state, checkedAt: checkedAt, message: message)
  }

  @Test func anInstallationEndsOnceTheNewVersionRuns() {
    let start = Date(timeIntervalSince1970: 1000)
    let before = Self.status(installed: "2.11.0 (160)", newest: "2.12.0 (161)", available: true)
    let install = ServerUpdateOperation(kind: .install, before: before, startedAt: start)
    let busy = Self.status(installed: "2.11.0 (160)", newest: "2.12.0 (161)", available: true, state: "installing")
    #expect(install.outcome(of: busy, now: start.addingTimeInterval(30)) == nil)
    let done = Self.status(installed: "2.12.0 (161)", newest: "2.12.0 (161)")
    #expect(install.outcome(of: done, now: start.addingTimeInterval(80)) == .installed("2.12.0 (161)"))
    #expect(install.outcome(serverVersion: "2.12.0") == .installed("2.12.0"))
    #expect(install.outcome(serverVersion: "2.11.0") == nil)
    let failed = Self.status(installed: "2.11.0 (160)", state: "failed", message: "No signature.")
    #expect(install.outcome(of: failed, now: start.addingTimeInterval(40)) == .failed("No signature."))
    #expect(install.outcome(of: busy, now: start.addingTimeInterval(700)) == .notFinished)
  }

  @Test func aCheckSaysWhatItFound() {
    let start = Date(timeIntervalSince1970: 1000)
    let check = ServerUpdateOperation(
      kind: .check, before: Self.status(installed: "2.12.0 (161)"), startedAt: start)
    #expect(check.outcome(of: Self.status(installed: "2.12.0 (161)", state: "checking"), now: start.addingTimeInterval(5)) == nil)
    #expect(check.outcome(of: Self.status(installed: "2.12.0 (161)"), now: start.addingTimeInterval(9)) == .upToDate("2.12.0 (161)"))
    #expect(
      check.outcome(of: Self.status(installed: "2.12.0 (161)", newest: "2.13.0 (162)", available: true), now: start.addingTimeInterval(9))
        == .available("2.13.0 (162)"))
    #expect(ServerUpdateResult.upToDate("2.12.0 (161)").text.hasPrefix("No new version found"))
    #expect(ServerUpdateResult.installed("2.12.0 (161)").text.contains("installed and running"))
  }
}
