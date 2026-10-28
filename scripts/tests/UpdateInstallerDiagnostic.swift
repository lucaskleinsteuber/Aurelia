import Foundation

/// Exercise the production diagnostic exit path without launching an application.
@main
struct UpdateInstallerDiagnostic {
  static func main() {
    guard UpdateInstaller.runIfRequested(CommandLine.arguments) else { exit(2) }
  }
}
