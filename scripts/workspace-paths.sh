#!/bin/sh
# Shared by build/test scripts. Generated files never belong in the checkout.
if [ -z "${AURELIA_OTHER_ROOT:-}" ]; then
  if [ "$(uname -s)" = Darwin ]; then
    AURELIA_OTHER_ROOT="$HOME/Library/Caches/Aurelia/Artifacts"
  else
    AURELIA_OTHER_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/Aurelia/Artifacts"
  fi
fi
export AURELIA_OTHER_ROOT
other_root=$AURELIA_OTHER_ROOT

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
