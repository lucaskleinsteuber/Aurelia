import BackgroundTasks
import Foundation

/// Keeps a converted download going while Aurelia is in the background: a continued processing
/// task the person started, shown by the system with its progress (iOS 26). When the system ends
/// the time, the download pauses and Try Again continues where it stopped.
@MainActor
final class IOSConvertedBackground {
  private let store: IOSOfflineStore
  private var tasks: [UUID: BGContinuedProcessingTask] = [:]
  private var registered: Set<String> = []

  init(store: IOSOfflineStore) {
    self.store = store
    store.convertedStarted = { [weak self] id, title in self?.begin(id, title: title) }
    store.convertedProgressed = { [weak self] id, share in self?.progress(id, share) }
    store.convertedEnded = { [weak self] id, success in self?.end(id, success: success) }
  }

  static func identifier(_ id: UUID) -> String {
    "\(Bundle.main.bundleIdentifier ?? "com.lucas.aurelia.ios").download.\(id.uuidString.lowercased())"
  }

  private func begin(_ id: UUID, title: String) {
    let identifier = Self.identifier(id)
    if !registered.contains(identifier) {
      let accepted = BGTaskScheduler.shared.register(
        forTaskWithIdentifier: identifier, using: .main
      ) {
        [weak self] task in
        MainActor.assumeIsolated {
          guard let self, let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
          }
          task.progress.totalUnitCount = 1000
          task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.store.pauseConverted(id) }
          }
          self.tasks[id] = task
        }
      }
      guard accepted else { return }
      registered.insert(identifier)
    }
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier, title: "Downloading \(title)",
      subtitle: "A smaller copy from your server")
    request.strategy = .fail
    // Without the system's time the download still runs while Aurelia is open.
    try? BGTaskScheduler.shared.submit(request)
  }

  private func progress(_ id: UUID, _ share: Double) {
    guard let task = tasks[id] else { return }
    task.progress.completedUnitCount = Int64(share * 1000)
    task.updateTitle(
      task.title, subtitle: "\(Int(share * 100)) % · A smaller copy from your server")
  }

  private func end(_ id: UUID, success: Bool) {
    tasks.removeValue(forKey: id)?.setTaskCompleted(success: success)
  }
}
