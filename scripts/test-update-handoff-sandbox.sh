#!/bin/zsh
# A windowless sandboxed sender launches a windowless receiver through NSWorkspace.
# They use only invented bytes in this unique run directory; no personal App Group or app.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
run_root="$HOME/Library/Caches/Tarven/TestRuns/handoff-$(uuidgen)"
mkdir -p "$run_root"
trap 'chmod -R u+w "$run_root" 2>/dev/null || true; rm -rf -- "$run_root"' EXIT
python3 - "$run_root" <<'PY'
import pathlib,plistlib,sys,json
root=pathlib.Path(sys.argv[1]);shared=root/'Shared/Updates';shared.mkdir(parents=True)
for name in ['Sender','Receiver']:
 bundle=root/(name+'.app');(bundle/'Contents/MacOS').mkdir(parents=True)
 with (bundle/'Contents/Info.plist').open('wb') as f:plistlib.dump(dict(CFBundleExecutable=name,CFBundleIdentifier='org.tarven.handofftest.'+name+'.'+root.name.removeprefix('handoff-'),CFBundleName=name,CFBundlePackageType='APPL',LSUIElement=True),f)
with (root/'sender.entitlements').open('wb') as f:plistlib.dump({'com.apple.security.app-sandbox':True,'com.apple.security.temporary-exception.files.absolute-path.read-write':[str(root)+'/']},f)
quote=lambda p:json.dumps(str(p))
(root/'Sender.swift').write_text('''import AppKit
import Foundation
@main @MainActor struct Sender {
  static func main() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let root = URL(fileURLWithPath: ROOT)
    let directory = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let image = directory.appendingPathComponent("Tarven-1.27.2-126-macOS-universal.dmg")
    try Data("invented data; never mounted".utf8).write(to: image)
    let request = try MacUpdateInstallRequest.prepare(image: image, build: 126, appPID: getpid(), root: root)
    try request.save(in: root)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = true
    configuration.arguments = ["--not-needed-for-handoff"]
    _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: HELPER), configuration: configuration)
    try await request.waitForAcknowledgement(in: root)
    print("PASS: real NSWorkspace launch from a sandboxed sender acknowledged the production request without a player or GUI.")
  }
}
'''.replace('ROOT',quote(shared)).replace('HELPER',quote(root/'Receiver.app')))
(root/'Receiver.swift').write_text('''import AppKit
import Foundation
@main @MainActor final class Receiver: NSObject, NSApplicationDelegate {
  static func main() {
    let application = NSApplication.shared
    let delegate = Receiver()
    application.delegate = delegate
    application.setActivationPolicy(.prohibited)
    application.run()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      do {
        let root = URL(fileURLWithPath: ROOT)
        let fakeApp = URL(fileURLWithPath: APP)
        // Exercise the real UpdateInstaller.hasPendingRequest guards before claiming.
        guard !UpdateInstaller.hasPendingRequest(
          arguments: ["--background"], environment: [:], appURL: fakeApp,
          requiredAppPath: fakeApp.path, updatesRoot: root)
        else { exit(11) }
        guard !UpdateInstaller.hasPendingRequest(
          arguments: [], environment: ["TARVEN_HOST_BOOTSTRAP_DIR": "/tmp"], appURL: fakeApp,
          requiredAppPath: fakeApp.path, updatesRoot: root)
        else { exit(12) }
        guard !UpdateInstaller.hasPendingRequest(
          arguments: [], environment: [:], appURL: fakeApp,
          requiredAppPath: "/Applications/Tarven.app", updatesRoot: root)
        else { exit(13) }
        guard UpdateInstaller.hasPendingRequest(
          arguments: [], environment: [:], appURL: fakeApp,
          requiredAppPath: fakeApp.path, updatesRoot: root)
        else { exit(14) }

        // Exercise UpdateInstaller.runPendingWorker pre-acceptance status fallback on a read-only
        // destination without launching or touching any real application.
        let fm = FileManager.default
        let roRoot = root.deletingLastPathComponent().appendingPathComponent("ReadOnlyCheck")
        let roApps = roRoot.appendingPathComponent("Apps", isDirectory: true)
        let roUpdates = roRoot.appendingPathComponent("Updates", isDirectory: true)
        let roDir = roUpdates.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: roApps, withIntermediateDirectories: true)
        try fm.createDirectory(at: roDir, withIntermediateDirectories: true)
        let roApp = roApps.appendingPathComponent("Tarven.app", isDirectory: true)
        try fm.createDirectory(at: roApp, withIntermediateDirectories: true)
        let roImage = roDir.appendingPathComponent("Tarven-1.27.2-126-macOS-universal.dmg")
        try Data("invented bytes".utf8).write(to: roImage)
        let roReq = try MacUpdateInstallRequest.prepare(
          image: roImage, build: 126, appPID: getpid(), root: roUpdates)
        try roReq.save(in: roUpdates)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roApps.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roApps.path) }
        var relaunched = false
        let workerResult = UpdateInstaller.runPendingWorker(
          appURL: roApp, requiredAppPath: roApp.path, updatesRoot: roUpdates,
          relaunch: { _ in relaunched = true })
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roApps.path)
        guard case .completed = workerResult, !relaunched,
          let roStatus = MacUpdateInstallRequest.status(in: roUpdates),
          roStatus.id == roReq.id, roStatus.phase == "failed",
          roStatus.message == UpdateInstallation.Failure.notWritable.message,
          !fm.fileExists(atPath: roDir.path)
        else { exit(15) }

        guard let request = try MacUpdateInstallRequest.claim(in: root) else { exit(2) }
        try request.writeStatus("accepted", in: root)
        try JSONEncoder().encode(CommandLine.arguments.contains("--not-needed-for-handoff")).write(to: root.appendingPathComponent("arguments-arrived.json"))
        try await Task.sleep(for: .milliseconds(200))
        NSApplication.shared.terminate(nil)
      } catch { exit(3) }
    }
  }
}
'''.replace('ROOT',quote(shared)).replace('APP',quote(root/'Sender.app')))
PY
for name in Sender Receiver; do
  if [[ "$name" == Receiver ]]; then
    xcrun swiftc -warnings-as-errors -swift-version 6 \
      "$repository_root/clients/macos/UpdateHandoff/MacUpdateInstallRequest.swift" \
      "$repository_root/clients/macos/UpdateHandoff/AppEdition.swift" \
      "$repository_root/clients/macos/TarvenServerHost/UpdateInstallation.swift" \
      "$repository_root/clients/macos/TarvenServerHost/UpdateInstaller.swift" \
      "$run_root/$name.swift" \
      -o "$run_root/$name.app/Contents/MacOS/$name"
    codesign --force --sign - "$run_root/$name.app"
  else
    xcrun swiftc -warnings-as-errors -swift-version 6 \
      "$repository_root/clients/macos/UpdateHandoff/MacUpdateInstallRequest.swift" \
      "$repository_root/clients/macos/UpdateHandoff/AppEdition.swift" "$run_root/$name.swift" \
      -o "$run_root/$name.app/Contents/MacOS/$name"
    codesign --force --sign - --entitlements "$run_root/sender.entitlements" "$run_root/$name.app"
  fi
done
"$run_root/Sender.app/Contents/MacOS/Sender"
python3 - "$run_root/Shared/Updates/arguments-arrived.json" <<'PY'
import json,pathlib,sys
assert json.loads(pathlib.Path(sys.argv[1]).read_text()) is False
print('PASS: macOS discarded the sandboxed launch arguments; the file handoff still succeeded.')
PY
