import BackgroundTasks
import Foundation

/// Keeps a converted download going while Tarven is in the background: a continued processing
/// task the person started, shown by the system with its progress (iOS 26). When the system ends
/// the time, the download pauses and Try Again continues where it stopped.
@MainActor
final class IOSConvertedBackground {
  private let store: IOSOfflineStore
  private var tasks: [UUID: BGContinuedProcessingTask] = [:]
  private var activeRuns: [UUID: UUID] = [:]

  init(store: IOSOfflineStore) {
    self.store = store
    store.convertedStarted = { [weak self] id, run, title in self?.begin(id, run: run, title: title)
    }
    store.convertedProgressed = { [weak self] id, run, share in self?.progress(id, run: run, share)
    }
    store.convertedEnded = { [weak self] id, run, success in
      self?.end(id, run: run, success: success)
    }
  }

  static func identifier(_ id: UUID) -> String {
    "\(Bundle.main.bundleIdentifier ?? "org.tarven.ios").download.\(id.uuidString.lowercased())"
  }

  private func begin(_ id: UUID, run: UUID, title: String) {
    activeRuns[id] = run
    let identifier = Self.identifier(run)
    let accepted = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: identifier, using: .main
    ) {
      [weak self] task in
      MainActor.assumeIsolated {
        guard let self, self.activeRuns[id] == run,
          let task = task as? BGContinuedProcessingTask
        else {
          task.setTaskCompleted(success: false)
          return
        }
        task.progress.totalUnitCount = 1000
        task.expirationHandler = IOSBackgroundTaskCallbacks.expiration { [weak self] in
          self?.store.pauseConverted(id, run: run)
        }
        self.tasks[run] = task
      }
    }
    guard accepted else { return }
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier, title: "Downloading \(title)",
      subtitle: "A smaller copy from your server")
    request.strategy = .fail
    // Without the system's time the download still runs while Tarven is open.
    try? BGTaskScheduler.shared.submit(request)
  }

  private func progress(_ id: UUID, run: UUID, _ share: Double) {
    guard activeRuns[id] == run, let task = tasks[run] else { return }
    task.progress.completedUnitCount = Int64(share * 1000)
    task.updateTitle(
      task.title, subtitle: "\(Int(share * 100)) % · A smaller copy from your server")
  }

  private func end(_ id: UUID, run: UUID, success: Bool) {
    guard activeRuns[id] == run else { return }
    activeRuns[id] = nil
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier(run))
    tasks.removeValue(forKey: run)?.setTaskCompleted(success: success)
  }
}
