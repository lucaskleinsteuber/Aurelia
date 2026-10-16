#!/bin/zsh
# Explicit, bounded check of the one user-approved episode. Never called by CI
# or ordinary simulator tests; it uses the existing normal app connection.
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
if [[ "${AURELIA_TV_DEVICE_CHECK:-}" != 1 ||
      "${AURELIA_TV_DEVICE_TITLE:-}" != 'Breaking Bad' ||
      "${AURELIA_TV_DEVICE_EPISODE_TITLE:-}" != Pilot ]]; then
  print -u2 'This check requires explicit opt-in for Breaking Bad S01 E01 Pilot.'
  print -u2 'Set AURELIA_TV_DEVICE_CHECK=1, AURELIA_TV_DEVICE_TITLE="Breaking Bad", and AURELIA_TV_DEVICE_EPISODE_TITLE=Pilot.'
  exit 2
fi
if [[ "${AURELIA_TV_DEVICE_MEDIA_CHECKED:-}" != 1 || "${AURELIA_TV_DEVICE_READY:-}" != 1 ]]; then
  print -u2 'Record the approved file size/mtime and confirm the TV is ready before setting AURELIA_TV_DEVICE_MEDIA_CHECKED=1 and AURELIA_TV_DEVICE_READY=1.'
  exit 2
fi
device_id=''
provisioning=0
while (( $# > 0 )); do
  case "$1" in
    --device)
      (( $# >= 2 )) || { print -u2 '--device requires the paired Apple TV identifier.'; exit 2; }
      device_id=$2
      shift
      ;;
    --allow-provisioning-updates) provisioning=1 ;;
    *) print -u2 'Usage: scripts/test-tvos-device.sh --device identifier [--allow-provisioning-updates]'; exit 2 ;;
  esac
  shift
done
[[ -n "$device_id" ]] || { print -u2 'An explicit paired Apple TV identifier is required.'; exit 2; }
run_id="tv-device-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
run_root="$HOME/Library/Caches/Aurelia/TestRuns/$run_id"
result="$other_root/Test Results/AureliaTV-Device-$run_id.xcresult"
log="$other_root/Logs/AureliaTV-Device-$run_id.log"
mkdir -p "$run_root" "$other_root/Test Results" "$other_root/Logs"
did_run_tests=0
finish() {
  local exit_code=$?
  set +e
  if (( did_run_tests )); then
    # This is the test runner only. Never uninstall the user's Aurelia app.
    xcrun devicectl device uninstall app --device "$device_id" \
      com.lucas.aurelia.tvos.ui-tests.xctrunner --timeout 10 >> "$log" 2>&1
  fi
  rm -rf "$run_root"
  exit "$exit_code"
}
trap finish EXIT

dependency_root=${TVVLCKIT_ROOT:-"$repository_root/clients/tvos/Dependencies"}
TVVLCKIT_ROOT="$dependency_root" "$repository_root/scripts/prepare-tvvlckit.sh"
arguments=(
  -project "$repository_root/clients/tvos/AureliaTV.xcodeproj"
  -scheme AureliaTVDeviceCheck -configuration Release -sdk appletvos
  -destination "platform=tvOS,id=$device_id" -destination-timeout 30
  -derivedDataPath "$run_root/DerivedData"
  "TVVLCKIT_ROOT=$dependency_root"
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
)
if (( provisioning )); then arguments+=(-allowProvisioningUpdates); fi
# Build first. The playback deadline only surrounds the actual test invocation.
DEVELOPER_DIR="$developer_dir" xcodebuild "${arguments[@]}" build-for-testing 2>&1 | tee "$log"

# Only the runner receives approval identifiers. The product is the unmodified
# Release app with its normal connection and no synthetic launch environment.
xctestrun=$(python3 - "$run_root/DerivedData/Build/Products" <<'PY'
import os, pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
paths = list(root.glob('*.xctestrun'))
if len(paths) != 1:
    raise SystemExit('Expected one dedicated device xctestrun configuration.')
path = paths[0]
with path.open('rb') as source:
    run = plistlib.load(source)
targets = [target for config in run.get('TestConfigurations', []) for target in config.get('TestTargets', [])]
if not targets:
    targets = [value for value in run.values() if isinstance(value, dict) and value.get('IsUITestBundle')]
if len(targets) != 1:
    raise SystemExit('The device check must select exactly one UI test target.')
target = targets[0]
target['OnlyTestIdentifiers'] = ['TVDeviceCheckTests/testApprovedEpisodeOnPhysicalAppleTV']
target['SkipTestIdentifiers'] = []
target['SystemAttachmentLifetime'] = 'keepNever'
target['UserAttachmentLifetime'] = 'keepNever'
target['PreferredScreenCaptureFormat'] = 'screenshots'
target['TestTimeoutsEnabled'] = True
target['DefaultTestExecutionTimeAllowance'] = 240
target['MaximumTestExecutionTimeAllowance'] = 240
environment = target.setdefault('EnvironmentVariables', {})
for key in ('AURELIA_TV_DEVICE_CHECK', 'AURELIA_TV_DEVICE_TITLE', 'AURELIA_TV_DEVICE_EPISODE_TITLE',
            'AURELIA_TV_DEVICE_SERIES_ID', 'AURELIA_TV_DEVICE_EPISODE_ID', 'AURELIA_TV_DEVICE_MEDIA_CHECKED', 'AURELIA_TV_DEVICE_READY'):
    if key in os.environ:
        environment[key] = os.environ[key]
for key in tuple(environment):
    if key.startswith('AURELIA_TV_UI_'):
        del environment[key]
target['UITargetAppEnvironmentVariables'] = {}
target['UITargetAppCommandLineArguments'] = []
with path.open('wb') as destination:
    plistlib.dump(run, destination)
print(path)
PY
)
print 'Device check: automatic screen capture Never; screenshot format selected, no video; only the approved episode test.' | tee -a "$log"
did_run_tests=1
DEVELOPER_DIR="$developer_dir" python3 - "$device_id" "$xctestrun" "$result" "$log" <<'PY'
import json, os, pathlib, selectors, signal, subprocess, sys, time

device, configuration, result, log_path = sys.argv[1:]
command = [
    'xcodebuild', '-xctestrun', configuration, '-destination', f'platform=tvOS,id={device}',
    '-destination-timeout', '30', '-resultBundlePath', result,
    '-collect-test-diagnostics', 'never', '-enableCodeCoverage', 'NO',
    '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
    '-default-test-execution-time-allowance', '240', '-maximum-test-execution-time-allowance', '240',
    '-only-testing:AureliaTVUITests/TVDeviceCheckTests/testApprovedEpisodeOnPhysicalAppleTV',
    'test-without-building',
]

def terminate_only_aurelia():
    """Bounded emergency stop; never target helpers or another installed app."""
    try:
        reply = subprocess.run(
            ['xcrun', 'devicectl', 'device', 'info', 'processes', '--device', device,
             '--search', 'Aurelia', '--timeout', '5', '--json-output', '-'],
            capture_output=True, text=True, timeout=7, check=False)
        data = json.loads(reply.stdout)
        candidates = []
        def walk(value):
            if isinstance(value, dict):
                paths = [v for v in value.values() if isinstance(v, str)]
                if any(p.endswith('/Aurelia.app/Aurelia') for p in paths):
                    pid = value.get('processIdentifier', value.get('pid', value.get('processId')))
                    if isinstance(pid, int) and pid > 0:
                        candidates.append(pid)
                for item in value.values():
                    walk(item)
            elif isinstance(value, list):
                for item in value:
                    walk(item)
        walk(data)
        for pid in set(candidates):
            subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'terminate', '--device', device,
                            '--pid', str(pid), '--kill', '--timeout', '5'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=7, check=False)
        return bool(candidates)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False

with open(log_path, 'ab', buffering=0) as log:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    # The test stops itself after 210 seconds of playback. XCTest's independent
    # allowance is 240 seconds; this outer guard reserves 30 seconds for stop.
    deadline = time.monotonic() + 270
    timed_out = False
    try:
        while selector.get_map():
            if time.monotonic() >= deadline:
                timed_out = True
                message = b'Device check exceeded its 270-second invocation limit; stopping Aurelia.\n'
                log.write(message)
                sys.stdout.buffer.write(message)
                sys.stdout.flush()
                terminate_only_aurelia()
                os.killpg(process.pid, signal.SIGTERM)
                break
            for key, _ in selector.select(timeout=0.25):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                log.write(chunk)
                sys.stdout.buffer.write(chunk)
                sys.stdout.flush()
        try:
            exit_code = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            exit_code = process.wait()
    finally:
        selector.close()
        if process.poll() is None:
            terminate_only_aurelia()
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    if timed_out:
        raise SystemExit(124)
    raise SystemExit(exit_code)
PY
print "Device check results: $result"
print "Device check log: $log"
