import Combine
import Foundation

/// The code-entry sheet keeps request failures and drafts locally. Generations stop a late
/// answer for an edited code from replacing the current device or dismissing a newer error.
@MainActor
final class IOSDeviceApprovalModel: ObservableObject {
  enum Phase: Equatable { case idle, lookingUp, deciding }

  @Published var code = "" {
    didSet {
      guard code != oldValue else { return }
      invalidate()
      preview = nil
      done = nil
      error = nil
    }
  }
  @Published private(set) var preview: IOSDeviceAuthorizationPreview?
  @Published private(set) var done: String?
  @Published private(set) var error: Error?
  @Published private(set) var phase = Phase.idle
  private var generation = 0

  var isWorking: Bool { phase != .idle }
  var canLookUp: Bool { code.filter(\.isNumber).count == 8 && !isWorking }

  func lookUp(
    using work: @MainActor @Sendable (String) async throws -> IOSDeviceAuthorizationPreview
  ) async {
    guard canLookUp else { return }
    generation += 1
    let request = generation
    let typed = code
    phase = .lookingUp
    preview = nil
    done = nil
    error = nil
    defer { if request == generation { phase = .idle } }
    do {
      let answer = try await work(typed)
      try Task.checkCancellation()
      guard request == generation else { return }
      preview = answer
    } catch is CancellationError {
      return
    } catch {
      guard request == generation, !Task.isCancelled else { return }
      self.error = error
    }
  }

  func decide(
    approve: Bool,
    using work: @MainActor @Sendable (UUID, Bool) async throws -> Void
  ) async {
    guard !isWorking, done == nil, let preview else { return }
    generation += 1
    let request = generation
    phase = .deciding
    error = nil
    defer { if request == generation { phase = .idle } }
    do {
      try await work(preview.id, approve)
      try Task.checkCancellation()
      guard request == generation else { return }
      done = approve ? "“\(preview.deviceName)” can connect now." : "The device was denied."
    } catch is CancellationError {
      return
    } catch {
      guard request == generation, !Task.isCancelled else { return }
      self.error = error
    }
  }

  /// Closing the sheet or editing a code retires its outstanding response.
  func invalidate() {
    generation += 1
    phase = .idle
  }
}
