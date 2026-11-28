import Foundation
import Testing

/// Server administration on the Apple TV: one-time approvals, unlocking on another device, power
/// and Wake-on-LAN, Power Now and screen time words. A fake server and invented names only.
@Suite struct TVAdministrationTests {
  private let fingerprint = String(repeating: "B", count: 64)

  @Test func aProtectedChangeGetsOneApprovalAndIsSentOnceMore() async throws {
    let transport = TVAdminTestTransport(responses: [
      problem(403, "approval_required"),
      raw(#"{"token":"\#(String(repeating: "T", count: 43))","expiresAt":"2099-01-01T00:00:00Z"}"#),
      raw(
        #"{"id":"77000000-0000-0000-0000-000000000001","kind":"restart","state":"running","confirmBefore":null,"httpsPort":null}"#
      ),
    ])
    _ = try await api(transport).restartServer()
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(requests[1].url?.path == "/api/v1/management/approval")
    let confirmation = try JSONDecoder().decode(
      [String: String].self, from: requests[1].httpBody ?? Data())
    #expect(confirmation["action"] == "POST /api/v1/server/operations/restart")
    #expect(confirmation["payloadHash"] == TVApprovalExecutor.payloadHash(nil))
    #expect(requests[2].value(forHTTPHeaderField: "X-Tarven-Approval")?.count == 43)
  }

  @Test func lockedManagementIsReportedForTheUnlockScreen() async throws {
    let transport = TVAdminTestTransport(responses: [problem(403, "management_locked")])
    await #expect {
      _ = try await api(transport).serverPower()
    } throws: { error in
      (error as? TVCoreError)?.isManagementLocked == true
    }
    #expect(await transport.requests.count == 1)
  }

  @Test func confirmingOnAnotherDeviceShowsACodeAndWaits() async throws {
    let transport = TVAdminTestTransport(responses: [
      raw(
        #"{"id":"77000000-0000-0000-0000-000000000002","code":"4821","expiresAt":"2099-01-01T00:00:00Z"}"#
      ),
      raw(#"{"state":"pending","expiresAt":"2099-01-01T00:00:00Z","managementExpiresAt":null}"#),
      raw(
        #"{"state":"approved","expiresAt":"2099-01-01T00:00:00Z","managementExpiresAt":"2099-01-01T00:10:00Z"}"#
      ),
    ])
    let client = api(transport)
    let started = try await client.requestRemoteUnlock()
    #expect(started.code == "4821")
    let waiting = try await client.remoteUnlockStatus(id: started.id)
    #expect(!waiting.isFinished && !waiting.unlocked)
    #expect(waiting.text.hasPrefix("Waiting for confirmation"))
    let approved = try await client.remoteUnlockStatus(id: started.id)
    #expect(approved.unlocked)
    #expect(
      TVRemoteUnlockStatus(state: "denied", expiresAt: "x", managementExpiresAt: nil).isFinished)
    let paths = await transport.requests.map { $0.url?.path ?? "" }
    #expect(paths[0] == "/api/v1/management/remote-unlock")
    #expect(paths[1] == "/api/v1/management/remote-unlock/\(started.id.uuidString.lowercased())")
  }

  @Test func powerSettingsCheckWakeOnLANAndPowerNowSaysWhatHappens() throws {
    let power = TVServerPower(
      available: true, mode: "sleep", idleMinutes: 30, awakeFrom: nil, awakeUntil: nil,
      wakeSupport: "pumbg", hosting: "linuxPackage", network: "wired", wakeOn: "g",
      sleepKind: "deep")
    let check = try #require(TVPowerRules.wakeCheck(power))
    #expect(check.contains { $0.title == "Wake-on-LAN is on" && $0.state == .ok })
    #expect(!TVPowerRules.wakeCheckFooter.contains("BTV"))
    #expect(TVPowerRules.wakeCheck(power, mode: "off") == nil)
    var draft = power
    draft.awakeFrom = "07:00"
    draft.awakeUntil = "07:00"
    #expect(throws: TVPowerRules.Problem.sameAwakeTimes) {
      try TVPowerRules.payload(for: draft, awakeHours: true, server: power)
    }
    #expect(TVPowerNowText.known(["sleep", "explode", "stop"]) == ["sleep", "stop"])
    #expect(TVPowerNowText.title("shutdown") == "Turn Off Now")
    #expect(TVPowerNowText.isOffered(by: ["power-now-v1"]))
  }

  @Test func screenTimeLimitsReadNaturally() {
    #expect(TVScreenTimeAdminText.minutes(45) == "45 min")
    #expect(TVScreenTimeAdminText.minutes(120) == "2 h")
    #expect(TVScreenTimeAdminText.minutes(150) == "2 h 30 min")
    #expect(TVAdminPermissions(role: "admin", accessMode: nil).administrator)
    #expect(!TVAdminPermissions(role: "admin", accessMode: nil).owner)
    #expect(!TVAdminPermissions(role: "user", accessMode: nil).administrator)
  }

  // MARK: Helpers

  private func api(_ transport: TVAdminTestTransport) -> TVAPIClient {
    let connection = TVStoredConnection(
      serverID: UUID(), name: "Synthetic server",
      baseURL: URL(string: "https://fixture.invalid:43111")!, fingerprint: fingerprint,
      deviceToken: String(repeating: "D", count: 43), deviceSessionID: UUID())
    let session = TVProfileSession(
      user: TVUser(id: UUID(), username: "Owner", role: "owner"),
      sessionId: UUID(), token: String(repeating: "P", count: 43),
      expiresAt: "2099-01-01T00:00:00Z")
    return TVAPIClient(connection: connection, session: session, transport: transport)
  }
  private func raw(_ text: String) -> TVHTTPResponse {
    TVHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8),
      fingerprint: fingerprint)
  }
  private func problem(_ status: Int, _ code: String) -> TVHTTPResponse {
    TVHTTPResponse(
      statusCode: status, headers: ["Content-Type": "application/json"],
      body: Data(#"{"code":"\#(code)","message":"Synthetic refusal."}"#.utf8),
      fingerprint: fingerprint)
  }

  @Test func serverUpdateShowsTheStepAndPercentageWhileItInstalls() throws {
    let older = try updateStatus()
    #expect(older.isBusy)
    #expect(older.progressPercent == nil)
    #expect(UpdateProgress.fraction(older, reconnecting: false) == nil)
    #expect(
      UpdateProgress.text(older, reconnecting: false)
        == "Installing 2.25.0 (179)… The server restarts by itself.")

    let downloading = try updateStatus(#","progressPercent":42,"phase":"downloading""#)
    #expect(UpdateProgress.percent(downloading, reconnecting: false) == 42)
    #expect(UpdateProgress.fraction(downloading, reconnecting: false) == 0.42)
    #expect(UpdateProgress.text(downloading, reconnecting: false) == "Downloading server update…")
    // While the server restarts it does not answer; the page waits instead of showing an error.
    #expect(UpdateProgress.percent(downloading, reconnecting: true) == 95)
    #expect(
      UpdateProgress.text(downloading, reconnecting: true) == "Waiting for server to restart…")

    var odd = downloading
    odd.progressPercent = 140
    #expect(UpdateProgress.percent(odd, reconnecting: false) == 100)
    odd.progressPercent = -3
    #expect(UpdateProgress.percent(odd, reconnecting: false) == 0)

    var preparing = downloading
    preparing.phase = "starting"
    #expect(UpdateProgress.text(preparing, reconnecting: false) == "Preparing server update…")
    let check = TVServerUpdateStatus(
      available: true, installed: "2.24.0 (178)", newest: nil, updateAvailable: false,
      state: "checking", checkedAt: nil, message: nil, progressPercent: 10, phase: "starting")
    #expect(UpdateProgress.text(check, reconnecting: false) == "Starting update check…")
    let idle = TVServerUpdateStatus(
      available: true, installed: "2.25.0 (179)", newest: nil, updateAvailable: false,
      state: "idle", checkedAt: nil, message: nil)
    #expect(!idle.isBusy)
  }

  private typealias UpdateProgress = TVServerUpdateProgress

  /// A server installing 2.25.0; `extra` adds fields, as a newer server sends them.
  private func updateStatus(_ extra: String = "") throws -> TVServerUpdateStatus {
    let json =
      #"{"available":true,"installed":"2.24.0 (178)","newest":"2.25.0 (179)","#
      + #""updateAvailable":true,"state":"installing","checkedAt":null,"message":null"#
      + extra + "}"
    return try JSONDecoder().decode(TVServerUpdateStatus.self, from: Data(json.utf8))
  }
}

private actor TVAdminTestTransport: TVHTTPTransport {
  private var responses: [TVHTTPResponse]
  private(set) var requests: [URLRequest] = []
  init(responses: [TVHTTPResponse]) { self.responses = responses }
  func execute(_ request: URLRequest, trust: TVTrustMode) async throws -> TVHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw TVCoreError.invalidResponse }
    return responses.removeFirst()
  }
}

/// Chapters and scene notes in the Apple TV player. Invented times only.
@Suite struct TVChaptersAndNotesTests {
  private let chapters = [
    TVPlaybackChapter(
      index: 0, title: "Opening", timeOffsetMilliseconds: 0, durationMilliseconds: 60_000),
    TVPlaybackChapter(
      index: 1, title: "Middle", timeOffsetMilliseconds: 60_000, durationMilliseconds: 60_000),
    TVPlaybackChapter(
      index: 2, title: "End", timeOffsetMilliseconds: 150_000, durationMilliseconds: 50_000),
  ]

  @Test func theCurrentChapterAndItsMarks() {
    #expect(TVChapterPolicy.current(chapters, position: 90_000)?.title == "Middle")
    #expect(TVChapterPolicy.current(chapters, position: 0)?.title == "Opening")
    #expect(TVChapterPolicy.markers(chapters, duration: 200_000) == [0.3, 0.75])
    #expect(TVChapterPolicy.markers(Array(chapters.prefix(1)), duration: 200_000).isEmpty)
  }

  @Test func aSceneNoteShowsAtItsMoment() {
    let note = TVSceneNote(
      id: UUID(), mediaId: UUID(), startMilliseconds: 30_000, endMilliseconds: nil,
      text: "Invented line", revision: 1)
    #expect(TVSceneNotePolicy.cue([note], position: 33_000)?.text == "Invented line")
    #expect(TVSceneNotePolicy.cue([note], position: 40_000) == nil)
  }
}
