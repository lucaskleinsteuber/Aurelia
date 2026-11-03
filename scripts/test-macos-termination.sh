#!/bin/zsh
# Exercise production termination in real sandboxed, windowless AppKit processes.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
run_root="$HOME/Library/Caches/Aurelia/TestRuns/termination-$(uuidgen)"
mkdir -p "$run_root/Termination.app/Contents/MacOS"
trap 'rm -rf -- "$run_root"' EXIT
python3 - "$run_root" <<'PY'
import pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])
with (root/'Termination.app/Contents/Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleExecutable='Termination',CFBundleIdentifier='com.lucas.aurelia.terminationtest.'+root.name.removeprefix('termination-'),CFBundleName='Termination',CFBundlePackageType='APPL',LSUIElement=True),f)
with (root/'entitlements.plist').open('wb') as f:
    plistlib.dump({'com.apple.security.app-sandbox':True,'com.apple.security.temporary-exception.files.absolute-path.read-write':[str(root)+'/']},f)
PY
xcrun swiftc -warnings-as-errors -swift-version 6 \
  "$repository_root/clients/macos/Aurelia/ApplicationTerminationCoordinator.swift" \
  "$repository_root/scripts/tests/ApplicationTerminationTests.swift" \
  -o "$run_root/Termination.app/Contents/MacOS/Termination"
codesign --force --sign - --entitlements "$run_root/entitlements.plist" "$run_root/Termination.app"
python3 - "$run_root" <<'PY'
import json,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1])
for mode in ('task','main-queue','immediate'):
    receipt=root/(mode+'.json')
    subprocess.run([str(root/'Termination.app/Contents/MacOS/Termination'),mode,str(receipt)],check=True,timeout=10)
    result=json.loads(receipt.read_text())
    assert result['windows']==0 and result['cleanupCount']==1 and result['cleanupFinished']
    print('PASS: sandboxed AppKit termination '+mode+'; exactly one completed cleanup, no windows or media.')
PY
