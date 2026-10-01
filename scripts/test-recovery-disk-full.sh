#!/bin/zsh
set -euo pipefail
repository_root=${0:A:h:h}
other_root=${AURELIA_OTHER_ROOT:-"${repository_root:h}/Aurelia Other"}
dotnet_bin=${DOTNET_BIN:-"$other_root/Package Cache/dotnet/dotnet"}
run_root=$(mktemp -d "$other_root/Build/.recovery-probe.XXXXXX")
image="$run_root/DisposableRecovery.dmg"
mount="$run_root/Mount"
cleanup() {
  set +e
  /usr/bin/hdiutil detach "$mount" >/dev/null 2>&1
  [[ "$run_root" == "$other_root/Build/.recovery-probe."* ]] && find "$run_root" -depth -delete
}
trap cleanup EXIT
mkdir -p "$mount"
/usr/bin/hdiutil create -size 128m -fs HFS+ -volname AureliaRecoveryProbe "$image" >/dev/null
/usr/bin/hdiutil attach -nobrowse -mountpoint "$mount" "$image" >/dev/null
env NUGET_PACKAGES="$other_root/Package Cache/NuGet" "$dotnet_bin" run \
  --project "$repository_root/tools/Aurelia.Server.RecoveryProbe" -- "$mount"
