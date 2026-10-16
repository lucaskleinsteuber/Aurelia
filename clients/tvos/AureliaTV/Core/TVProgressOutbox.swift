import Foundation

struct TVProgressScope: Codable, Hashable, Sendable {
  let serverID: UUID
  let profileID: UUID
  let fingerprint: String

  init(connection: TVStoredConnection, session: TVProfileSession) {
    serverID = connection.serverID
    profileID = session.user.id
    fingerprint = connection.fingerprint.uppercased()
  }

  init(serverID: UUID, profileID: UUID, fingerprint: String) {
    self.serverID = serverID
    self.profileID = profileID
    self.fingerprint = fingerprint.uppercased()
  }
}

struct TVProgressSnapshot: Codable, Equatable, Sendable {
  let id: UUID
  let position: Int64
  let duration: Int64
  let finished: Bool

  init(position: Int64, duration: Int64, finished: Bool, id: UUID = UUID()) {
    self.id = id
    self.position = position
    self.duration = duration
    self.finished = finished
  }

  var isValid: Bool {
    position >= 0 && duration > 0 && position <= duration
      && position <= 31_536_000_000 && duration <= 31_536_000_000
  }
}

struct TVProgressMutation: Codable, Equatable, Sendable {
  let mediaID: UUID
  let mutationID: UUID
  let expectedRevision: Int64
  let snapshot: TVProgressSnapshot
}

protocol TVProgressClient: Sendable {
  func readProgress(mediaID: UUID) async throws -> TVPlaybackProgress
  func sendProgress(_ mutation: TVProgressMutation) async throws -> TVPlaybackProgress
}

extension TVAPIClient: TVProgressClient {
  func readProgress(mediaID: UUID) async throws -> TVPlaybackProgress {
    try await progress(mediaID: mediaID)
  }

  func sendProgress(_ mutation: TVProgressMutation) async throws -> TVPlaybackProgress {
    try await saveProgress(
      mediaID: mutation.mediaID, position: mutation.snapshot.position,
      duration: mutation.snapshot.duration, finished: mutation.snapshot.finished,
      expectedRevision: mutation.expectedRevision, mutationID: mutation.mutationID)
  }
}

enum TVProgressSaveState: String, Codable, Sendable {
  case pending, conflict, accessDenied, unavailable
}

private struct TVProgressEntry: Codable, Sendable {
  let scope: TVProgressScope
  let mediaID: UUID
  var latest: TVProgressSnapshot
  var revision: Int64?
  var mutation: TVProgressMutation?
  var state: TVProgressSaveState = .pending
}

/// Only identifiers, positions and concurrency tokens are persisted. A write
/// with an uncertain result retains its exact mutation ID, revision and body.
/// Device/profile credentials and media locations never enter this file.
actor TVProgressOutbox {
  static let shared = TVProgressOutbox(storageURL: defaultStorageURL())
  static let capacity = 256
  static let maximumBytes = 512 * 1_024

  private let storageURL: URL?
  private var entries: [TVProgressEntry] = []
  private var activeScope: TVProgressScope?
  private var activeSessionID: UUID?
  private var client: (any TVProgressClient)?
  private var authenticationFailure: (@Sendable (TVCoreError) async -> Void)?
  private var worker: Task<Void, Never>?
  private var generation = UUID()
  private var readFailed = false
  private var knownRevisions: [String: Int64] = [:]
  private(set) var storageFailed = false

  init(storageURL: URL? = nil) {
    self.storageURL = storageURL
    guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }
    do {
      let metadata = try storageURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
        (metadata.fileSize ?? .max) <= Self.maximumBytes
      else { throw CocoaError(.fileReadCorruptFile) }
      let saved = try JSONDecoder().decode(
        [TVProgressEntry].self, from: Data(contentsOf: storageURL))
      guard saved.count <= Self.capacity,
        saved.allSatisfy({ entry in
          entry.latest.isValid && (entry.revision.map { $0 >= 0 } ?? true)
            && (entry.mutation.map {
              $0.mediaID == entry.mediaID && $0.expectedRevision >= 0 && $0.snapshot.isValid
            } ?? true)
        }),
        Set(
          saved.map {
            "\($0.scope.serverID):\($0.scope.profileID):\($0.scope.fingerprint):\($0.mediaID)"
          }
        ).count == saved.count
      else { throw CocoaError(.fileReadCorruptFile) }
      entries = saved
    } catch {
      // Preserve an unreadable queue for recovery instead of replacing it.
      readFailed = true
      storageFailed = true
    }
  }

  func activate(
    scope: TVProgressScope, client: any TVProgressClient, sessionID: UUID? = nil,
    onAuthenticationFailure: (@Sendable (TVCoreError) async -> Void)? = nil
  ) {
    deactivate()
    activeScope = scope
    activeSessionID = sessionID
    self.client = client
    authenticationFailure = onAuthenticationFailure
    for index in entries.indices where entries[index].scope == scope {
      if entries[index].state == .accessDenied { entries[index].state = .pending }
    }
    kick()
  }

  func deactivate() {
    generation = UUID()
    worker?.cancel()
    worker = nil
    client = nil
    activeScope = nil
    activeSessionID = nil
    authenticationFailure = nil
    knownRevisions.removeAll()
  }

  func noteBaseline(scope: TVProgressScope, progress: TVPlaybackProgress, sessionID: UUID? = nil) {
    guard acceptsSnapshot(scope: scope, sessionID: sessionID), progress.revision >= 0 else {
      return
    }
    let key = revisionKey(scope: scope, mediaID: progress.mediaId)
    knownRevisions[key] = max(knownRevisions[key] ?? 0, progress.revision)
    guard
      let index = entries.firstIndex(where: { $0.scope == scope && $0.mediaID == progress.mediaId })
    else { return }
    if entries[index].mutation == nil, entries[index].revision == nil {
      entries[index].revision = progress.revision
      _ = persist()
    }
  }

  @discardableResult
  func enqueue(
    scope: TVProgressScope, mediaID: UUID, snapshot: TVProgressSnapshot, baselineRevision: Int64?,
    sessionID: UUID? = nil
  ) -> Bool {
    guard acceptsSnapshot(scope: scope, sessionID: sessionID), !readFailed, snapshot.isValid,
      baselineRevision.map({ $0 >= 0 }) ?? true
    else {
      return false
    }
    if let index = entries.firstIndex(where: { $0.scope == scope && $0.mediaID == mediaID }) {
      entries[index].latest = snapshot
      // The already-dispatched mutation is intentionally not replaced.
    } else {
      guard entries.count < Self.capacity else { return false }
      let known = knownRevisions[revisionKey(scope: scope, mediaID: mediaID)]
      let revision = [known, baselineRevision].compactMap { $0 }.max()
      entries.append(
        TVProgressEntry(scope: scope, mediaID: mediaID, latest: snapshot, revision: revision))
    }
    guard persist() else { return false }
    kick()
    return true
  }

  func state(scope: TVProgressScope, mediaID: UUID) -> TVProgressSaveState? {
    entries.first { $0.scope == scope && $0.mediaID == mediaID }?.state
  }

  func count(scope: TVProgressScope) -> Int { entries.filter { $0.scope == scope }.count }

  // Read-only diagnostic for deterministic logic tests; contains no secrets.
  func pendingMutation(scope: TVProgressScope, mediaID: UUID) -> TVProgressMutation? {
    entries.first { $0.scope == scope && $0.mediaID == mediaID }?.mutation
  }

  private func kick() {
    guard worker == nil, !readFailed, client != nil, let activeScope,
      entries.contains(where: { $0.scope == activeScope && $0.state == .pending })
    else { return }
    let operation = generation
    worker = Task { await work(generation: operation) }
  }

  private func work(generation operation: UUID) async {
    var failures = 0
    while !Task.isCancelled, operation == generation, let scope = activeScope, let client,
      let index = entries.firstIndex(where: { $0.scope == scope && $0.state == .pending })
    {
      let mediaID = entries[index].mediaID
      do {
        if entries[index].mutation == nil {
          var revision = entries[index].revision
          if revision == nil {
            let current = try await client.readProgress(mediaID: mediaID)
            guard operation == generation, !Task.isCancelled else { return }
            guard current.mediaId == mediaID, current.revision >= 0 else {
              throw TVCoreError.invalidResponse
            }
            revision = current.revision
          }
          guard let index = entryIndex(scope: scope, mediaID: mediaID), let revision else {
            continue
          }
          entries[index].mutation = TVProgressMutation(
            mediaID: mediaID, mutationID: UUID(), expectedRevision: revision,
            snapshot: entries[index].latest)
          // Durability precedes the first network attempt.
          guard persist() else { break }
        }
        guard let index = entryIndex(scope: scope, mediaID: mediaID),
          let mutation = entries[index].mutation
        else { continue }
        let result = try await client.sendProgress(mutation)
        guard operation == generation, !Task.isCancelled else { return }
        guard result.mediaId == mediaID, result.revision > mutation.expectedRevision,
          result.lastMutationId == mutation.mutationID
        else { throw TVCoreError.invalidResponse }
        guard let index = entryIndex(scope: scope, mediaID: mediaID) else { continue }
        knownRevisions[revisionKey(scope: scope, mediaID: mediaID)] = result.revision
        if entries[index].latest.id == mutation.snapshot.id {
          entries.remove(at: index)
        } else {
          entries[index].mutation = nil
          entries[index].revision = result.revision
        }
        guard persist() else { break }
        failures = 0
      } catch {
        guard operation == generation, !Task.isCancelled else { return }
        guard let index = entryIndex(scope: scope, mediaID: mediaID) else { continue }
        if let api = error as? TVCoreError, api.isConflict {
          entries[index].state = .conflict
          _ = persist()
          continue
        }
        if let api = error as? TVCoreError, api.isAuthenticationFailure {
          entries[index].state = .accessDenied
          _ = persist()
          let callback = authenticationFailure
          deactivate()
          await callback?(api)
          return
        }
        if let api = error as? TVCoreError,
          let status = api.statusCode, (400..<500).contains(status), !api.isTransient
        {
          entries[index].state = .unavailable
          _ = persist()
          continue
        }
        failures += 1
        let providerDelay = (error as? TVCoreError)?.retryAfter ?? 0
        let delay = max(providerDelay, min(30, pow(2, Double(min(failures, 5)))))
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      }
    }
    if operation == generation { worker = nil }
  }

  private func acceptsSnapshot(scope: TVProgressScope, sessionID: UUID?) -> Bool {
    // A closing player may retain its last sample while another profile is
    // active. It must not replace samples from a newer session of its own
    // profile.
    guard activeScope == scope, let activeSessionID, let sessionID else { return true }
    return activeSessionID == sessionID
  }

  private func entryIndex(scope: TVProgressScope, mediaID: UUID) -> Int? {
    entries.firstIndex { $0.scope == scope && $0.mediaID == mediaID }
  }

  private func revisionKey(scope: TVProgressScope, mediaID: UUID) -> String {
    "\(scope.serverID):\(scope.profileID):\(scope.fingerprint):\(mediaID)"
  }

  private func persist() -> Bool {
    guard !readFailed else { return false }
    guard let storageURL else { return true }
    do {
      let data = try JSONEncoder().encode(entries)
      guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
      let directory = storageURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let directoryInfo = try directory.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard directoryInfo.isDirectory == true, directoryInfo.isSymbolicLink != true else {
        throw CocoaError(.fileWriteNoPermission)
      }
      try data.write(to: storageURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
      storageFailed = false
      return true
    } catch {
      storageFailed = true
      return false
    }
  }

  private static func defaultStorageURL() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("AureliaTV", isDirectory: true)
      .appendingPathComponent("ProgressOutbox.json")
  }
}
