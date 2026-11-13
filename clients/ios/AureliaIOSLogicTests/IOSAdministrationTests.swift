import Foundation
import Testing

@Suite("iOS server administration")
struct IOSAdministrationTests {
  private let serverID = UUID(uuidString: "74000000-0000-0000-0000-000000000001")!
  private let profileID = UUID(uuidString: "74000000-0000-0000-0000-000000000002")!
  private let fingerprint = String(repeating: "B", count: 64)

  // MARK: Approvals

  @Test func protectedChangeGetsOneApprovalForExactlyThisRequestAndIsSentOnceMore() async throws {
    let transport = IOSAdminTestTransport(responses: [
      problem(403, "approval_required"),
      try json(["token": String(repeating: "T", count: 43), "expiresAt": "2099-01-01T00:00:00Z"]),
      IOSHTTPResponse(statusCode: 204, headers: [:], body: Data(), fingerprint: fingerprint),
    ])
    let library = UUID(uuidString: "74000000-0000-0000-0000-0000000000aa")!
    try await api(transport).removeLibrary(id: library)

    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(requests[0].httpMethod == "DELETE")
    #expect(requests[0].value(forHTTPHeaderField: "X-Aurelia-Approval") == nil)
    #expect(requests[1].url?.path == "/api/v1/management/approval")
    let confirmation = try JSONDecoder().decode(
      [String: String].self, from: requests[1].httpBody ?? Data())
    #expect(confirmation["action"] == "DELETE /api/v1/libraries/\(library.uuidString.lowercased())")
    #expect(confirmation["payloadHash"] == IOSApprovalExecutor.payloadHash(nil))
    #expect(requests[2].value(forHTTPHeaderField: "X-Aurelia-Approval") == String(repeating: "T", count: 43))
    #expect(requests[2].httpMethod == "DELETE")
  }

  @Test func approvalCoversQueryAndBody() throws {
    let url = URL(string: "https://fixture.invalid:43111/api/v1/libraries/folders?path=/Volumes/My%20Drive")!
    #expect(try IOSApprovalExecutor.action(method: "GET", url: url)
      == "GET /api/v1/libraries/folders?path=/Volumes/My%20Drive")
    #expect(IOSApprovalExecutor.payloadHash(Data())
      == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(IOSApprovalExecutor.payloadHash(Data("{}".utf8))
      == "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
  }

  @Test func lockedManagementIsReportedWithoutRetrying() async throws {
    let transport = IOSAdminTestTransport(responses: [problem(403, "management_locked")])
    await #expect {
      _ = try await api(transport).serverSettings()
    } throws: { error in
      (error as? IOSCoreError)?.isManagementLocked == true
    }
    #expect(await transport.requests.count == 1)
  }

  @Test func aSecondRefusalAfterTheApprovalIsShownNotRetriedAgain() async throws {
    let transport = IOSAdminTestTransport(responses: [
      problem(403, "approval_required"),
      try json(["token": String(repeating: "T", count: 43), "expiresAt": "2099-01-01T00:00:00Z"]),
      problem(403, "approval_required"),
    ])
    await #expect(throws: IOSCoreError.self) {
      try await api(transport).deleteProfile(id: UUID())
    }
    #expect(await transport.requests.count == 3)
  }

  @Test func unlockSendsThePasswordOnceAndReadsTheExpiry() async throws {
    let transport = IOSAdminTestTransport(responses: [
      try json(["expiresAt": "2099-01-01T00:10:00Z"])
    ])
    let expiry = try await api(transport).unlockManagement(password: "synthetic-password")
    #expect(expiry == IOSServerDate.parse("2099-01-01T00:10:00Z"))
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/api/v1/management/unlock")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "P", count: 43))
    await #expect(throws: IOSCoreError.self) {
      _ = try await api(transport).unlockManagement(password: "")
    }
  }

  @Test func metadataJobsAlwaysSayWhichKind() async throws {
    let job = """
      {"id":"74000000-0000-0000-0000-000000000010","libraryId":null,"mediaId":null,"state":"queued",
      "itemsTotal":0,"itemsProcessed":0,"itemsMatched":0,"itemsNeedingReview":0,"itemsFailed":0,
      "error":null,"createdAt":"2026-11-13T10:00:00Z","startedAt":null,"completedAt":null}
      """
    let transport = IOSAdminTestTransport(responses: [raw(job), raw(job)])
    _ = try await api(transport).startMetadataJob()
    _ = try await api(transport).startMetadataJob(fullRefresh: true)
    let bodies = await transport.requests.map {
      (try? JSONDecoder().decode([String: String].self, from: $0.httpBody ?? Data())) ?? [:]
    }
    #expect(bodies.map { $0["mode"] } == ["incremental", "fullRefresh"])
  }

  @Test func devicePairingCodesAreEightDigits() async throws {
    let transport = IOSAdminTestTransport(responses: [])
    await #expect(throws: IOSCoreError.invalidRequest) {
      _ = try await api(transport).lookupDevicePairing(code: "1234")
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func backupNamesNeverChangeTheAddress() {
    #expect(IOSAPIClient.isBackupName("aurelia-database-20261113T100000000Z.db"))
    #expect(!IOSAPIClient.isBackupName("../secret"))
    #expect(!IOSAPIClient.isBackupName("a/b"))
    #expect(!IOSAPIClient.isBackupName(""))
  }

  // MARK: Policy, power and permissions

  @Test func policyKeepsUnknownFieldsAndClampsNumbers() throws {
    let stored: [String: IOSJSONValue] = [
      "version": .number(3), "serverName": .string("Synthetic"), "futureSetting": .string("kept"),
      "globalStreamLimit": .number(8), "userStreamLimit": .number(2),
      "maintenanceStartHour": .number(2), "maintenanceEndHour": .number(6),
      "deviceSessionDays": .number(30), "pairingEnabled": .bool(true),
    ]
    let (draft, problem) = IOSServerPolicy.draft(
      stored: stored, numbers: ["deviceSessionDays": 9999, "globalStreamLimit": 0],
      switches: ["pairingEnabled": false])
    #expect(draft["futureSetting"] == .string("kept"))
    #expect(draft["deviceSessionDays"]?.int == 365)
    #expect(draft["globalStreamLimit"]?.int == 1)
    #expect(draft["pairingEnabled"]?.bool == false)
    #expect(problem == "Streams per profile can't be more than streams in total.")

    let same = IOSServerPolicy.draft(
      stored: stored, numbers: ["maintenanceStartHour": 4, "maintenanceEndHour": 4])
    #expect(same.problem == "Maintenance needs to start and end at different hours.")
    #expect(IOSServerPolicy.draft(stored: stored).problem == nil)
  }

  @Test func policyEncodesWholeNumbersAsIntegers() throws {
    let encoded = try JSONEncoder().encode(["deviceSessionDays": IOSJSONValue.number(30)])
    #expect(String(decoding: encoded, as: UTF8.self) == #"{"deviceSessionDays":30}"#)
    let decoded = try JSONDecoder().decode(
      [String: IOSJSONValue].self,
      from: Data(#"{"a":[1,"x",null,{"b":true}],"c":2.5}"#.utf8))
    #expect(decoded["a"] == .array([.number(1), .string("x"), .null, .object(["b": .bool(true)])]))
    #expect(decoded["c"] == .number(2.5))
  }

  @Test func powerOffersOnlyWhatTheComputerCanDo() throws {
    let linux = IOSServerPower(
      available: true, mode: "sleep", idleMinutes: 30, awakeFrom: nil, awakeUntil: nil,
      wakeOnAccess: false, wakeSupport: "pumbg", hosting: "linuxServer")
    #expect(IOSPowerRules.modes(for: linux).map(\.id) == ["off", "stop", "sleep", "shutdown"])
    #expect(IOSPowerRules.offersWakeOnAccess(linux))
    #expect(!IOSPowerRules.offersWakeOnAccess(linux, mode: "stop"))

    var mac = linux
    mac.hosting = "macApp"
    #expect(IOSPowerRules.modes(for: mac).map(\.id) == ["off", "stop"])
    #expect(!IOSPowerRules.offersWakeOnAccess(mac))

    var noCard = linux
    noCard.wakeSupport = "g"
    #expect(!IOSPowerRules.offersWakeOnAccess(noCard))
  }

  @Test func powerPayloadChecksTimesAndAsksOnlyCapableCards() throws {
    let server = IOSServerPower(
      available: true, mode: "off", idleMinutes: 30, awakeFrom: nil, awakeUntil: nil,
      wakeOnAccess: nil, wakeSupport: "ug", hosting: "linuxServer")
    var draft = server
    draft.mode = "shutdown"
    draft.wakeOnAccess = true
    draft.awakeFrom = "07:00"
    draft.awakeUntil = "23:30"
    let payload = try IOSPowerRules.payload(for: draft, awakeHours: true, server: server)
    #expect(payload.mode == "shutdown")
    #expect(payload.awakeFrom == "07:00")
    #expect(payload.wakeOnAccess == true)
    #expect(payload.afterSleepTimer)

    #expect(throws: IOSPowerRules.Problem.awakeTimes) {
      var broken = draft
      broken.awakeUntil = "25:00"
      _ = try IOSPowerRules.payload(for: broken, awakeHours: true, server: server)
    }
    #expect(throws: IOSPowerRules.Problem.sameAwakeTimes) {
      var broken = draft
      broken.awakeUntil = "07:00"
      _ = try IOSPowerRules.payload(for: broken, awakeHours: true, server: server)
    }
    #expect(throws: IOSPowerRules.Problem.idleMinutes) {
      var broken = draft
      broken.idleMinutes = 2
      _ = try IOSPowerRules.payload(for: broken, awakeHours: false, server: server)
    }
    var withoutCard = server
    withoutCard.wakeSupport = nil
    let plain = try IOSPowerRules.payload(for: draft, awakeHours: false, server: withoutCard)
    #expect(plain.wakeOnAccess == nil)
    #expect(plain.awakeFrom == nil)

    var mac = server
    mac.hosting = "macApp"
    #expect(throws: IOSPowerRules.Problem.mode) {
      _ = try IOSPowerRules.payload(for: draft, awakeHours: false, server: mac)
    }
  }

  @Test func permissionsFollowTheServer() {
    #expect(IOSAdminPermissions(role: "owner", accessMode: "selectedTitles")
      == .init(role: "owner", accessMode: nil))
    let owner = IOSAdminPermissions(role: "owner", accessMode: nil)
    #expect(owner.owner && owner.administrator && owner.storage)
    let admin = IOSAdminPermissions(role: "admin", accessMode: "entireLibrary")
    #expect(!admin.owner && admin.administrator && admin.storage)
    let limited = IOSAdminPermissions(role: "admin", accessMode: "selectedTitles")
    #expect(limited.administrator && !limited.storage)
    let viewer = IOSAdminPermissions(role: "user", accessMode: nil)
    #expect(!viewer.administrator && !viewer.storage)
  }

  @Test func profileRulesMatchTheServer() {
    #expect(!IOSProfileRules.canSave(role: "admin", protection: false, newPIN: "", hasPIN: true))
    #expect(IOSProfileRules.canSave(role: "user", protection: false, newPIN: "", hasPIN: false))
    #expect(!IOSProfileRules.canSave(role: "user", protection: true, newPIN: "", hasPIN: false))
    #expect(IOSProfileRules.canSave(role: "user", protection: true, newPIN: "4821", hasPIN: false))
    #expect(!IOSProfileRules.canSave(role: "user", protection: true, newPIN: "48a1", hasPIN: false))
    #expect(IOSProfileRules.isValidName("Mia"))
    #expect(IOSProfileRules.isValidName("A"))
    #expect(!IOSProfileRules.isValidName("   "))
    #expect(!IOSProfileRules.isValidName(String(repeating: "x", count: 65)))
  }

  // MARK: Reading the server's answers

  @Test func statesFromANewerServerAreShownNotRefused() throws {
    let library = try JSONDecoder().decode(
      IOSLibrarySummary.self,
      from: Data(
        """
        {"id":"74000000-0000-0000-0000-000000000020","name":"Films","path":"/Volumes/Media/Films",
        "kind":"futureKind","availability":"available","createdAt":"2026-11-13T10:00:00Z",
        "lastScanStartedAt":null,"lastScanCompletedAt":null,"lastError":null,"health":"healthy",
        "somethingNew":42}
        """.utf8))
    #expect(library.kindTitle == "Automatic")
    #expect(library.availabilityTitle == "Available")

    let health = try JSONDecoder().decode(
      IOSServerHealth.self,
      from: Data(
        """
        {"uptimeSeconds":7300,"freeDiskBytes":1000,"databaseBytes":2000,"scrubPreviewTitleCount":1,
        "scrubPreviewBytes":10,"scrubPreviewPendingCount":0,"activeLiveConversions":0,"activeStreams":1,
        "offlineMediaCount":0,"lastScan":null,
        "backgroundJobs":{"activeScans":0,"activeMetadataJobs":0,"activeScrubPreviewJobs":0},
        "recentIssues":[{"at":"2026-11-13T10:00:00Z","code":"invalid_credentials","severity":"warning","status":401}],
        "backup":null,"performance":{"later":true}}
        """.utf8))
    #expect(IOSAdminText.uptime(health.uptimeSeconds) == "2 h 1 min")
    #expect(IOSAdminText.event(health.recentIssues[0].code) == "Wrong Server Password")
  }

  @Test func metadataJobSummariesReadLikeTheMac() throws {
    func job(_ state: String, matched: Int = 0, review: Int = 0, failed: Int = 0) throws
      -> IOSMetadataJob
    {
      try JSONDecoder().decode(
        IOSMetadataJob.self,
        from: Data(
          """
          {"id":"74000000-0000-0000-0000-000000000030","libraryId":null,"mediaId":null,"state":"\(state)",
          "itemsTotal":25,"itemsProcessed":10,"itemsMatched":\(matched),"itemsNeedingReview":\(review),
          "itemsFailed":\(failed),"error":null,"createdAt":"2026-11-13T10:00:00Z","startedAt":null,
          "completedAt":null}
          """.utf8))
    }
    #expect(try job("completed", matched: 23, review: 2).summary == "Done · 23 matched, 2 need review")
    #expect(try job("completed").summary == "Done · 25 titles checked")
    #expect(try job("running").summary == "10 of 25 titles checked")
    #expect(try job("running").progress == 0.4)
  }

  // MARK: Import preview and Wake-on-LAN

  @Test func importChoicesAndChangesFollowTheBrowser() throws {
    func item(_ path: String, folder: Bool = false) -> IOSImportPreviewItem {
      IOSImportPreviewItem(
        relativePath: path, title: path, kind: nil, parentRelativePath: nil, seasonNumber: nil,
        episodeNumber: nil, category: nil, status: "pending", reason: "", isDirectory: folder)
    }
    let file = item("Show/extra.mkv")
    let folder = item("Show", folder: true)
    #expect(IOSImportRules.choices(for: [file]).map(\.id) == ["movie", "episode", "extra", "trailer", "ignore"])
    #expect(IOSImportRules.choices(for: [folder]).map(\.id) == ["movie", "series", "extra", "trailer", "ignore"])
    #expect(!IOSImportRules.choices(for: [file, item("b.mkv")]).map(\.id).contains("episode"))

    let show = IOSImportPreviewTarget(relativePath: "Show", title: "Show", kind: "series", seasonNumbers: [1])
    var form = IOSImportRules.Form()
    form.choice = "episode"
    #expect(throws: IOSImportRules.Problem.parent) {
      _ = try IOSImportRules.changes(items: [file], form: form, targets: [show])
    }
    form.parentPath = "Show"
    form.season = 2
    form.episode = 5
    let changes = try IOSImportRules.changes(items: [file], form: form, targets: [show])
    #expect(changes == [
      IOSImportAssignment(
        relativePath: "Show/extra.mkv", isDirectory: false, kind: "episode",
        parentRelativePath: "Show", seasonNumber: 2, episodeNumber: 5)
    ])
    form.episode = 0
    #expect(throws: IOSImportRules.Problem.episodeNumber) {
      _ = try IOSImportRules.changes(items: [file], form: form, targets: [show])
    }
    var ignore = IOSImportRules.Form()
    ignore.choice = "ignore"
    let ignored = try IOSImportRules.changes(items: [folder], form: ignore, targets: [])
    #expect(ignored.first?.kind == nil)
    let encoded = String(decoding: try JSONEncoder().encode(ignored[0]), as: UTF8.self)
    #expect(!encoded.contains("\"kind\""))
  }

  @Test func wakeStatusSaysWhetherWakeServerCanWork() throws {
    let defaults = try #require(UserDefaults(suiteName: "aurelia.ios.admin.wake.\(UUID().uuidString)"))
    let server = UUID()
    #expect(IOSWakeOnLan.status(for: server, defaults: defaults).summary == "Not reported by the server")
    let info = IOSServerInfo(
      serverId: server, name: "Synthetic", version: "2.13.0", isSetup: true, lanAccessEnabled: true,
      lanHttpsPort: 43111, publicKeyFingerprint: fingerprint, displayFingerprint: nil,
      capabilities: [], wakeOnLanAddresses: ["02:00:5e:10:00:01"], hosting: "linuxServer")
    IOSWakeOnLan.remember(serverID: server, info: info, hosts: [], defaults: defaults)
    #expect(IOSWakeOnLan.status(for: server, defaults: defaults).summary == "Connect once to learn its address")
    IOSWakeOnLan.remember(serverID: server, info: info, hosts: ["192.0.2.10"], defaults: defaults)
    let ready = IOSWakeOnLan.status(for: server, defaults: defaults)
    #expect(ready.canWake)
    #expect(ready.summary == "Ready · 1 network card")
    var hosted = info
    hosted.hosting = "macApp"
    IOSWakeOnLan.remember(serverID: server, info: hosted, hosts: ["192.0.2.10"], defaults: defaults)
    let app = IOSWakeOnLan.status(for: server, defaults: defaults)
    #expect(!app.canWake)
    #expect(app.summary == "Starts with Aurelia on the Mac")
    #expect(IOSWakeOnLan.Plan.totalSeconds == 120 && IOSWakeOnLan.Plan.resendSeconds == 10)
  }

  @Test func wakeLooksUpTheAddressBehindAName() {
    #expect(IOSWakeOnLan.resolveIPv4("localhost").contains("127.0.0.1"))
    #expect(IOSWakeOnLan.resolveIPv4("192.0.2.10").isEmpty)
    #expect(IOSWakeOnLan.resolveIPv4("").isEmpty)
    #expect(IOSWakeOnLan.resolveIPv4("fe80::1").isEmpty)
  }

  @Test func performanceReadsTheServerMeasurements() throws {
    let performance = try JSONDecoder().decode(
      IOSServerPerformance.self,
      from: Data(
        """
        {"since":"2026-11-13T08:00:00Z","slowRequestMilliseconds":500,"slowQueryMilliseconds":100,
        "requests":42,"p95Milliseconds":131.5,
        "endpoints":[{"method":"GET","route":"/api/v1/catalog/items/{mediaId:guid}","count":40,"errors":0,
        "slowCount":0,"medianMilliseconds":12.4,"p95Milliseconds":19.9,"maxMilliseconds":22,"queriesPerRequest":13}],
        "slowQueries":[{"at":"2026-11-13T08:01:00Z","milliseconds":250.5,"kind":"SELECT","statement":"SELECT ?",
        "endpoint":"GET /api/v1/home","warmUp":true}],"later":1}
        """.utf8))
    #expect(performance.endpoints.first?.queriesPerRequest == 13)
    #expect(IOSPerformanceText.route(performance.endpoints[0].route) == "/catalog/items/‹mediaId›")
    #expect(IOSPerformanceText.route("/web/{**file}") == "/web/‹file›")
    #expect(IOSPerformanceText.duration(12.4) == "12 ms")
    #expect(IOSPerformanceText.duration(1460) == "1.5 s")
  }

  // MARK: Helpers

  private func api(_ transport: IOSAdminTestTransport) -> IOSAPIClient {
    let connection = IOSStoredConnection(
      serverID: serverID, name: "Synthetic server",
      baseURL: URL(string: "https://fixture.invalid:43111")!, fingerprint: fingerprint,
      deviceToken: String(repeating: "D", count: 43), deviceSessionID: UUID())
    let session = IOSProfileSession(
      user: IOSUser(id: profileID, username: "Owner", role: "owner"),
      sessionId: UUID(), token: String(repeating: "P", count: 43),
      expiresAt: "2099-01-01T00:00:00Z")
    return IOSAPIClient(connection: connection, session: session, transport: transport)
  }
  private func json(_ value: [String: String]) throws -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try JSONEncoder().encode(value), fingerprint: fingerprint)
  }
  private func raw(_ text: String) -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8),
      fingerprint: fingerprint)
  }
  private func problem(_ status: Int, _ code: String) -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: status, headers: ["Content-Type": "application/json"],
      body: Data(#"{"code":"\#(code)","message":"Synthetic refusal."}"#.utf8),
      fingerprint: fingerprint)
  }
}

private actor IOSAdminTestTransport: IOSHTTPTransport {
  private var responses: [IOSHTTPResponse]
  private(set) var requests: [URLRequest] = []
  init(responses: [IOSHTTPResponse]) { self.responses = responses }
  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw IOSCoreError.invalidResponse }
    return responses.removeFirst()
  }
}
