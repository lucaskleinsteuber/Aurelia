import AppKit

enum AdministrationPasswordPrompt {
  @MainActor static func viewingPIN(name: String) throws -> String {
    let alert = NSAlert()
    alert.messageText = "Unlock \(name) on the New Connection"
    alert.informativeText =
      "The server restarted for this network trial. Re-enter your viewing PIN; it will not be stored."
    alert.addButton(withTitle: "Unlock")
    alert.addButton(withTitle: "Cancel")
    let pin = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
    pin.placeholderString = "4–8 digit viewing PIN"
    alert.accessoryView = pin
    alert.window.initialFirstResponder = pin
    guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
    guard ProfilePIN.isValid(pin.stringValue) else {
      throw APIClientError.serverRejected(
        code: "invalid_pin_format", message: "Use a numeric PIN with 4 to 8 digits.")
    }
    return pin.stringValue
  }
  @MainActor static func confirm(serverName: String) throws -> String {
    let alert = NSAlert()
    alert.messageText = "Authorize Server Change"
    alert.informativeText =
      "Enter the server management password for \(serverName). This authorizes only the pending change, once, for up to two minutes. Your viewing PIN cannot authorize server changes."
    alert.addButton(withTitle: "Authorize")
    alert.addButton(withTitle: "Cancel")
    let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    password.placeholderString = "Server management password"
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
