#!/bin/sh
# Removes old generated output so the Local workspace does not grow without bound.
# Build and test scripts call this before they write anything new. It keeps:
#   - the newest numbered Mac build ("Build <n>") and the newest tvOS and Linux build
#     (AURELIA_KEEP_BUILDS, default 1 each); every release is on GitHub;
#   - .NET configurations/frameworks/RIDs used in the last seven days, for incremental builds;
#     shared restore files at the project level stay. Older whole units are pruned only while
#     no .NET build/test tool or executable from this build cache is running;
#   - the newest test result bundles (AURELIA_KEEP_TEST_RESULTS, default 10);
#   - logs from the last 30 days;
#   - one-off output in Build/ and test run folders from the last day, so a run in progress is
#     never touched.
# It never touches the Package Cache, the build summaries or anything outside these folders.
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
keep_builds=${AURELIA_KEEP_BUILDS:-1}
keep_results=${AURELIA_KEEP_TEST_RESULTS:-10}
dotnet_days=${AURELIA_DOTNET_CACHE_DAYS:-7}
dry_run=false
workspace_only=false
for option do
  case "$option" in
    --dry-run) dry_run=true ;;
    --workspace-only) workspace_only=true ;;
    *) echo "Usage: $0 [--dry-run] [--workspace-only]" >&2; exit 2 ;;
  esac
done

positive_number() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 5 ] && [ "$1" -ge 1 ]
}
if ! positive_number "$keep_builds" || ! positive_number "$keep_results" || ! positive_number "$dotnet_days"; then
  echo "Workspace retention values must be positive integers of at most five digits." >&2
  exit 2
fi
# Normalize leading zeros before shell arithmetic (which otherwise treats them as octal).
keep_builds=$(expr "$keep_builds" + 0)
keep_results=$(expr "$keep_results" + 0)
dotnet_days=$(expr "$dotnet_days" + 0)

case "$other_root" in
  "" | / | "$HOME" | "$HOME/")
    echo "Refusing to prune the workspace at '$other_root'." >&2
    exit 1
    ;;
esac
[ -d "$other_root" ] || exit 0
if [ -L "$other_root" ]; then
  echo "Refusing to prune a symlink workspace: $other_root" >&2
  exit 1
fi
logical_root=$(CDPATH= cd -- "$other_root" && pwd -L)
physical_root=$(CDPATH= cd -- "$other_root" && pwd -P)
if [ "$logical_root" != "$physical_root" ]; then
  echo "Refusing a workspace reached through symlinks: $other_root" >&2
  exit 1
fi
other_root=$physical_root
case "$other_root" in / | "$HOME" | "$HOME/") echo "Refusing unsafe workspace." >&2; exit 1 ;; esac

real_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  physical_directory=$(CDPATH= cd -- "$1" 2>/dev/null && pwd -P) || return 1
  [ "$physical_directory" = "$1" ]
}

remove_entry() {
  parent=$1
  entry=$2
  case "$entry" in "$parent"/*) ;; *) echo "Refusing out-of-scope cleanup." >&2; exit 1 ;; esac
  relative=${entry#"$parent"/}
  case "$relative" in '' | . | .. | ../* | */../* | */..) return ;; esac
  # Never traverse a linked subtree, even if it is named like generated output.
  [ ! -L "$entry" ] || return 0
  if "$dry_run"; then printf 'Would remove: %s\n' "$entry"; else rm -rf -- "$entry"; fi
}

# ls/read is used only for these ordinary generated names. If a directory has a newline in
# an entry name, fail closed rather than interpreting its fragments as separate paths.
simple_names() {
  for entry in "$1"/*; do
    case "$entry" in *'
'*) return 1 ;; esac
  done
}

# Removes every line of stdin after the first $1, each a name inside directory $2.
remove_all_but() {
  limit=$1
  directory=$2
  count=0
  while IFS= read -r name; do
    case "$name" in '' | . | .. | */*) continue ;; esac
    [ ! -L "$directory/$name" ] || continue
    count=$((count + 1))
    [ "$count" -le "$limit" ] || remove_entry "$directory" "$directory/$name"
  done
}

old_entries() {
  directory=$1
  days=$2
  real_directory "$directory" || return 0
  if "$dry_run"; then
    find "$directory" -mindepth 1 -maxdepth 1 -mtime "+$days" ! -type l -print
  else
    find "$directory" -mindepth 1 -maxdepth 1 -mtime "+$days" ! -type l -exec rm -rf -- {} +
  fi
}

dotnet_is_busy() {
  # Executable names only: process arguments can contain credentials. Long-lived installed
  # Aurelia servers do not block cleanup; only an executable inside this build cache does.
  processes=$(ps -A -o pid=,comm= 2>/dev/null) || return 0
  if printf '%s\n' "$processes" | awk -v cache="$other_root/Build/" '
    { path=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", path); name=path; sub(/^.*\//, "", name)
      if (name == "dotnet" || name == "MSBuild" || name == "VBCSCompiler" || name ~ /^testhost(\.|$)/ || index(path, cache) == 1) busy=1 }
    END { exit !busy }'; then return 0; fi
  # Linux ps reports a basename for comm. Resolve only server executable links, never argv.
  if [ -d /proc ]; then
    server_pids=$(printf '%s\n' "$processes" | awk '$2 ~ /^Aurelia\.Server/ { print $1 }')
    for server_pid in $server_pids; do
      executable=$(readlink "/proc/$server_pid/exe" 2>/dev/null) || continue
      case "$executable" in "$other_root/Build/"*) return 0 ;; esac
    done
  fi
  return 1
}

idle_unit() {
  unit=$1
  real_directory "$unit" || return 1
  # A directory's mtime alone misses writes to existing descendants. Any recent entry protects
  # the entire unit; dependencies inside a usable output are never deleted piecemeal.
  recent=$(find "$unit" -mtime "-$dotnet_days" -print -quit 2>/dev/null) || return 1
  [ -z "$recent" ] || return 1
  remove_entry "$other_root/Build" "$unit"
  return 0
}

prune_dotnet() {
  if dotnet_is_busy; then
    "$dry_run" && echo "Keeping .NET caches while build/test tools are running."
    return 0
  fi
  for cache in "$other_root/Build/bin" "$other_root/Build/obj"; do
    real_directory "$cache" || continue
    for project in "$cache"/*; do
      real_directory "$project" || continue
      for configuration in "$project"/*; do
        real_directory "$configuration" || continue
        for framework in "$configuration"/net[0-9]*; do
          real_directory "$framework" || continue
          # Check the parent first: deleting an old RID updates its parent's mtime and must
          # not accidentally protect an otherwise entirely stale framework for another week.
          if idle_unit "$framework"; then continue; fi
          for runtime in "$framework"/*; do
            case "${runtime##*/}" in linux-* | osx-* | win-* | freebsd-* | browser-* | android-* | ios-* | tvos-* | maccatalyst-*) idle_unit "$runtime" || true ;; esac
          done
        done
      done
    done
  done
}

build="$other_root/Build"
if real_directory "$build"; then
  if simple_names "$build"; then
    ls "$build" | grep -E '^Build [0-9]+$' | sort -k2 -n -r | remove_all_but "$keep_builds" "$build"
  fi
  for platform in tvOS Linux; do
    if real_directory "$build/$platform" && simple_names "$build/$platform"; then
      ls -t "$build/$platform" | remove_all_but "$keep_builds" "$build/$platform"
    fi
  done
  if "$dry_run"; then
    find "$build" -mindepth 1 -maxdepth 1 ! -name 'Build [0-9]*' ! -name tvOS ! -name Linux \
      ! -name bin ! -name obj ! -type l -mtime +1 -print
  else
    find "$build" -mindepth 1 -maxdepth 1 ! -name 'Build [0-9]*' ! -name tvOS ! -name Linux \
      ! -name bin ! -name obj ! -type l -mtime +1 -exec rm -rf -- {} +
  fi
  prune_dotnet
fi

results="$other_root/Test Results"
if real_directory "$results" && simple_names "$results"; then
  ls -t "$results" | remove_all_but "$keep_results" "$results"
fi
if real_directory "$other_root/Logs"; then
  if "$dry_run"; then
    find "$other_root/Logs" -type f -mtime +30 -print
  else
    find "$other_root/Logs" -type f -mtime +30 -delete
  fi
fi

if ! "$workspace_only" && [ "$(uname -s)" = Darwin ]; then
  for runs in "$HOME/Library/Caches/Aurelia/TestRuns" /private/tmp/Aurelia; do
    old_entries "$runs" 0
  done
fi
exit 0
