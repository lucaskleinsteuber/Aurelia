#!/bin/bash
# Turn a tested beta (a GitHub pre-release) into the stable release of its product, with the
# same verified downloads. Mac releases become Latest; server and Linux desktop tags stay
# independent. Afterwards record the version in docs/RELEASE_VERSIONS.json.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tag=${1:-}
[ $# -eq 1 ] && [ -n "$tag" ] || { echo "Usage: publish-release.sh --promote <tag>" >&2; exit 1; }
cd "$repository_root"
[ "$(gh release view "$tag" --json isPrerelease --jq .isPrerelease)" = true ] \
  || { echo "$tag is not a beta; nothing to promote." >&2; exit 1; }
[ "$(gh release view "$tag" --json isDraft --jq .isDraft)" = false ] \
  || { echo "$tag is still a draft; publish it as a beta first." >&2; exit 1; }
case "$tag" in
  linux-app-*|server-*) latest=false ;;
  [0-9]*) echo "Mac versions stay betas (owner's decision, 11.11.2026); only Server and Linux app tags are promoted." >&2; exit 1 ;;
  *) latest=true ;;
esac
title=$(gh release view "$tag" --json name --jq .name)
title=${title% Beta}
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
# Drop the beta notice; the rest of the description stays as tested.
gh release view "$tag" --json body --jq .body | python3 -c '
import sys
notice = open(sys.argv[1]).read().strip()
body = sys.stdin.read()
print(body.replace(notice, "", 1).lstrip("\n"), end="")
' "$repository_root/scripts/beta-notice.md" > "$notes"
gh release edit "$tag" --prerelease=false --latest="$latest" --title "$title" --notes-file "$notes"
echo "Promoted $tag to the stable release: $title."
