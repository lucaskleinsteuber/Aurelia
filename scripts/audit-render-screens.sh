#!/bin/zsh
# Draws Mac app screens offscreen to PNG files with an invented library, so they can be checked
# for visual bugs without using anyone's screen (DEBUG mode AURELIA_UI_TEST_MODE=audit-render,
# clients/macos/Aurelia/Views/AuditScreenRenderer.swift).
#
# The Debug build gets its own bundle identifier and an ad-hoc signature with only the App
# Sandbox: no network, Keychain or App Group access, and its preferences live in its own
# container, never the real app's. It starts in the background (`open -g`), never activates and
# never shows a window; every picture comes from a window that is never ordered in. No system
# setting is changed and nothing is played.
#
#   AURELIA_AUDIT_RENDER_OUTPUT    folder for <screen>__<size>__<appearance>.png and index.md
#                                  (default: $other_root/Audit/mac-render)
#   AURELIA_AUDIT_RENDER_SIZES     e.g. 1280x800,760x560,1920x1080 (the default)
#   AURELIA_AUDIT_RENDER_VARIANTS  light,dark,dark-contrast,dark-reducedtransparency (default);
#                                  also light-contrast, light-reducedtransparency
#   AURELIA_AUDIT_RENDER_ONLY      comma-separated screen names
#   AURELIA_AUDIT_RENDER_SCALE     pixels per point (default 1)
#   --skip-build                   reuse the last build
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true

skip_build=false
[[ "${1:-}" == "--skip-build" ]] && skip_build=true
output=${AURELIA_AUDIT_RENDER_OUTPUT:-"$other_root/Audit/mac-render"}
derived_data="$other_root/Build/macOS-AuditRender-DerivedData"
bundle_identifier=com.lucas.aurelia.media.auditrender
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
runtime_root="/private/tmp/Aurelia/$run_id"
candidate="$runtime_root/Aurelia.app"
frames="$runtime_root/frames.bin"
log_root="$other_root/Logs"
console_log="$log_root/Audit-Render-$run_id-console.log"
application_pid=''
log_pid=''

cleanup() {
  local exit_code=$?
  set +e
  [[ -n "$application_pid" ]] && kill "$application_pid" 2>/dev/null
  [[ -n "$log_pid" ]] && kill "$log_pid" 2>/dev/null
  find "$runtime_root" -depth -delete 2>/dev/null
  return $exit_code
}
trap cleanup EXIT

mkdir -p "$output/.manifests" "$log_root"
mkdir -m 700 -p "$runtime_root"

if [[ "$skip_build" != true ]]; then
  "$repository_root/scripts/prepare-vlckit.sh"
  DEVELOPER_DIR="$developer_dir" nice -n 10 xcodebuild -quiet \
    -project "$repository_root/clients/macos/Aurelia.xcodeproj" \
    -scheme Aurelia -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$derived_data" \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGNING_ALLOWED=NO \
    AURELIA_BUNDLE_ID_BASE=$bundle_identifier \
    build
fi

/usr/bin/ditto "$derived_data/Build/Products/Debug/Aurelia.app" "$candidate"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")" \
  == "$bundle_identifier" ]] || { print -u2 'The render build carries the real bundle identifier.'; exit 1; }
cat > "$runtime_root/render.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
PLIST
/usr/bin/codesign --force --deep --sign - "$candidate" 2>/dev/null
/usr/bin/codesign --force --sign - --entitlements "$runtime_root/render.entitlements" "$candidate"

# Console messages of this copy only (layout warnings, faults, errors).
/usr/bin/log stream --style compact --level info \
  --predicate "processImagePath BEGINSWITH \"$runtime_root/\"" > "$console_log" 2>&1 &
log_pid=$!
sleep 1

/usr/bin/open -n -g \
  --env AURELIA_UI_TEST_MODE=audit-render \
  --env "AURELIA_AUDIT_RENDER_SIZES=${AURELIA_AUDIT_RENDER_SIZES:-}" \
  --env "AURELIA_AUDIT_RENDER_VARIANTS=${AURELIA_AUDIT_RENDER_VARIANTS:-}" \
  --env "AURELIA_AUDIT_RENDER_ONLY=${AURELIA_AUDIT_RENDER_ONLY:-}" \
  --env "AURELIA_AUDIT_RENDER_SCALE=${AURELIA_AUDIT_RENDER_SCALE:-}" \
  --stdout "$frames" --stderr "$runtime_root/stderr.txt" "$candidate" \
  --args -ApplePersistenceIgnoreState YES

deadline=$(( $(date +%s) + ${AURELIA_AUDIT_RENDER_TIMEOUT:-5400} ))
finished=false
while (( $(date +%s) < deadline )); do
  [[ -z "$application_pid" ]] \
    && application_pid="$(pgrep -f "^$candidate/Contents/MacOS/Aurelia( |$)" | tail -1 || true)"
  if [[ -f "$frames" ]] && grep -aq 'AURELIA-AUDIT-FRAME json manifest' "$frames"; then
    finished=true
    break
  fi
  if [[ -n "$application_pid" ]] && ! kill -0 "$application_pid" 2>/dev/null; then break; fi
  sleep 2
done
sleep 1
[[ -n "$application_pid" ]] && kill "$application_pid" 2>/dev/null || true
kill "$log_pid" 2>/dev/null || true
log_pid=''
[[ -f "$runtime_root/stderr.txt" ]] && cp "$runtime_root/stderr.txt" "$log_root/Audit-Render-$run_id-stderr.txt"

python3 -I - "$frames" "$output" "$run_id" "$finished" "$console_log" <<'PY'
import json, pathlib, re, sys
frames, output, run_id, finished, console = sys.argv[1:6]
output = pathlib.Path(output)
data = pathlib.Path(frames).read_bytes() if pathlib.Path(frames).exists() else b""
header = re.compile(rb"\nAURELIA-AUDIT-FRAME (\w+) (\S+) (\d+)\n")
position, written, manifest, logs = 0, 0, [], []
while True:
    match = header.search(data, position)
    if not match:
        break
    kind, name, length = match.group(1).decode(), match.group(2).decode(), int(match.group(3))
    body = data[match.end():match.end() + length]
    position = match.end() + length
    if len(body) < length:
        logs.append(f"truncated frame {name}")
        break
    if kind == "png" and "/" not in name and not name.startswith("."):
        (output / f"{name}.png").write_bytes(body)
        written += 1
    elif kind == "json":
        manifest = json.loads(body or b"[]")
    else:
        logs.append(f"{name}: {body.decode(errors='replace')}")
(output / ".manifests" / f"{run_id}.json").write_text(json.dumps(
    {"finished": finished == "true", "entries": manifest, "logs": logs}, indent=1))
print(f"{written} pictures written to {output} (finished: {finished}); console log: {console}")
PY
python3 -I "$repository_root/scripts/audit-render-index.py" "$output"
[[ "$finished" == true ]] || { print -u2 'The render did not finish; see the logs.'; exit 1; }
