#!/bin/zsh
# A windowless sandboxed sender launches a windowless receiver through NSWorkspace.
# They use only invented bytes in this unique run directory; no personal App Group or app.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
run_root="$HOME/Library/Caches/Aurelia/TestRuns/handoff-$(uuidgen)"
mkdir -p "$run_root"
trap 'rm -rf -- "$run_root"' EXIT
python3 - "$run_root" <<'PY'
import pathlib,plistlib,sys,json
root=pathlib.Path(sys.argv[1]);shared=root/'Shared/Updates';shared.mkdir(parents=True)
for name in ['Sender','Receiver']:
 bundle=root/(name+'.app');(bundle/'Contents/MacOS').mkdir(parents=True)
 with (bundle/'Contents/Info.plist').open('wb') as f:plistlib.dump(dict(CFBundleExecutable=name,CFBundleIdentifier='com.lucas.aurelia.handofftest.'+name+'.'+root.name.removeprefix('handoff-'),CFBundleName=name,CFBundlePackageType='APPL',LSUIElement=True),f)
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
    let image = directory.appendingPathComponent("Aurelia-1.27.2-126-macOS-universal.dmg")
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
        guard let request = try MacUpdateInstallRequest.claim(in: root) else { exit(2) }
        try request.writeStatus("accepted", in: root)
        try JSONEncoder().encode(CommandLine.arguments.contains("--not-needed-for-handoff")).write(to: root.appendingPathComponent("arguments-arrived.json"))
        try await Task.sleep(for: .milliseconds(200))
        NSApplication.shared.terminate(nil)
      } catch { exit(3) }
    }
  }
}
'''.replace('ROOT',quote(shared)))
PY
for name in Sender Receiver; do
  xcrun swiftc -warnings-as-errors -swift-version 6 \
    "$repository_root/clients/macos/UpdateHandoff/MacUpdateInstallRequest.swift" \
    "$repository_root/clients/macos/UpdateHandoff/AppEdition.swift" "$run_root/$name.swift" \
    -o "$run_root/$name.app/Contents/MacOS/$name"
  if [[ "$name" == Sender ]]; then
    codesign --force --sign - --entitlements "$run_root/sender.entitlements" "$run_root/$name.app"
  else
    codesign --force --sign - "$run_root/$name.app"
  fi
done
"$run_root/Sender.app/Contents/MacOS/Sender"
python3 - "$run_root/Shared/Updates/arguments-arrived.json" <<'PY'
import json,pathlib,sys
assert json.loads(pathlib.Path(sys.argv[1]).read_text()) is False
print('PASS: macOS discarded the sandboxed launch arguments; the file handoff still succeeded.')
PY
