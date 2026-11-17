import Foundation
import Testing

@Suite("iOS device code approval")
struct IOSDeviceApprovalTests {
  @MainActor
  @Test func anInvalidCodeStaysEditableAndCanBeRetriedInTheSameSheet() async {
    let model = IOSDeviceApprovalModel()
    model.code = "00000000"
    await model.lookUp { _ in
      throw IOSCoreError.server(
        status: 404, code: "invalid_code", message: "The code is invalid or expired.",
        retryAfter: nil)
    }
    #expect(model.code == "00000000")
    #expect((model.error as? IOSCoreError)?.code == "invalid_code")
    #expect(model.canLookUp)
    #expect(model.preview == nil)
    let device = preview(name: "Invented tablet")
    await model.lookUp { _ in device }
    #expect(model.preview == device)
    #expect(model.error == nil)
    #expect(model.code == "00000000")
  }

  @MainActor
  @Test func duplicateLookupsAndLateRepliesCannotReplaceAnEditedCode() async throws {
    let model = IOSDeviceApprovalModel()
    let gate = IOSDeviceApprovalGate()
    model.code = "12345678"
    let first = Task { await model.lookUp { typed in await gate.lookup(typed) } }
    try await gate.waitUntilRequested()
    #expect(model.phase == .lookingUp)
    let duplicate = preview(name: "Duplicate")
    await model.lookUp { _ in duplicate }
    #expect(model.preview == nil)
    model.code = "87654321"
    let current = preview(name: "Current")
    await model.lookUp { _ in current }
    #expect(model.preview == current)
    await gate.finish(preview(name: "Old reply"))
    await first.value
    #expect(model.code == "87654321")
    #expect(model.preview == current)
    #expect(!model.isWorking)
  }

  @MainActor
  @Test func failedDecisionsKeepTheDeviceAndCanBeRetried() async {
    let model = IOSDeviceApprovalModel()
    model.code = "12345678"
    let device = preview(name: "Invented tablet")
    await model.lookUp { _ in device }
    await model.decide(approve: true) { _, _ in
      throw IOSCoreError.server(
        status: 503, code: "temporary_failure", message: "Try the decision again.", retryAfter: nil)
    }
    #expect(model.preview == device)
    #expect(model.done == nil)
    #expect(model.error != nil)
    #expect(!model.isWorking)
    await model.decide(approve: true) { _, _ in }
    #expect(model.done == "“Invented tablet” can connect now.")
    #expect(model.error == nil)
    #expect(model.code == "12345678")
  }

  private func preview(name: String) -> IOSDeviceAuthorizationPreview {
    IOSDeviceAuthorizationPreview(
      id: UUID(), deviceName: name, serverId: UUID(), serverName: "Invented server",
      state: "pending", expiresAt: "2099-01-01T00:00:00Z")
  }
}

private actor IOSDeviceApprovalGate {
  private var continuation: CheckedContinuation<IOSDeviceAuthorizationPreview, Never>?

  func lookup(_ code: String) async -> IOSDeviceAuthorizationPreview {
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilRequested() async throws {
    for _ in 0..<1000 {
      if continuation != nil { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw WaitError.timedOut
  }

  func finish(_ value: IOSDeviceAuthorizationPreview) {
    continuation?.resume(returning: value)
    continuation = nil
  }

  enum WaitError: Error { case timedOut }
}
