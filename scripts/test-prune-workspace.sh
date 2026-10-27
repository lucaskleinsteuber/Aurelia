#!/bin/sh
# Isolated retention tests. No real workspace, user cache or smoke directory is pruned.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
parent="$HOME/Library/Caches/Aurelia/TestRuns"
mkdir -p "$parent"
run_root=$(mktemp -d "$parent/prune-workspace.XXXXXX")
trap 'rm -rf -- "$run_root"' EXIT HUP INT TERM
workspace="$run_root/Workspace with spaces"
tools="$run_root/tools"
outside="$run_root/Outside sentinel"
mkdir -p "$workspace/Build" "$tools" "$outside"
printf 'keep\n' >"$outside/sentinel"
cat >"$tools/ps" <<'EOF'
#!/bin/sh
case "${PRUNE_TEST_PROCESS:-idle}" in
  build) printf '100 /synthetic/sdk/dotnet\n' ;;
  installed) printf '100 /Applications/Aurelia.app/Contents/Resources/Server/Aurelia.Server\n' ;;
  cache) printf '100 %s/Build/bin/Test/Release/net10.0/Aurelia.Server\n' "$AURELIA_OTHER_ROOT" ;;
  fail) exit 1 ;;
esac
EOF
chmod 0755 "$tools/ps"

prune() {
  AURELIA_OTHER_ROOT="$workspace" PATH="$tools:$PATH" sh "$repository_root/scripts/prune-workspace.sh" --workspace-only "$@"
}
old_tree() { find "$1" -exec touch -t 200001010000 {} +; }
exists() { [ -e "$1" ] || { echo "Missing protected fixture: $1" >&2; exit 1; }; }
absent() { [ ! -e "$1" ] || { echo "Stale fixture retained: $1" >&2; exit 1; }; }

for build in 1 2 3; do mkdir -p "$workspace/Build/Build $build"; done
for platform in tvOS Linux; do
  mkdir -p "$workspace/Build/$platform/old" "$workspace/Build/$platform/new"
  old_tree "$workspace/Build/$platform/old"
done
mkdir -p "$workspace/Test Results" "$workspace/Logs" "$workspace/Build/bin/Test/Debug/net10.0/linux-x64" \
  "$workspace/Build/bin/Test/Debug/net10.0/osx-arm64" "$workspace/Build/obj/Test/Release/net9.0/linux-x64" \
  "$workspace/Package Cache" "$workspace/Aurelia Build summarys" "$workspace/LinuxServer"
printf 'stale\n' >"$workspace/Build/bin/Test/Debug/net10.0/linux-x64/output"
printf 'recent\n' >"$workspace/Build/bin/Test/Debug/net10.0/osx-arm64/output"
printf 'stale\n' >"$workspace/Build/obj/Test/Release/net9.0/output"
printf 'stale RID\n' >"$workspace/Build/obj/Test/Release/net9.0/linux-x64/output"
old_tree "$workspace/Build/bin"
old_tree "$workspace/Build/obj"
# Updating an existing nested file does not update its ancestors' mtime.
touch "$workspace/Build/bin/Test/Debug/net10.0/osx-arm64/output"
printf 'restore metadata\n' >"$workspace/Build/obj/Test/project.assets.json"
for number in 01 02 03 04 05 06 07 08 09 10 11 12; do
  mkdir -p "$workspace/Test Results/Result $number"
  touch -t "20000101${number}00" "$workspace/Test Results/Result $number"
done
printf 'old\n' >"$workspace/Logs/old.log"
touch -t 200001010000 "$workspace/Logs/old.log"
printf 'new\n' >"$workspace/Logs/new.log"
for folder in 'Package Cache' 'Aurelia Build summarys' LinuxServer; do printf 'keep\n' >"$workspace/$folder/sentinel"; done
ln -s "$outside" "$workspace/Logs/linked"
ln -s "$outside" "$workspace/Build/bin/LinkedProject"

prune --dry-run >"$run_root/dry-run.txt"
exists "$workspace/Build/Build 1"
exists "$workspace/Logs/old.log"
exists "$workspace/Build/obj/Test/Release/net9.0/output"
PRUNE_TEST_PROCESS=build prune
exists "$workspace/Build/bin/Test/Debug/net10.0/linux-x64/output"
exists "$workspace/Build/obj/Test/Release/net9.0/output"
PRUNE_TEST_PROCESS=cache prune
exists "$workspace/Build/obj/Test/Release/net9.0/output"
PRUNE_TEST_PROCESS=fail prune
exists "$workspace/Build/obj/Test/Release/net9.0/output"
PRUNE_TEST_PROCESS=installed prune
absent "$workspace/Build/Build 1"
absent "$workspace/Build/Build 2"
exists "$workspace/Build/Build 3"
for platform in tvOS Linux; do
  absent "$workspace/Build/$platform/old"
  exists "$workspace/Build/$platform/new"
done
absent "$workspace/Test Results/Result 01"
absent "$workspace/Test Results/Result 02"
exists "$workspace/Test Results/Result 03"
exists "$workspace/Test Results/Result 12"
absent "$workspace/Logs/old.log"
exists "$workspace/Logs/new.log"
absent "$workspace/Build/bin/Test/Debug/net10.0/linux-x64"
absent "$workspace/Build/obj/Test/Release/net9.0"
exists "$workspace/Build/bin/Test/Debug/net10.0/osx-arm64/output"
exists "$workspace/Build/obj/Test/project.assets.json"
exists "$outside/sentinel"
for folder in 'Package Cache' 'Aurelia Build summarys' LinuxServer; do exists "$workspace/$folder/sentinel"; done

# Linked managed subtrees are skipped, and a linked workspace root is rejected entirely.
linked="$run_root/Linked workspace"
ln -s "$workspace" "$linked"
if AURELIA_OTHER_ROOT="$linked" sh "$repository_root/scripts/prune-workspace.sh" --workspace-only >/dev/null 2>&1; then
  echo "A linked workspace must be refused." >&2; exit 1
fi
if AURELIA_KEEP_BUILDS=0 prune >/dev/null 2>&1; then
  echo "An unsafe retention count must be refused." >&2; exit 1
fi
echo "Passed workspace retention, idle .NET units, active process, dry-run and symlink-boundary tests."
