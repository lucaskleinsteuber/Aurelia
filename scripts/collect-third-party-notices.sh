#!/bin/zsh
set -euo pipefail

# Read the published dependency graph, not a hand-maintained list of binaries.
repository_root=${0:A:h:h}
deps=${1:?Provide the published Aurelia.Server.deps.json.}
assets=${2:?Provide the matching project.assets.json.}
destination=${3:?Provide an external notices directory.}
mkdir -p "$destination"
cp "$repository_root/THIRD_PARTY_NOTICES.md" "$destination/README.md"
while IFS= read -r dependency; do
  package=${dependency%/*}
  version=${dependency##*/}
  package=${package#runtimepack.}
  package_directory=''
  while IFS= read -r package_root; do
    proposed="$package_root/${(L)package}/$version"
    if [[ -d "$proposed" ]]; then package_directory="$proposed"; break; fi
  done < <(jq -r '.packageFolders | keys[]' "$assets")
  [[ -n "$package_directory" ]] || {
    echo "Missing resolved package for notices: $dependency" >&2; exit 1
  }
  target="$destination/$package-$version"
  mkdir -p "$target"
  for notice in "$package_directory"/*(N.); do
    case ${(L)notice:t} in
      license*|*third*notices*|*.nuspec) cp "$notice" "$target/" ;;
    esac
  done
  case "$package/$version" in
    Haukcode.Mdns/1.0.18) cp "$repository_root/docs/licenses/Haukcode.Mdns-LICENSE.txt" "$target/" ;;
    SQLitePCLRaw.*/2.1.12) cp "$repository_root/docs/licenses/SQLitePCLRaw-"*.txt "$target/" ;;
    Haukcode.Mdns/*|SQLitePCLRaw.*/*)
      echo "Review upstream notices for the changed dependency: $dependency" >&2; exit 1 ;;
  esac
done < <(jq -r '.libraries | to_entries[] | select(.value.type != "project") | .key' "$deps")
