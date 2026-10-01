import AppKit

enum AdministrationPasswordPrompt {
  @MainActor static func confirm(serverName: String) throws -> String {
    let alert = NSAlert()
    alert.messageText = "Authorize Server Change"
    alert.informativeText =
      "Enter your current owner password for \(serverName). This authorizes only the pending change, once, for up to two minutes."
    alert.addButton(withTitle: "Authorize")
    alert.addButton(withTitle: "Cancel")
    let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    password.placeholderString = "Current owner password"
    alert.accessoryView = password
    alert.window.initialFirstResponder = password
    guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
    guard !password.stringValue.isEmpty else {
      throw APIClientError.serverRejected(
        code: "password_required", message: "Enter your current password.")
    }
    return password.stringValue
  }
}
