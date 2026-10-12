import Darwin
import Foundation

/// Contains IDs, positions and concurrency revisions only: never credentials,
/// server URLs, media paths or titles. An uncertain write keeps its mutation ID
/// across restarts so that the server can recognize an already-applied retry.
struct PendingPlaybackProgress: Codable, Equatable, Sendable {
  let sequence: UUID
  let position: Int64
  let duration: Int64
  let finished: Bool
  let recordedAt: Date
}

struct PlaybackProgressScope: Codable, Hashable, Sendable {
  let server: UUID
  let user: UUID
  let fingerprint: String

  init(_ profile: StoredServerProfile) {
    server = profile.serverId
    user = profile.user?.id ?? profile.sessionId
    fingerprint = profile.publicKeyFingerprint.lowercased()
  }
}

enum PlaybackProgressSaveState: String, Codable, Sendable {
  case pending, retrying, conflict, accessDenied, unsupportedServer
}

private struct ProgressMutation: Codable, Equatable {
  let id: UUID
  let snapshot: PendingPlaybackProgress
  let expectedRevision: Int64
}

private struct ProgressOutboxEntry: Codable, Equatable {
  let scope: PlaybackProgressScope
  let media: UUID
  var pending: PendingPlaybackProgress
  var baselineRevision: Int64?
  var mutation: ProgressMutation?
  var state: PlaybackProgressSaveState = .pending
  var attempts = 0
  var nextAttempt = Date.distantPast
}

@MainActor
final class PlaybackProgressOutbox {
  static let shared = PlaybackProgressOutbox(storageURL: defaultStorageURL())
  static let capacity = 256
  static let maximumFileBytes = 512 * 1_024

  private var entries: [ProgressOutboxEntry] = []
  private var revisions: [UUID: Int64] = [:]
  private var client: (any PlaybackClientProtocol)?
  private var scope: PlaybackProgressScope?
  private var session: UUID?
  private var generation = UUID()
  private var worker: Task<Void, Never>?
  private let storageURL: URL?
  private let clock: @MainActor () -> Date
  private let sleep: @MainActor (TimeInterval) async throws -> Void
  private var observers: [UUID: @MainActor () -> Void] = [:]
  private(set) var storageFailed = false
  private(set) var capacityReached = false
  private var storageLocked = false

  init(
    storageURL: URL? = nil,
    clock: @escaping @MainActor () -> Date = { Date() },
    sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { delay in
      try await Task.sleep(for: .seconds(delay))
    }
  ) {
    self.storageURL = storageURL
    self.clock = clock
    self.sleep = sleep
    guard let storageURL else { return }
    do {
      try prepareStorage(storageURL)
      if FileManager.default.fileExists(atPath: storageURL.path) {
        let bytes = try readPrivateFile(storageURL)
        entries = try JSONDecoder().decode([ProgressOutboxEntry].self, from: bytes)
        guard entries.count <= Self.capacity,
          entries.allSatisfy({
            valid($0.pending) && (0...6).contains($0.attempts)
              && ($0.baselineRevision.map { $0 >= 0 } ?? true)
              && ($0.mutation.map { valid($0.snapshot) && $0.expectedRevision >= 0 } ?? true)
          }),
          Set(
            entries.map {
              "\($0.scope.server):\($0.scope.user):\($0.scope.fingerprint):\($0.media)"
            }
          ).count == entries.count
        else { throw CocoaError(.fileReadCorruptFile) }
      }
    } catch {
      // Do not overwrite a corrupt/unreadable queue with an empty queue.
      storageFailed = true
      storageLocked = true
    }
  }

  func activate(profile: StoredServerProfile) {
    activate(client: APIPlaybackClient(profile: profile))
  }

  func activate(client: any PlaybackClientProtocol) {
    let newScope = PlaybackProgressScope(client.profile)
    if scope != newScope || session != client.profile.sessionId {
      deactivate()
      scope = newScope
      session = client.profile.sessionId
      for index in entries.indices where entries[index].scope == newScope {
        // Only a newly verified session can release an authentication stop.
        if entries[index].state == .accessDenied { entries[index].state = .pending }
      }
    }
    self.client = client
    kick()
  }

  func deactivate() {
    generation = UUID()
    worker?.cancel()
    worker = nil
    client = nil
    scope = nil
    session = nil
    revisions.removeAll()
  }

  func observe(_ callback: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID()
    observers[id] = callback
    return id
  }

  func removeObserver(_ id: UUID) { observers[id] = nil }

  func noteBaseline(_ progress: PlaybackProgressResponse, profile: StoredServerProfile) {
    guard scope == PlaybackProgressScope(profile) else { return }
    if let revision = progress.revision {
      revisions[progress.mediaId] = max(revisions[progress.mediaId] ?? 0, revision)
      // A newly authorized playback source proves access to this title was
      // restored. A generic reconnect/current-user refresh does not.
      if let index = entries.firstIndex(where: {
        $0.scope == scope && $0.media == progress.mediaId && $0.state == .accessDenied
      }) {
        entries[index].state = .pending
        entries[index].attempts = 0
        entries[index].nextAttempt = clock()
        guard persist() else {
          notify()
          return
        }
        notify()
        kick()
      }
    }
  }

  func state(media: UUID, profile: StoredServerProfile) -> PlaybackProgressSaveState? {
    entries.first { $0.scope == PlaybackProgressScope(profile) && $0.media == media }?.state
  }

  func pendingCount(profile: StoredServerProfile) -> Int {
    entries.filter { $0.scope == PlaybackProgressScope(profile) }.count
  }

  @discardableResult
  func enqueue(
    media: UUID, profile: StoredServerProfile, position: Int64, duration: Int64, finished: Bool
  ) -> Bool {
    let snapshot = PendingPlaybackProgress(
      sequence: UUID(), position: position, duration: duration, finished: finished,
      recordedAt: clock())
    guard valid(snapshot) else { return false }
    let target = PlaybackProgressScope(profile)
    if let index = entries.firstIndex(where: { $0.scope == target && $0.media == media }) {
      entries[index].pending = snapshot
      // Never replace an uncertain in-flight write with a new mutation. The
      // next snapshot may be a deliberate backwards seek, not a higher time.
    } else {
      guard entries.count < Self.capacity else {
        capacityReached = true
        notify()
        return false
      }
      entries.append(
        ProgressOutboxEntry(
          scope: target, media: media, pending: snapshot,
          baselineRevision: scope == target ? revisions[media] : nil))
    }
    guard persist() else {
      notify()
      return false
    }
    notify()
    kick()
    return true
  }

  /// Called only after an explicit user confirmation in the player. A conflict
  /// is not resolved by a reconnect, periodic tick or app restart.
  func resolveConflict(media: UUID, profile: StoredServerProfile) async throws {
    guard let client, scope == PlaybackProgressScope(profile),
      entries.contains(where: { $0.scope == scope && $0.media == media && $0.state == .conflict })
    else { return }
    let operation = generation
    let progress = try await client.playbackProgress(mediaId: media)
    guard operation == generation, scope == PlaybackProgressScope(profile),
      let revision = progress.revision, revision >= 0, progress.mediaId == media,
      let index = entries.firstIndex(where: { $0.scope == scope && $0.media == media })
    else { throw APIClientError.invalidResponse }
    revisions[media] = revision
    entries[index].baselineRevision = revision
    entries[index].mutation = nil
    entries[index].state = .pending
    entries[index].attempts = 0
    entries[index].nextAttempt = clock()
    guard persist() else { throw CocoaError(.fileWriteUnknown) }
    notify()
    kick()
  }

  /// Shutdown must not wait for a hung network request. The durable write has
  /// already completed synchronously; this is only a short best-effort flush.
  func flush(for seconds: TimeInterval = 0.35) async {
    kick()
    let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, seconds)))
    var immediateYields = 0
    while worker != nil && ContinuousClock.now < deadline {
      if immediateYields < 16 {
        immediateYields += 1
        await Task.yield()
      } else {
        try? await Task.sleep(for: .milliseconds(5))
      }
    }
  }

  private func kick() {
    guard worker == nil, client != nil, scope != nil, !storageFailed else { return }
    let operation = generation
    worker = Task { [weak self] in await self?.drain(operation: operation) }
  }

  private func drain(operation: UUID) async {
    defer {
      if generation == operation { worker = nil }
    }
    while operation == generation, !Task.isCancelled, let client, let scope {
      let candidates = entries.indices.filter {
        entries[$0].scope == scope
          && [.pending, .retrying].contains(entries[$0].state)
          && entries[$0].attempts < 6
      }
      // One offline title's backoff must not stall saves for other episodes.
      guard let index = candidates.min(by: { entries[$0].nextAttempt < entries[$1].nextAttempt })
      else { return }
      let delay = entries[index].nextAttempt.timeIntervalSince(clock())
      if delay > 60 {
        // Wall-clock corrections or a restored queue must not postpone saves
        // indefinitely. Retry windows are never intentionally above 60 seconds.
        entries[index].nextAttempt = clock().addingTimeInterval(60)
      }
      if delay > 0 {
        // Re-check at most once per second so a newly queued title need not
        // wait behind another title's longer retry delay.
        do { try await sleep(min(delay, 1)) } catch { return }
        continue
      }
      let media = entries[index].media
      do {
        if entries[index].mutation == nil {
          if entries[index].baselineRevision == nil {
            if !client.requiresProgressRevision {
              entries[index].baselineRevision = 0
            } else {
              // An offline draft without a known baseline cannot safely adopt
              // the newest server revision: that would overwrite another device.
              entries[index].state = .conflict
              _ = persist()
              notify()
              continue
            }
          }
          entries[index].mutation = ProgressMutation(
            id: UUID(), snapshot: entries[index].pending,
            expectedRevision: entries[index].baselineRevision ?? 0)
          guard persist() else {
            notify()
            return
          }
        }
        guard let mutation = entries[index].mutation else { return }
        let result = try await client.updatePlaybackProgress(
          mediaId: media, positionMilliseconds: mutation.snapshot.position,
          durationMilliseconds: mutation.snapshot.duration, isFinished: mutation.snapshot.finished,
          expectedRevision: mutation.expectedRevision, clientMutationId: mutation.id)
        guard operation == generation, !Task.isCancelled else { return }
        guard let revision = result.revision ?? (client.requiresProgressRevision ? nil : 0) else {
          entries[index].state = .unsupportedServer
          _ = persist()
          notify()
          continue
        }
        if client.requiresProgressRevision,
          result.mediaId != media || result.lastMutationId != mutation.id
            || revision <= mutation.expectedRevision
        {
          throw APIClientError.invalidResponse
        }
        revisions[media] = revision
        if entries[index].pending.sequence == mutation.snapshot.sequence {
          entries.remove(at: index)
          capacityReached = false
        } else {
          entries[index].mutation = nil
          entries[index].baselineRevision = revision
          entries[index].state = .pending
          entries[index].attempts = 0
          entries[index].nextAttempt = clock()
        }
        guard persist() else {
          notify()
          return
        }
        notify()
      } catch {
        guard operation == generation, !Task.isCancelled else { return }
        let api = error as? APIClientError
        if api?.problemCode == "playback_progress_conflict" || api?.httpStatus == 409 {
          entries[index].state = .conflict
        } else if api?.isAuthenticationFailure == true
          || api == .serverIdentityMismatch
          || !TicketRenewalPolicy.isTransient(error)
        {
          entries[index].state = .accessDenied
        } else {
          entries[index].attempts += 1
          entries[index].state = .retrying
          let delay = min(60, max(1, api?.retryDelay ?? pow(2, Double(entries[index].attempts))))
          entries[index].nextAttempt = clock().addingTimeInterval(delay)
        }
        guard persist() else {
          notify()
          return
        }
        notify()
      }
    }
  }

  func retryAfterReconnect() {
    guard let scope else { return }
    if storageFailed, !storageLocked {
      guard persist() else {
        notify()
        return
      }
      notify()
    }
    for index in entries.indices where entries[index].scope == scope {
      if entries[index].state == .retrying, entries[index].attempts >= 6,
        entries[index].nextAttempt <= clock()
      {
        entries[index].attempts = 0
      }
    }
    kick()
  }

  /// A fresh playback ticket proves this session can reach this title again.
  /// Release only its transport retry/backoff, never adopt a newer revision or
  /// replace an uncertain mutation. Other titles and policy stops stay intact.
  func retryAfterPlaybackAuthorization(media: UUID, profile: StoredServerProfile) {
    guard scope == PlaybackProgressScope(profile), session == profile.sessionId,
      let index = entries.firstIndex(where: {
        $0.scope == scope && $0.media == media && $0.state == .retrying
      })
    else { return }
    entries[index].attempts = 0
    entries[index].nextAttempt = clock()
    guard persist() else {
      notify()
      return
    }
    notify()
    kick()
  }

  private func notify() { for observer in observers.values { observer() } }

  private func valid(_ snapshot: PendingPlaybackProgress) -> Bool {
    snapshot.duration > 0 && snapshot.position >= 0 && snapshot.position <= snapshot.duration
  }

  private func persist() -> Bool {
    guard let storageURL else { return true }
    guard !storageLocked else { return false }
    do {
      try prepareStorage(storageURL)
      let bytes = try JSONEncoder().encode(entries)
      guard bytes.count <= Self.maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
      let temporary = storageURL.deletingLastPathComponent()
        .appendingPathComponent(".pending-\(UUID().uuidString).json")
      let descriptor = open(
        temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer {
        try? handle.close()
        unlink(temporary.path)
      }
      guard fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
      try handle.write(contentsOf: bytes)
      try handle.synchronize()
      try handle.close()
      guard rename(temporary.path, storageURL.path) == 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
      storageFailed = false
      return true
    } catch {
      storageFailed = true
      return false
    }
  }

  private func prepareStorage(_ file: URL) throws {
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var metadata = stat()
    guard lstat(directory.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
      metadata.st_mode & 0o777 == 0o700
    else { throw CocoaError(.fileReadNoPermission) }
    if lstat(file.path, &metadata) == 0 {
      guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(),
        metadata.st_nlink == 1, metadata.st_mode & 0o777 == 0o600
      else { throw CocoaError(.fileReadNoPermission) }
    }
  }

  private func readPrivateFile(_ file: URL) throws -> Data {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size <= Self.maximumFileBytes,
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1
    else { throw CocoaError(.fileReadCorruptFile) }
    return try handle.readToEnd() ?? Data()
  }

  private static func defaultStorageURL() -> URL? {
    // Explicit temporary storage URLs in persistence tests still work. The
    // process-wide queue must never read/write the installed user's state from
    // XCTest, synthetic UI fixtures or an isolated release preflight host.
    if NativePreflightIsolation.isRequested { return nil }
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      if environment["AURELIA_UI_TEST_MODE"] != nil
        || environment["AURELIA_RUNNING_TESTS"] == "1"
        || environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
      {
        return nil
      }
    #endif
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("PlaybackState", isDirectory: true)
      .appendingPathComponent("pending-progress.json")
  }
}
