import Foundation

struct SyncRefreshPlan: Equatable {
  let fullCatalog: Bool
  let collections: Bool
  let home: Bool
  let mediaIDs: [UUID]

  init(_ changes: SyncChangesResponse) {
    let areas = Set(changes.changedAreas)
    let ids = Array(Set(changes.changedMediaIds)).sorted { $0.uuidString < $1.uuidString }
    // Bound small updates; resets, structural changes and older responses
    // without affected IDs still need an authorized coherent snapshot.
    fullCatalog =
      changes.resetRequired || areas.contains(.catalog) || areas.contains(.libraries)
      || ids.count > 32
      || (ids.isEmpty && (areas.contains(.metadata) || areas.contains(.userState)))
    collections = fullCatalog || areas.contains(.collections)
    home = changes.resetRequired || !areas.isEmpty
    mediaIDs = fullCatalog ? [] : ids
  }
}

struct ScanPollingBatch {
  var active: [LibraryScanSummary] = []
  var completed: [LibraryScanSummary] = []
  var unavailable: Set<UUID> = []
  var definitiveFailure: APIClientError?

  func reconciled(polledIDs: Set<UUID>, current: [LibraryScanSummary]) -> Self {
    let currentIDs = Set(current.map(\.id))
    var result = self
    // A confirmed cancellation/removal during a delayed GET must win over
    // either its stale reply or the cached fallback after a failed GET.
    result.active =
      active.filter { currentIDs.contains($0.id) }
      + current.filter { !polledIDs.contains($0.id) }
    result.completed = completed.filter { currentIDs.contains($0.id) }
    result.unavailable.formIntersection(currentIDs)
    return result
  }

  @MainActor static func load(
    scans: [LibraryScanSummary],
    fetch: (UUID) async throws -> LibraryScanSummary
  ) async throws -> Self {
    var result = Self()
    for scan in scans {
      try Task.checkCancellation()
      do {
        let latest = try await fetch(scan.id)
        guard latest.id == scan.id, latest.libraryId == scan.libraryId else {
          throw APIClientError.invalidResponse
        }
        switch latest.state {
        case .queued, .running, .waitingForStorage: result.active.append(latest)
        default: result.completed.append(latest)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A failed read is not a completed scan. Retain its last known state.
        result.active.append(scan)
        result.unavailable.insert(scan.id)
        if let failure = error as? APIClientError,
          failure.isAuthenticationFailure || failure == .serverIdentityMismatch
        {
          result.definitiveFailure = failure
          result.active.append(
            contentsOf: scans.dropFirst(result.active.count + result.completed.count))
          return result
        }
      }
    }
    try Task.checkCancellation()
    return result
  }
}

struct HostHealthPolicy {
  enum Action: Equatable {
    case wait(TimeInterval)
    case recover, stop
  }
  private(set) var failures = 0
  private(set) var recoveries = 0
  private var healthySince: TimeInterval?

  mutating func healthy(at instant: TimeInterval) {
    failures = 0
    if healthySince == nil { healthySince = instant }
    if let healthySince, instant - healthySince >= 60 { recoveries = 0 }
  }

  mutating func failed(at instant: TimeInterval, confirmedExit: Bool = false) -> Action {
    healthySince = nil
    failures += 1
    if !confirmedExit && failures < 3 { return .wait(Double(failures)) }
    guard recoveries < 3 else { return .stop }
    recoveries += 1
    failures = 0
    return .recover
  }

  var recoveryDelay: TimeInterval { min(pow(2, Double(max(0, recoveries - 1))), 8) }
}
