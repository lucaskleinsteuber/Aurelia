import Combine
import Foundation

@MainActor
final class TVLibraryListing: ObservableObject {
  let section: TVBrowseSection
  var kind: TVMediaKind { section.fixedKind ?? .unknown }
  @Published private(set) var items: [TVCatalogItem] = []
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  @Published private(set) var query: TVBrowseQuery
  @Published private(set) var search = ""
  private(set) var total = 1
  private var offset = 0
  private var revision: String?
  private var generation = UUID()
  private var profileID: UUID?
  private var plans: [UUID: TVPlaybackPlan] = [:]

  init(kind: TVMediaKind) {
    self.section = kind == .movie ? .movies : .shows
    query = section.defaultQuery
  }
  init(section: TVBrowseSection) {
    self.section = section
    query = section.defaultQuery
  }
  func configure(query: TVBrowseQuery, search: String, profileID: UUID?) {
    let query = section.constrain(query)
    let search = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    guard self.query != query || self.search != search || self.profileID != profileID else {
      return
    }
    self.query = query
    self.search = search
    self.profileID = profileID
    invalidate()
  }
  func clear() {
    query = section.defaultQuery
    search = ""
    profileID = nil
    invalidate()
  }
  func invalidate() {
    generation = UUID()
    items = []
    total = 1
    offset = 0
    revision = nil
    error = nil
    loading = false
    plans = [:]
  }
  func update(_ item: TVCatalogItem) {
    if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
  }
  func loadNext(api: TVAPIClient, onFailure: (Error) -> Void) async {
    guard !loading, offset < total else { return }
    let run = generation
    loading = true
    defer { if generation == run { loading = false } }
    var restarts = 0
    while restarts < 2 {
      do {
        repeat {
          let page = try await api.browsePage(
            query: query, search: search, offset: offset, revision: revision)
          guard generation == run, !Task.isCancelled else { return }
          guard offset == 0 || total == page.total else { throw TVCoreError.invalidResponse }
          var next = page.items
          if section == .continueWatching {
            next = try await continuationTargets(next, api: api, run: run)
          }
          guard generation == run, !Task.isCancelled else { return }
          let existing = Set(items.map(\.id))
          items.append(contentsOf: next.filter { !existing.contains($0.id) })
          total = page.total
          offset = page.offset + page.items.count
          revision = page.revision
          error = nil
          if !next.isEmpty { return }
        } while offset < total
        return
      } catch let failure as TVCoreError
        where failure.code == "catalog_changed" && failure.statusCode == 409
      {
        guard generation == run, !Task.isCancelled else { return }
        items = []
        total = 1
        offset = 0
        revision = nil
        plans = [:]
        restarts += 1
      } catch {
        guard generation == run, !Task.isCancelled, !(error is CancellationError) else { return }
        self.error = error.localizedDescription
        onFailure(error)
        return
      }
    }
    error = "The library changed while loading. Try again."
  }

  /// Reloads the loaded range and swaps it in at once. Visible items, focus and
  /// pushed details stay in place instead of emptying the grid during a refresh.
  func refresh(api: TVAPIClient, onFailure: (Error) -> Void) async {
    guard !items.isEmpty else {
      await loadNext(api: api, onFailure: onFailure)
      return
    }
    generation = UUID()
    let run = generation
    let wanted = items.count
    loading = true
    defer { if generation == run { loading = false } }
    var collected: [TVCatalogItem] = []
    var nextOffset = 0
    var pageTotal = 0
    var pageRevision: String?
    do {
      repeat {
        let page = try await api.browsePage(
          query: query, search: search, offset: nextOffset, revision: pageRevision)
        guard generation == run, !Task.isCancelled else { return }
        var next = page.items
        if section == .continueWatching {
          next = try await continuationTargets(next, api: api, run: run)
        }
        guard generation == run, !Task.isCancelled else { return }
        let existing = Set(collected.map(\.id))
        collected.append(contentsOf: next.filter { !existing.contains($0.id) })
        pageTotal = page.total
        pageRevision = page.revision
        nextOffset = page.offset + page.items.count
        if page.items.isEmpty { break }
      } while nextOffset < pageTotal && collected.count < wanted
      items = collected
      total = pageTotal
      offset = nextOffset
      revision = pageRevision
      error = nil
    } catch let failure as TVCoreError
      where failure.code == "catalog_changed" && failure.statusCode == 409
    {
      guard generation == run, !Task.isCancelled else { return }
      invalidate()
      await loadNext(api: api, onFailure: onFailure)
    } catch {
      guard generation == run, !Task.isCancelled, !(error is CancellationError) else { return }
      self.error = error.localizedDescription
      onFailure(error)
    }
  }

  private func continuationTargets(_ candidates: [TVCatalogItem], api: TVAPIClient, run: UUID)
    async throws
    -> [TVCatalogItem]
  {
    var result: [TVCatalogItem] = []
    let visible = candidates.filter { $0.continueWatchingHidden != true }
    for start in stride(from: 0, to: visible.count, by: 2) {
      try Task.checkCancellation()
      let batch = Array(visible[start..<min(start + 2, visible.count)])
      let cached = plans
      let resolved = try await withThrowingTaskGroup(
        of: (Int, TVCatalogItem?, TVPlaybackPlan?).self
      ) { group in
        for (index, item) in batch.enumerated() {
          group.addTask {
            if item.kind == .series {
              let plan: TVPlaybackPlan
              if let existing = cached[item.id] {
                plan = existing
              } else {
                plan = try await api.playbackPlan(mediaID: item.id)
              }
              return (index, plan.continueWatchingEligible ? plan.target : nil, plan)
            }
            let eligible =
              item.kind == .movie && item.progress?.isCompleted != true
              && (item.progress?.positionMilliseconds ?? 0) > 10_000
            return (index, eligible ? item : nil, nil)
          }
        }
        var values: [(Int, TVCatalogItem?, TVPlaybackPlan?)] = []
        for try await value in group { values.append(value) }
        return values.sorted { $0.0 < $1.0 }
      }
      guard generation == run, !Task.isCancelled else { throw CancellationError() }
      for (index, item, plan) in resolved {
        if let plan { plans[batch[index].id] = plan }
        if let item { result.append(item) }
      }
    }
    var seen = Set<UUID>()
    return result.filter { seen.insert($0.detailID).inserted }
  }
}
