#!/bin/zsh
# Validate a caller-supplied local Apple Development identity before a long build.
# The temporary verifier is never executed and no installed bundle is changed.
set -euo pipefail
repository_root=${0:A:h:h}
signing_identity=${1:-}
team_identifier=${2:-}
verification_root=${3:-}
if [[ ${#signing_identity} -ne 40 || "$signing_identity" == *[^0-9A-F]* \
  || -z "$team_identifier" || -z "$verification_root" || -e "$verification_root" ]]; then
  print -u2 "Provide an available Apple Development SHA-1 identity, the expected team, and a fresh verification directory."
  exit 2
fi
if ! /usr/bin/security find-identity -v -p codesigning \
  | /usr/bin/awk -v identity="$signing_identity" \
    '$2 == identity && /Apple Development:/ { found = 1 } END { exit !found }'; then
  print -u2 "The selected Apple Development identity is unavailable or invalid."
  exit 1
fi
mkdir -m 700 "$verification_root"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" /usr/bin/xcrun swiftc -warnings-as-errors \
  "$repository_root/tools/macos/ProfilelessSigningProbe.swift" \
  -o "$verification_root/identity-verifier"
/usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
  "$verification_root/identity-verifier"
/usr/bin/codesign --verify --strict "$verification_root/identity-verifier"
actual_team=$(/usr/bin/codesign --display --verbose=4 "$verification_root/identity-verifier" 2>&1 \
  | /usr/bin/sed -n 's/^TeamIdentifier=//p')
if [[ "$actual_team" != "$team_identifier" ]]; then
  print -u2 "The signing team does not match Aurelia's existing App Group identity."
  exit 1
fi
/usr/bin/codesign --display --extract-certificates="$verification_root/certificate-" \
  "$verification_root/identity-verifier" 2>/dev/null
/usr/bin/openssl x509 -inform DER -in "$verification_root/certificate-0" -checkend 0 -noout
print "Profileless local development still depends on this certificate's validity:"
/usr/bin/openssl x509 -inform DER -in "$verification_root/certificate-0" -noout -dates
