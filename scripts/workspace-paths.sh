#!/bin/sh
# Shared by build/test scripts. Generated files never belong in the checkout.
# The workspace is TARVEN_OTHER_ROOT, else the git-ignored Local folder of the checkout, else
# the per-user cache.
if [ -z "${TARVEN_OTHER_ROOT:-}" ] && [ -n "${repository_root:-}" ]; then
  TARVEN_OTHER_ROOT="$repository_root/Local"
  mkdir -p "$TARVEN_OTHER_ROOT"
fi
if [ -z "${TARVEN_OTHER_ROOT:-}" ]; then
  if [ "$(uname -s)" = Darwin ]; then
    TARVEN_OTHER_ROOT="$HOME/Library/Caches/Tarven/Artifacts"
  else
    TARVEN_OTHER_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/Tarven/Artifacts"
  fi
fi
export TARVEN_OTHER_ROOT
other_root=$TARVEN_OTHER_ROOT

if [ -z "${DOTNET_BIN:-}" ]; then
  if command -v dotnet >/dev/null 2>&1; then
    DOTNET_BIN=$(command -v dotnet)
  else
    DOTNET_BIN="$other_root/Package Cache/dotnet/dotnet"
  fi
fi
export DOTNET_BIN

if [ "$(uname -s)" = Darwin ]; then
  developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
fi
