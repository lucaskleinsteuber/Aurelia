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

private struct TVProgressEntry: Codable, Equatable, Sendable {
  let scope: TVProgressScope
  let mediaID: UUID
  var latest: TVProgressSnapshot
  var revision: Int64?
  var mutation: TVProgressMutation?
  var state: TVProgressSaveState = .pending
}

/// Journal storage is injectable so tests never use the app's preferences.
protocol TVProgressJournalStore: Sendable {
  func read() throws -> Data?
  func write(_ data: Data) throws
}

final class TVDefaultsProgressJournal: TVProgressJournalStore, @unchecked Sendable {
  static let key = "aurelia.progress-journal.v1"
  private let defaults: UserDefaults
  private let key: String
  private let lock = NSLock()

  init(defaults: UserDefaults, key: String = TVDefaultsProgressJournal.key) {
    self.defaults = defaults
    self.key = key
  }

  func read() throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard let value = defaults.object(forKey: key) else { return nil }
    guard let data = value as? Data else { throw CocoaError(.fileReadCorruptFile) }
    return data
  }

  func write(_ data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    guard data.count <= TVProgressOutbox.maximumBytes else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    defaults.set(data, forKey: key)
    // The journal is deliberately small. Flush it before reporting a durable
    // enqueue, including when the app is about to enter the background.
    guard defaults.synchronize(), defaults.data(forKey: key) == data else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}

private struct TVFileProgressJournal: TVProgressJournalStore {
  let url: URL

  func read() throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let metadata = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
      (metadata.fileSize ?? .max) <= TVProgressOutbox.legacyMaximumBytes
    else { throw CocoaError(.fileReadCorruptFile) }
    return try Data(contentsOf: url)
  }

  func write(_ data: Data) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let metadata = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard metadata.isDirectory == true, metadata.isSymbolicLink != true else {
      throw CocoaError(.fileWriteNoPermission)
    }
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

private struct TVProgressJournal: Codable {
  let version: Int
  let entries: [TVProgressEntry]
  let legacyImported: Bool
}

enum TVProgressFlushResult: Equatable, Sendable {
  case saved, pending, conflict, storageFailure, inactive, cancelled
}

enum TVProgressStorageIssue: Sendable {
  case unreadable, capacity, write, migration
}

struct TVProgressOutboxChange: Sendable {
  enum Reason: Sendable { case enqueued, acknowledged, stateChanged, storageFailure }
  let reason: Reason
  let scope: TVProgressScope
  let mediaID: UUID?
  let snapshot: TVProgressSnapshot?
  let progress: TVPlaybackProgress?
  let state: TVProgressSaveState?
  let storageFailed: Bool

  /// Background reconciliation needs no acknowledgement when the server already has a newer
  /// position. The active player reports its own conflicts without blocking library browsing.
  var requiresUserAttention: Bool { storageFailed }
}

/// Only identifiers, positions and concurrency tokens enter the journal.
/// An uncertain write retains its exact mutation ID, revision and body.
actor TVProgressOutbox {
  static let shared = TVProgressOutbox(
    journal: TVDefaultsProgressJournal(defaults: .standard),
    legacyStorageURL: defaultStorageURL())
  static let capacity = 256
  static let maximumBytes = 256 * 1_024
  fileprivate static let legacyMaximumBytes = 512 * 1_024

  private let journal: (any TVProgressJournalStore)?
  private var entries: [TVProgressEntry] = []
  private var activeScope: TVProgressScope?
  private var activeSessionID: UUID?
  private var client: (any TVProgressClient)?
  private var authenticationFailure: (@Sendable (TVCoreError) async -> Void)?
  private var worker: Task<Void, Never>?
  private var generation = UUID()
  private var readFailed = false
  private var legacyImported = false
  private var knownRevisions: [String: Int64] = [:]
  /// Titles whose newer position came from another device. Their open player stops saving so
  /// it cannot overwrite that position; opening the title again starts from the server's.
  private var stoppedAfterConflict: Set<String> = []
  private var confirmedProgress: [String: TVPlaybackProgress] = [:]
  private var observers:
    [UUID: (TVProgressScope, AsyncStream<TVProgressOutboxChange>.Continuation)] = [:]
  private(set) var storageFailed = false
  private(set) var storageIssue: TVProgressStorageIssue?

  /// The default is memory-only, including all synthetic UI fixtures. The URL
  /// overload remains available for isolated legacy compatibility tests.
  init(storageURL: URL? = nil) {
    journal = storageURL.map { TVFileProgressJournal(url: $0) }
    do {
      if let data = try journal?.read() {
        let saved = try Self.decode(data, maximumBytes: Self.maximumBytes)
        entries = saved.entries
        legacyImported = saved.legacyImported
      }
    } catch {
      readFailed = true
      storageFailed = true
      storageIssue = .unreadable
    }
  }

  init(journal: any TVProgressJournalStore, legacyStorageURL: URL? = nil) {
    self.journal = journal
    do {
      if let data = try journal.read() {
        let saved = try Self.decode(data, maximumBytes: Self.maximumBytes)
        entries = saved.entries
        legacyImported = saved.legacyImported
      }
    } catch {
      readFailed = true
      storageFailed = true
      storageIssue = .unreadable
      return
    }
    guard !legacyImported, let legacyStorageURL,
      FileManager.default.fileExists(atPath: legacyStorageURL.path)
    else { return }
    do {
      let legacy = TVFileProgressJournal(url: legacyStorageURL)
      guard let data = try legacy.read() else { return }
      let saved = try Self.decode(data, maximumBytes: Self.legacyMaximumBytes)
      var merged = entries
      for entry in saved.entries {
        if let existing = merged.first(where: {
          $0.scope == entry.scope && $0.mediaID == entry.mediaID
        }) {
          // Never pick a winner between two uncertain mutations.
          guard existing == entry else { throw CocoaError(.fileReadCorruptFile) }
        } else {
          merged.append(entry)
        }
      }
      guard merged.count <= Self.capacity else { throw CocoaError(.fileWriteOutOfSpace) }
      let migrated = try Self.encode(merged, legacyImported: true)
      try journal.write(migrated)
      guard try journal.read() == migrated else { throw CocoaError(.fileWriteUnknown) }
      entries = merged
      legacyImported = true
      // A persisted receipt prevents a later import if cleanup is unavailable.
      // Removal is attempted only after a verified, readable replacement.
      try? FileManager.default.removeItem(at: legacyStorageURL)
    } catch {
      // Neither an unreadable source nor a failed replacement is discarded.
      readFailed = true
      storageFailed = true
      storageIssue = .migration
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
    // A conflict is settled in the server's favor; older builds kept such entries forever,
    // which stopped the title from saving on this Apple TV.
    let settled = entries.count
    entries.removeAll { $0.state == .conflict }
    if storageFailed || entries.count != settled { _ = persist() }
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
    // Known revisions stay: they are keyed by server, profile and title, and the app leaves and
    // returns to the foreground during playback. Forgetting them made this Apple TV's next
    // write use the player's older baseline and conflict with its own previous write.
  }

  func noteBaseline(scope: TVProgressScope, progress: TVPlaybackProgress, sessionID: UUID? = nil) {
    guard acceptsSnapshot(scope: scope, sessionID: sessionID), progress.revision >= 0 else {
      return
    }
    let key = revisionKey(scope: scope, mediaID: progress.mediaId)
    knownRevisions[key] = max(knownRevisions[key] ?? 0, progress.revision)
    // A new playback starts from the server's position, so it may save again.
    stoppedAfterConflict.remove(key)
    rememberConfirmed(progress, scope: scope)
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
      guard entries.count < Self.capacity else {
        storageFailed = true
        storageIssue = .capacity
        notify(reason: .storageFailure, scope: scope, mediaID: mediaID)
        return false
      }
      let key = revisionKey(scope: scope, mediaID: mediaID)
      guard !stoppedAfterConflict.contains(key) else { return false }
      let revision = [knownRevisions[key], baselineRevision].compactMap { $0 }.max()
      entries.append(
        TVProgressEntry(scope: scope, mediaID: mediaID, latest: snapshot, revision: revision))
    }
    guard persist() else { return false }
    notify(reason: .enqueued, scope: scope, mediaID: mediaID, snapshot: snapshot)
    kick()
    return true
  }

  func state(scope: TVProgressScope, mediaID: UUID) -> TVProgressSaveState? {
    if let entry = entries.first(where: { $0.scope == scope && $0.mediaID == mediaID }) {
      return entry.state
    }
    return stoppedAfterConflict.contains(revisionKey(scope: scope, mediaID: mediaID))
      ? .conflict : nil
  }

  func count(scope: TVProgressScope) -> Int { entries.filter { $0.scope == scope }.count }

  /// A confirmed conflict must never become an automatic local resume point.
  func latestPendingSnapshot(scope: TVProgressScope, mediaID: UUID) -> TVProgressSnapshot? {
    entries.first { $0.scope == scope && $0.mediaID == mediaID && $0.state == .pending }?.latest
  }

  /// Resolve against revisions in one actor turn. An acknowledged local sample
  /// never replaces a newer server revision, while an in-flight own sample stays usable.
  func resumePosition(scope: TVProgressScope, server: TVPlaybackProgress) -> Int64 {
    if let pending = latestPendingSnapshot(scope: scope, mediaID: server.mediaId) {
      return pending.finished ? 0 : pending.position
    }
    let known = confirmedProgress[revisionKey(scope: scope, mediaID: server.mediaId)]
    let newest = (known?.revision ?? -1) > server.revision ? known! : server
    return TVPlayerPolicy.resumePosition(newest)
  }

  private func rememberConfirmed(_ progress: TVPlaybackProgress, scope: TVProgressScope) {
    let key = revisionKey(scope: scope, mediaID: progress.mediaId)
    guard progress.revision >= (confirmedProgress[key]?.revision ?? -1) else { return }
    confirmedProgress[key] = progress
    if confirmedProgress.count > 256,
      let oldest = confirmedProgress.keys.first(where: { $0 != key })
    {
      confirmedProgress.removeValue(forKey: oldest)
    }
  }

  func pendingSnapshots(scope: TVProgressScope) -> [UUID: TVProgressSnapshot] {
    Dictionary(
      uniqueKeysWithValues: entries.filter { $0.scope == scope && $0.state == .pending }
        .map { ($0.mediaID, $0.latest) })
  }

  /// Register first, then read pendingSnapshots to avoid missing a concurrent
  /// acknowledgement while building a view's initial local overlay.
  func changes(scope: TVProgressScope) -> AsyncStream<TVProgressOutboxChange> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<TVProgressOutboxChange>.makeStream(
      bufferingPolicy: .bufferingNewest(64))
    observers[id] = (scope, continuation)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id) }
    }
    return stream
  }

  /// Observe the independent outbox worker for at most two seconds. Cancellation
  /// stops this wait immediately even if a transport ignores task cancellation.
  func flush(
    scope: TVProgressScope, mediaID: UUID, timeout: Duration = .seconds(2)
  ) async -> TVProgressFlushResult {
    let operation = generation
    let deadline = ContinuousClock.now.advanced(by: min(.seconds(2), max(.zero, timeout)))
    kick()
    while true {
      if Task.isCancelled { return .cancelled }
      guard operation == generation, activeScope == scope else { return .inactive }
      if storageFailed { return .storageFailure }
      guard let entry = entries.first(where: { $0.scope == scope && $0.mediaID == mediaID }) else {
        return stoppedAfterConflict.contains(revisionKey(scope: scope, mediaID: mediaID))
          ? .conflict : .saved
      }
      if entry.state == .conflict { return .conflict }
      if entry.state == .accessDenied { return .inactive }
      let now = ContinuousClock.now
      guard now < deadline else { return .pending }
      do {
        try await Task.sleep(for: min(.milliseconds(25), now.duration(to: deadline)))
      } catch { return .cancelled }
    }
  }

  // Read-only diagnostic for deterministic logic tests; contains no secrets.
  func pendingMutation(scope: TVProgressScope, mediaID: UUID) -> TVProgressMutation? {
    entries.first { $0.scope == scope && $0.mediaID == mediaID }?.mutation
  }

  private func kick() {
    guard worker == nil, !readFailed, !storageFailed, client != nil, let activeScope,
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
        }
        // Durability precedes every attempt, including a retry after a local
        // write failure. The uncertain mutation body is never regenerated.
        guard persist() else { break }
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
        rememberConfirmed(result, scope: scope)
        let beforeAcknowledgement = entries
        if entries[index].latest.id == mutation.snapshot.id {
          entries.remove(at: index)
        } else {
          entries[index].mutation = nil
          entries[index].revision = result.revision
        }
        guard persist() else {
          entries = beforeAcknowledgement
          break
        }
        notify(
          reason: .acknowledged, scope: scope, mediaID: mediaID,
          snapshot: latestPendingSnapshot(scope: scope, mediaID: mediaID), progress: result)
        failures = 0
      } catch {
        guard operation == generation, !Task.isCancelled else { return }
        guard let index = entryIndex(scope: scope, mediaID: mediaID) else { continue }
        if let api = error as? TVCoreError, api.isConflict {
          // Another device saved a newer position. Report it once and keep the server's
          // position: the open player stops saving this title until it is opened again, and the
          // entry is not kept, so the title is not stuck after that.
          entries[index].state = .conflict
          notify(reason: .stateChanged, scope: scope, mediaID: mediaID)
          stoppedAfterConflict.insert(revisionKey(scope: scope, mediaID: mediaID))
          entries.remove(at: index)
          _ = persist()
          continue
        }
        if let api = error as? TVCoreError, api.isAuthenticationFailure {
          entries[index].state = .accessDenied
          _ = persist()
          notify(reason: .stateChanged, scope: scope, mediaID: mediaID)
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
          notify(reason: .stateChanged, scope: scope, mediaID: mediaID)
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
    do {
      let data = try Self.encode(entries, legacyImported: legacyImported)
      if let journal {
        try journal.write(data)
        guard try journal.read() == data else { throw CocoaError(.fileWriteUnknown) }
      }
      storageFailed = false
      storageIssue = nil
      return true
    } catch {
      storageFailed = true
      storageIssue = (error as? CocoaError)?.code == .fileWriteOutOfSpace ? .capacity : .write
      for scope in Set(entries.map(\.scope)) {
        notify(reason: .storageFailure, scope: scope, mediaID: nil)
      }
      return false
    }
  }

  private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

  private func notify(
    reason: TVProgressOutboxChange.Reason, scope: TVProgressScope, mediaID: UUID?,
    snapshot: TVProgressSnapshot? = nil, progress: TVPlaybackProgress? = nil
  ) {
    let change = TVProgressOutboxChange(
      reason: reason, scope: scope, mediaID: mediaID, snapshot: snapshot, progress: progress,
      state: mediaID.flatMap { state(scope: scope, mediaID: $0) }, storageFailed: storageFailed)
    for (observedScope, continuation) in observers.values where observedScope == scope {
      continuation.yield(change)
    }
  }

  private static func encode(_ entries: [TVProgressEntry], legacyImported: Bool) throws -> Data {
    let data = try JSONEncoder().encode(
      TVProgressJournal(version: 1, entries: entries, legacyImported: legacyImported))
    guard entries.count <= capacity, data.count <= maximumBytes else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    return data
  }

  private static func decode(_ data: Data, maximumBytes limit: Int) throws -> TVProgressJournal {
    guard !data.isEmpty, data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
    let saved: TVProgressJournal
    if let journal = try? JSONDecoder().decode(TVProgressJournal.self, from: data) {
      guard journal.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
      saved = journal
    } else {
      saved = TVProgressJournal(
        version: 1, entries: try JSONDecoder().decode([TVProgressEntry].self, from: data),
        legacyImported: false)
    }
    guard saved.entries.count <= capacity,
      saved.entries.allSatisfy({ entry in
        entry.latest.isValid && (entry.revision.map { $0 >= 0 } ?? true)
          && (entry.mutation.map {
            $0.mediaID == entry.mediaID && $0.expectedRevision >= 0 && $0.snapshot.isValid
          } ?? true)
      }),
      Set(
        saved.entries.map {
          "\($0.scope.serverID):\($0.scope.profileID):\($0.scope.fingerprint):\($0.mediaID)"
        }
      )
      .count == saved.entries.count
    else { throw CocoaError(.fileReadCorruptFile) }
    return saved
  }

  private static func defaultStorageURL() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("AureliaTV", isDirectory: true)
      .appendingPathComponent("ProgressOutbox.json")
  }
}
