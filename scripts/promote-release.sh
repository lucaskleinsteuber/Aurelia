#!/bin/bash
# Turn a tested beta (a GitHub pre-release) into the stable release of its product, with the
# same verified downloads. A promoted server becomes GitHub's Latest, which `tarven update`, the
# one-line install and Docker read first; Linux desktop tags stay independent and Mac versions stay
# betas. Afterwards record the version in docs/RELEASE_VERSIONS.json.
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
  server-*) latest=true ;;
  linux-app-*) latest=false ;;
  [0-9]*) echo "Mac versions stay betas (owner's decision, 11.11.2026); only Server and Linux app tags are promoted." >&2; exit 1 ;;
  *) echo "$tag is no Server or Linux app tag." >&2; exit 1 ;;
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
if [[ "$tag" == linux-app-* ]]; then
  # The Linux app installs a stable release only when its signed comment says so (audit C-L14):
  # sign the same SHA256SUMS again for the stable channel before the release turns stable.
  . "$repository_root/scripts/workspace-paths.sh"
  command -v minisign >/dev/null || { echo "Install minisign to promote a Linux app release." >&2; exit 1; }
  signing_key="${TARVEN_MINISIGN_SECRET_KEY:-$HOME/.minisign/tarven-linux.key}"
  # The same key, under the name it was created with before the rename to Tarven.
  [ -n "${TARVEN_MINISIGN_SECRET_KEY:-}" ] || [ -s "$signing_key" ] || signing_key="$HOME/.minisign/aurelia-linux.key"
  [ -s "$signing_key" ] || { echo "Missing the minisign secret key $signing_key." >&2; exit 1; }
  public_key=$(sed -n 's/.*SigningPublicKey = "\([A-Za-z0-9+\/=]*\)";.*/\1/p' \
    "$repository_root/clients/linux/Tarven.Linux.Core/Updates/UpdateFeed.cs")
  repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
  signing=$(mktemp -d)
  trap 'rm -f "$notes"; rm -rf "$signing"' EXIT
  gh release download "$tag" --pattern SHA256SUMS --pattern SHA256SUMS.minisig --dir "$signing"
  minisign -V -P "$public_key" -m "$signing/SHA256SUMS" -x "$signing/SHA256SUMS.minisig" >/dev/null \
    || { echo "The beta's signature is not valid; nothing was promoted." >&2; exit 1; }
  rm -f "$signing/SHA256SUMS.minisig"
  minisign -S -s "$signing_key" -m "$signing/SHA256SUMS" -x "$signing/SHA256SUMS.minisig" \
    -t "$title channel=stable repository=$repository"
  minisign -V -P "$public_key" -m "$signing/SHA256SUMS" -x "$signing/SHA256SUMS.minisig" >/dev/null \
    || { echo "The new signature does not match the app's public key; nothing was promoted." >&2; exit 1; }
  gh release upload "$tag" "$signing/SHA256SUMS.minisig" --clobber
fi
gh release edit "$tag" --prerelease=false --latest="$latest" --title "$title" --notes-file "$notes"
echo "Promoted $tag to the stable release: $title."
