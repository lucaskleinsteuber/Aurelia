#!/bin/zsh
# Makes the two README screenshots (JPEG, Mac Home and a series) in docs/assets/screenshots from a fictional library: invented
# titles and generated pictures from scripts/make-showcase.swift, shown by the Mac and Apple TV
# apps in their DEBUG showcase mode. No server, media or personal data is involved.
#
# The Mac UI test takes over the screen for about a minute; the Apple TV test runs in a
# temporary tvOS simulator. `--web-only` instead captures the browser in an isolated headless
# context with simulated metadata; it never enters the native test path. `--ios-only` captures
# the iPhone and iPad app in simulators (scripts/capture-ios-showcase.sh).
set -euo pipefail

repository_root=${0:A:h:h}
if [[ "${1:-}" == "--web-only" ]]; then
  shift
  exec sh "$repository_root/scripts/capture-web-showcase.sh" "$@"
fi
if [[ "${1:-}" == "--ios-only" ]]; then
  exec zsh "$repository_root/scripts/capture-ios-showcase.sh"
fi
source "$repository_root/scripts/workspace-paths.sh"
showcase="$other_root/Showcase"
screenshots="$repository_root/docs/assets/screenshots"
port=8766

swift "$repository_root/scripts/make-showcase.swift" "$showcase"

# The sandboxed Mac app cannot read the folder, so it is served on the loopback address only
# while the tests run.
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$showcase" >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
export TEST_RUNNER_AURELIA_SHOWCASE_DIR="http://127.0.0.1:$port/"

started=$(date +%s)
AURELIA_UNIT_TEST_FILTER=AureliaTests/ProfilePickerLayoutTests \
  AURELIA_UI_TEST_FILTER=AureliaUITests/ShowcaseScreenshotUITests \
  zsh "$repository_root/scripts/test-macos.sh"
AURELIA_TV_UI_TEST_FILTER=TVShowcaseScreenshotUITests \
  zsh "$repository_root/scripts/test-tvos-ui.sh"

# Export the named screenshots of both runs as PNG files.
export_root=$(mktemp -d)
for result in "$other_root/Test Results"/Aurelia-macOS-UI-*.xcresult(N) \
  "$other_root/Test Results"/AureliaTV-UI-*.xcresult(N); do
  (( $(stat -f %m "$result") >= started )) || continue
  target="$export_root/${result:t:r}"
  xcrun xcresulttool export attachments --path "$result" --output-path "$target" >/dev/null
done
mkdir -p "$screenshots"
python3 - "$export_root" "$screenshots" <<'PY'
import json, pathlib, shutil, sys
root, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
count = 0
for manifest in root.glob("*/manifest.json"):
    for test in json.loads(manifest.read_text()):
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName", "")
            stem = name.split("_")[0]
            if stem in ("mac-home", "mac-detail"):
                shutil.copy(manifest.parent / attachment["exportedFileName"], output / f"{stem}.png")
                count += 1
# Smaller JPEG files for the repository.
import subprocess
for png in output.glob("*.png"):
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "82", "-Z", "1600",
                    str(png), "--out", str(png.with_suffix(".jpg"))], check=True,
                   stdout=subprocess.DEVNULL)
    png.unlink()
print(f"{count} screenshots in {output}")
PY
rm -rf "$export_root"
