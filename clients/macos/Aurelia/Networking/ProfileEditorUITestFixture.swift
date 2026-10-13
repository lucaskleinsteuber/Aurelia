#if DEBUG
  import Foundation

  // Isolated visual fixtures only. Real profile authorization is covered by server tests.
  @MainActor enum ProfileEditorUITestFixture {
    static var enabled: Bool {
      ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] == "profile-management"
    }

    private static let ownerID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
    private static let viewerID = UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
    private static var unlockCount = 0
    private static var profiles: [UUID: ProfileEditorResponse] = [
      ownerID: ProfileEditorResponse(
        user: UserSummary(
          id: ownerID, username: "Owner", role: .owner, createdAt: "2026-01-01T00:00:00Z",
          accessMode: .entireLibrary, profileRevision: 1), isEnabled: true,
        access: ProfileTitleAccess(mode: .entireLibrary, titleIds: [], revision: 1), revision: 1),
      viewerID: ProfileEditorResponse(
        user: UserSummary(
          id: viewerID, username: "Viewer", role: .user, createdAt: "2026-01-01T00:00:00Z",
          accessMode: .legacyLibraries, profileRevision: 1), isEnabled: true,
        access: ProfileTitleAccess(mode: .legacyLibraries, titleIds: [], revision: 1), revision: 1),
    ]

    static func response(path: String, method: String, body: Data?) throws -> Data? {
      if path == "/api/v1/management/unlock" {
        struct Unlock: Decodable { let password: String }
        let request = try JSONDecoder().decode(Unlock.self, from: body ?? Data())
        guard request.password == "synthetic-server-password" else {
          throw APIClientError.serverRejected(
            code: "invalid_server_password", message: "The Server Password is incorrect.")
        }
        unlockCount += 1
        let seconds =
          unlockCount == 1
          ? Double(
            ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MANAGEMENT_SECONDS"] ?? "600")
            ?? 600
          : 600
        let formatter = ISO8601DateFormatter()
        return try JSONSerialization.data(withJSONObject: [
          "expiresAt": formatter.string(from: Date().addingTimeInterval(seconds))
        ])
      }
      if path == "/api/v1/management/lock" { return Data() }
      if path == "/api/v1/server/users", method == "GET" {
        return try JSONEncoder().encode(
          profiles.values.sorted { $0.user.username < $1.user.username }.map {
            UserAccessSummary(user: $0.user, isEnabled: $0.isEnabled, libraryIds: [])
          })
      }
      if path == "/api/v1/users", method == "POST" {
        let request = try JSONDecoder().decode(ProfileCreateRequest.self, from: body ?? Data())
        if request.username == "Reject Profile" {
          throw APIClientError.serverRejected(
            code: "synthetic_save_failure",
            message: "The profile could not be saved. Your draft is unchanged.")
        }
        let id = UUID()
        let mode = request.role == .owner ? .entireLibrary : request.accessMode ?? .selectedTitles
        let user = UserSummary(
          id: id, username: request.username, role: request.role, createdAt: "2026-01-01T00:00:00Z",
          accessMode: mode, pinProtectionEnabled: request.pinProtectionEnabled,
          profileRevision: 1)
        profiles[id] = ProfileEditorResponse(
          user: user, isEnabled: request.isEnabled,
          access: ProfileTitleAccess(mode: mode, titleIds: request.titleIds ?? [], revision: 1),
          revision: 1)
        return try JSONEncoder().encode(user)
      }
      let components = path.split(separator: "/")
      guard components.count == 5, components[2] == "users", components[4] == "profile",
        let id = UUID(uuidString: String(components[3])), let current = profiles[id]
      else { return nil }
      if method == "GET" { return try JSONEncoder().encode(current) }
      guard method == "PUT" else { return nil }
      let request = try JSONDecoder().decode(ProfileUpdateRequest.self, from: body ?? Data())
      guard request.revision == current.revision else {
        throw APIClientError.serverRejected(
          code: "profile_conflict",
          message: "This profile changed on another device. Reopen it before saving.")
      }
      let revision = current.revision + 1
      let mode = request.role == .owner ? .entireLibrary : request.accessMode ?? current.access.mode
      let saved = ProfileEditorResponse(
        user: UserSummary(
          id: id, username: current.user.username, role: request.role,
          createdAt: current.user.createdAt, accessMode: mode,
          pinProtectionEnabled: request.pinProtectionEnabled, profileRevision: revision),
        isEnabled: request.isEnabled,
        access: ProfileTitleAccess(
          mode: mode, titleIds: request.titleIds ?? current.access.titleIds, revision: revision),
        revision: revision)
      profiles[id] = saved
      return try JSONEncoder().encode(saved)
    }
  }
#endif
