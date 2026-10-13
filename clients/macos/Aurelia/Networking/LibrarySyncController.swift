import Foundation

actor LibrarySyncController {
  typealias ChangeFetcher =
    @Sendable (StoredServerProfile, Int64, Int, String?) async throws
    -> SyncChangesResponse
  typealias Delay = @Sendable (TimeInterval) async throws -> Void

  private struct SessionKey: Hashable {
    let server: UUID
    let session: UUID?
    let user: UUID?
    init(_ profile: StoredServerProfile) {
      server = profile.serverId
      session = profile.sessionId
      user = profile.user?.id
    }
  }
  private struct Cursor {
    var value: Int64 = 0
    var generation: String?
  }

  private let fetchChanges: ChangeFetcher
  private var pollingTask: Task<Void, Never>?
  private var isForeground = true
  private var activeRun: UUID?
  private var activeSession: SessionKey?
  private var cursors: [SessionKey: Cursor] = [:]
  private var cursorSessions: [SessionKey] = []
  private let delay: Delay

  init(
    fetchChanges: @escaping ChangeFetcher = { profile, cursor, waitSeconds, generation in
      try await APIClient(profile: profile).syncChanges(
        after: cursor,
        waitSeconds: waitSeconds, generation: generation)
    },
    delay: @escaping Delay = { seconds in try await Task.sleep(for: .seconds(seconds)) }
  ) {
    self.fetchChanges = fetchChanges
    self.delay = delay
  }

  func start(
    profile: StoredServerProfile,
    runID: UUID = UUID(),
    onFailure: (@MainActor @Sendable (APIClientError) async -> Void)? = nil,
    onSuccess: (@MainActor @Sendable () async -> Void)? = nil,
    onChanges: @escaping @MainActor @Sendable (SyncChangesResponse) async throws -> Void
  ) {
    guard !Task.isCancelled else { return }
    stop()
    let run = runID
    activeRun = run
    let key = SessionKey(profile)
    activeSession = key
    guard isForeground else { return }
    pollingTask = Task {
      var cursor = cursors[key] ?? Cursor()
      var failures = 0
      while !Task.isCancelled, activeRun == run, isForeground {
        do {
          let started = Date()
          let changes: SyncChangesResponse
          do {
            changes = try await fetchChanges(profile, cursor.value, 30, cursor.generation)
          } catch let failure as APIClientError where failure.httpStatus == 404 {
            // Only this endpoint's absence enables old-server compatibility;
            // a failed snapshot read must not silently disable synchronization.
            return
          }
          try Task.checkCancellation()
          guard activeRun == run, isForeground else { return }
          if changes.cursor < cursor.value && !changes.resetRequired {
            throw APIClientError.invalidResponse
          }
          // A fetched notification is not an acknowledgement. Keep the old
          // cursor if loading/applying its snapshot fails, so the server can
          // redeliver the change even when no further mutation occurs.
          if changes.resetRequired || !changes.changedAreas.isEmpty {
            do {
              try await onChanges(changes)
            } catch let failure as APIClientError where failure.httpStatus == 404 {
              // A library/title can disappear between notification and scoped
              // reads. Refetch the snapshot from the same cursor after backoff.
              throw APIClientError.invalidResponse
            }
          }
          try Task.checkCancellation()
          guard activeRun == run, isForeground else { return }
          cursor = Cursor(value: changes.cursor, generation: changes.generation)
          if cursors[key] == nil {
            cursorSessions.append(key)
            if cursorSessions.count > 16 {
              cursors.removeValue(forKey: cursorSessions.removeFirst())
            }
          }
          cursors[key] = cursor
          failures = 0
          guard !Task.isCancelled, activeRun == run else { return }
          await onSuccess?()
          // Prevent a malformed or older endpoint from driving an unbounded empty poll loop.
          if Date().timeIntervalSince(started) < 0.25 { try await delay(0.25) }
        } catch is CancellationError {
          return
        } catch {
          guard !Task.isCancelled, activeRun == run, isForeground else { return }
          if error as? APIClientError == .supersededSnapshot {
            // The source cursor has not been acknowledged. Refetch after a
            // bounded delay, without reporting a malformed server response.
            do { try await delay(0.25) } catch { return }
            continue
          }
          if let failure = error as? APIClientError {
            if failure.isAuthenticationFailure || failure == .serverIdentityMismatch {
              await onFailure?(failure)
              return
            }
            if !failure.isRetryableTransient {
              await onFailure?(failure)
              return
            }
          }
          failures = min(failures + 1, 4)
          let retry =
            (error as? APIClientError)?.retryDelay
            ?? min(3 * pow(2, Double(failures - 1)), 30)
          do {
            try await delay(max(retry, 0.25))
          } catch {
            return
          }
        }
      }
    }
  }

  func setForeground(
    _ foreground: Bool,
    profile: StoredServerProfile?,
    runID: UUID = UUID(),
    onFailure: (@MainActor @Sendable (APIClientError) async -> Void)? = nil,
    onSuccess: (@MainActor @Sendable () async -> Void)? = nil,
    onChanges: @escaping @MainActor @Sendable (SyncChangesResponse) async throws -> Void
  ) {
    isForeground = foreground
    if foreground, let profile {
      start(
        profile: profile, runID: runID, onFailure: onFailure, onSuccess: onSuccess,
        onChanges: onChanges)
    } else {
      stop()
    }
  }

  func stop() {
    pollingTask?.cancel()
    pollingTask = nil
    activeRun = nil
    activeSession = nil
  }

  func stop(profile: StoredServerProfile) {
    guard activeSession == SessionKey(profile) else { return }
    stop()
  }

  func stop(runID: UUID) {
    guard activeRun == runID else { return }
    stop()
  }
}
