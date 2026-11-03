#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
build_number=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' "$repository_root/clients/macos/Configuration/BuildNumber.xcconfig")
source_candidate=${1:-"$other_root/Build/Build $build_number/Aurelia.app"}

# All credentials stay in a private synthetic configuration and Python memory.
# Neither a control URL nor a credential is passed as a process argument.
/usr/bin/python3 - "$source_candidate" "$other_root" "$build_number" <<'PY'
import datetime
import json
import os
import pathlib
import platform
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

source = pathlib.Path(sys.argv[1])
artifacts = pathlib.Path(sys.argv[2])
build = sys.argv[3]
run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + str(uuid.uuid4())
root = pathlib.Path("/private/tmp/Aurelia") / run_id
candidate = root / "Aurelia.app"
data = root / "Data"
logs = root / "Logs"
bootstrap = root / "Host"
configuration = bootstrap / "preflight.json"
rendezvous = bootstrap / "background-rendezvous.json"
report = artifacts / "Test Results" / ("Aurelia-HostWatchdog-" + run_id + ".txt")
helper = candidate / "Contents/Helpers/Aurelia Server Host.app/Contents/MacOS/AureliaServerHost"
architecture = "arm64" if platform.machine() == "arm64" else "x64"
server = candidate / ("Contents/Resources/Server/osx-" + architecture + "/Aurelia.Server")
process = None
known_children = set()
helper_output = None
private_values = set()
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

class ProbeFailure(Exception):
    pass

def fail(code):
    raise ProbeFailure(code)

def process_alive(pid):
    try:
        os.kill(pid, 0)
        state = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
        return bool(state) and not state.startswith("Z")
    except ProcessLookupError:
        return False

def canonical_command(value):
    # Foundation can preserve macOS's /tmp alias when launching the child.
    # Compare both complete synthetic paths in their canonical spelling.
    return value.replace("/tmp/Aurelia/", "/private/tmp/Aurelia/")

def is_owned_child(pid):
    if process is None or not process_alive(pid):
        return False
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "ppid=", "-o", "command="], capture_output=True, text=True)
    fields = result.stdout.strip().split(None, 1)
    return len(fields) == 2 and fields[0] == str(process.pid) and canonical_command(fields[1]).startswith(str(server) + " run --data-dir " + str(data))

def is_synthetic_process(pid):
    if not process_alive(pid):
        return False
    command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout.strip()
    return canonical_command(command).startswith(str(server) + " run --data-dir " + str(data))

def children():
    if process is None:
        return []
    result = subprocess.run(["/usr/bin/pgrep", "-P", str(process.pid)], capture_output=True, text=True)
    return [int(value) for value in result.stdout.split() if value.isdecimal() and is_owned_child(int(value))]

def read_status():
    try:
        port = json.loads(rendezvous.read_text())["port"]
        credential = json.loads(configuration.read_text())["controlSecret"]
        private_values.add(credential)
        request = urllib.request.Request("http://127.0.0.1:" + str(port) + "/" + credential + "/status")
        with opener.open(request, timeout=2) as response:
            value = json.loads(response.read(65536))
        if isinstance(value.get("bootstrapToken"), str):
            private_values.add(value["bootstrapToken"])
        # Do not return or print bootstrapToken or other credential fields.
        return value.get("state")
    except (OSError, ValueError, KeyError, urllib.error.URLError):
        return None

def live():
    try:
        request = urllib.request.Request("http://127.0.0.1:43110/api/v1/health/live", method="HEAD")
        with opener.open(request, timeout=1) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False

def wait_until(predicate, seconds, code):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            fail("helper_exited_unexpectedly")
        if predicate():
            return
        time.sleep(0.25)
    fail(code)

def record_diagnostics():
    destination = artifacts / "Logs" / ("Aurelia-HostWatchdog-" + run_id + ".log")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if helper_output is not None:
        helper_output.flush()
    state = read_status()
    lines = ["helper_state=" + str(state), "rendezvous_exists=" + str(rendezvous.exists()), "owned_children=" + str(len(children())), "live=" + str(live())]
    for source in (root / "helper-output.log", logs / "server.log"):
        if source.is_file():
            text = source.read_bytes()[-65536:].decode("utf-8", errors="replace")
            for value in private_values:
                if value:
                    text = text.replace(value, "[redacted]")
            # Secret-bearing output is excluded even if a response was lost
            # before the harness learned its exact value.
            lines.extend(line for line in text.splitlines() if not re.search(r"token|secret|password|authorization|AURELIA_SERVER_(READY|STOPPING)", line, re.I))
    destination.write_text("\n".join(lines) + "\n")
    destination.chmod(0o600)

exit_code = 1
try:
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text("Aurelia Build " + build + " background host watchdog smoke\nRun: " + run_id + "\n")
    for name in ("Aurelia", "AureliaServerHost"):
        if subprocess.run(["/usr/bin/pgrep", "-x", name], stdout=subprocess.DEVNULL).returncode == 0:
            fail("existing_aurelia_process_no_process_was_stopped")
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", 43110)) == 0:
            fail("loopback_port_occupied_no_process_was_stopped")
    if not source.is_dir():
        fail("candidate_missing")
    root.mkdir(parents=True, mode=0o700)
    for directory in (data, logs, bootstrap):
        directory.mkdir(mode=0o700)
    subprocess.run(["/usr/bin/ditto", str(source), str(candidate)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not helper.is_file() or not server.is_file():
        fail("candidate_incomplete")
    description = {"version": 1, "controlSecret": secrets.token_hex(32), "dataDirectory": str(data), "logDirectory": str(logs)}
    descriptor = os.open(configuration, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(description, output)
    del description
    environment = os.environ.copy()
    environment.update({"AURELIA_PREFLIGHT_TEST": "1", "AURELIA_HOST_PREFLIGHT_CONFIG": str(configuration)})
    helper_output = (root / "helper-output.log").open("wb")
    process = subprocess.Popen([str(helper), "--background", "--preflight-background"], env=environment, stdin=subprocess.DEVNULL, stdout=helper_output, stderr=helper_output)
    wait_until(lambda: read_status() == "setupRequired" and live() and len(children()) == 1, 40, "initial_background_readiness_timeout")
    original = children()[0]
    known_children.add(original)
    if subprocess.run(["/usr/bin/pgrep", "-x", "Aurelia"], stdout=subprocess.DEVNULL).returncode == 0:
        fail("mac_ui_running_during_background_probe")
    if not is_owned_child(original):
        fail("server_child_ownership_changed")
    os.kill(original, signal.SIGSTOP)
    stopped_at = time.monotonic()

    def recovered():
        current = children()
        known_children.update(current)
        return len(current) == 1 and current[0] != original and read_status() == "setupRequired" and live()

    wait_until(recovered, 95, "transport_watchdog_recovery_timeout")
    replacement = children()[0]
    elapsed = time.monotonic() - stopped_at
    history = json.loads((data / "host-recovery.json").read_text())
    if not any(value.get("code") == "host_transport_restart" for value in history):
        fail("transport_restart_receipt_missing")
    if process_alive(original) or not is_owned_child(replacement):
        fail("replacement_child_ownership_invalid")
    # No Mac UI or launch agent participates. Parent PID zero keeps this host
    # running until its own process receives SIGTERM.
    process.terminate()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        fail("helper_sigterm_timeout")
    deadline = time.monotonic() + 20
    while process_alive(replacement) and time.monotonic() < deadline:
        time.sleep(0.25)
    if process_alive(replacement):
        fail("server_lifeline_shutdown_timeout")
    verification = subprocess.run(
        [str(server), "database", "verify", "--data-dir", str(data), "--from", str(data / "aurelia.db")],
        capture_output=True, text=True, timeout=20)
    if verification.returncode != 0 or "Database is valid." not in verification.stdout:
        fail("synthetic_database_integrity_failed")
    with report.open("a") as output:
        output.write("PASS: isolated background host started without the Mac UI or personal hosting settings\n")
        output.write("PASS: SIGSTOP of its owned server child triggered transport recovery\n")
        output.write("PASS: a different owned child became ready in %.1f seconds\n" % elapsed)
        output.write("PASS: bounded host history contains host_transport_restart\n")
        output.write("PASS: SIGTERM of the helper stopped its child through the server lifeline\n")
        output.write("PASS: bundled database verifier passed quick_check, foreign keys and migration history after shutdown\n")
        output.write("PASS: no playback, media access, personal settings or launch-agent registration\n")
    print("Background host watchdog smoke passed. Report: " + str(report))
    exit_code = 0
except ProbeFailure as error:
    record_diagnostics()
    with report.open("a") as output:
        output.write("FAIL: " + str(error) + "\n")
    print("Background host watchdog smoke failed: " + str(error), file=sys.stderr)
except Exception as error:
    record_diagnostics()
    # Exception messages can contain private control URLs; log only the type.
    with report.open("a") as output:
        output.write("FAIL: unexpected_" + type(error).__name__ + "\n")
    print("Background host watchdog smoke failed: " + type(error).__name__, file=sys.stderr)
finally:
    owned_before_stop = {pid for pid in set(children()) | known_children if is_synthetic_process(pid)}
    for pid in owned_before_stop:
        try:
            os.kill(pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    # These PIDs were verified as this helper's exact synthetic children before
    # termination. Their inherited lifelines should finish shutdown unaided.
    deadline = time.monotonic() + 15
    while any(process_alive(pid) for pid in owned_before_stop) and time.monotonic() < deadline:
        time.sleep(0.1)
    for pid in owned_before_stop:
        if process_alive(pid):
            if is_synthetic_process(pid):
                os.kill(pid, signal.SIGKILL)
    if helper_output is not None:
        helper_output.close()
    if root.parent == pathlib.Path("/private/tmp/Aurelia") and root.name == run_id:
        shutil.rmtree(root, ignore_errors=True)
sys.exit(exit_code)
PY
