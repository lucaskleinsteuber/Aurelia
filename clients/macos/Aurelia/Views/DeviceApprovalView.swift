import SwiftUI

struct DeviceApprovalView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var code = ""
  @State private var preview: DeviceAuthorizationPreview?
  @State private var error: String?
  @State private var busy = false
  @State private var request: Task<Void, Never>?
  @FocusState private var codeFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Approve Apple TV or Browser").font(.title2.bold())
      if let preview {
        LabeledContent("Device", value: preview.deviceName)
        LabeledContent("Server", value: preview.serverName)
        Text("Only approve the device showing this code.")
          .foregroundStyle(.secondary)
        Text(code).font(.system(.title2, design: .monospaced, weight: .semibold))
      } else {
        TextField("8-digit code shown on the Apple TV or in the browser", text: $code)
          .textFieldStyle(.roundedBorder)
          .focused($codeFocused)
          .disabled(busy)
          .accessibilityIdentifier("device-approval-code")
          .onSubmit { start(approve: nil) }
      }
      if let error {
        Text(error).foregroundStyle(.red).accessibilityIdentifier("device-approval-error")
      }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        if preview != nil {
          Button("Deny", role: .destructive) { start(approve: false) }
            .disabled(busy)
          Button("Approve") { start(approve: true) }
            .keyboardShortcut(.defaultAction).disabled(busy)
            .accessibilityIdentifier("device-approval-confirm")
        } else {
          Button("Continue") { start(approve: nil) }
            .keyboardShortcut(.defaultAction).disabled(busy || !validCode)
            .accessibilityIdentifier("device-approval-lookup")
        }
      }
    }
    .padding(24).frame(width: 420)
    .onAppear { codeFocused = true }
    .onDisappear { request?.cancel() }
    .onChange(of: model.administrationGeneration) { _, _ in dismiss() }
    .onChange(of: model.managementUnlocked) { _, unlocked in if !unlocked { dismiss() } }
  }

  private var validCode: Bool {
    code.utf8.count == 8 && code.utf8.allSatisfy { (48...57).contains($0) }
  }

  private func start(approve: Bool?) {
    guard !busy, validCode, let profile = model.profile, profile.user?.role == .owner,
      model.managementUnlocked
    else { return }
    let generation = model.administrationGeneration
    let target = preview
    let submittedCode = code
    busy = true
    error = nil
    request = Task { @MainActor in
      defer { busy = false }
      do {
        let response = try await model.currentAdministration {
          let client = APIClient(profile: profile)
          if let approve, let target {
            return try await client.decideDeviceAuthorization(id: target.id, approve: approve)
          }
          return try await client.lookupDeviceAuthorization(code: submittedCode)
        }
        guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
        if approve != nil {
          guard response.state == (approve == true ? .approved : .denied) else {
            throw APIClientError.invalidResponse
          }
          await model.reloadDevices()
          dismiss()
        } else {
          guard response.state == .pending else {
            throw APIClientError.serverRejected(
              code: "pairing_not_pending", message: "This pairing request is no longer pending.")
          }
          preview = response
          code = submittedCode
        }
      } catch is CancellationError {
      } catch {
        guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
  }
}
