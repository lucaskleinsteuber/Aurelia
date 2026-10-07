#!/bin/sh
# The current product is Aurelia; old identifiers are migration inputs only.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"
matches=$(rg --no-heading --with-filename --only-matching \
  'Aurelia Home Server|Aurelia Home|AureliaHome|aurelia-home|aureliahome|AURELIA_HOME' \
  --glob '!scripts/verify-product-names.sh' --glob '!docs/LEGACY_COMPATIBILITY.md' . || test "$?" -eq 1)
printf '%s\n' "$matches" | awk -F: '
  BEGIN {
    allow["./src/Aurelia.Server/Services/BonjourAdvertisementService.cs:aurelia-home"] = 1
    allow["./src/Aurelia.Server/Services/ServerRuntimeOptions.cs:AureliaHome"] = 1
    allow["./src/Aurelia.Server/Services/ServerRuntimeOptions.cs:AURELIA_HOME"] = 1
    allow["./clients/macos/Aurelia/Security/KeychainServerStore.swift:aureliahome"] = 1
    allow["./clients/macos/Configuration/Aurelia-Info.plist:aurelia-home"] = 1
    allow["./clients/macos/Configuration/Aurelia.entitlements:aureliahome"] = 1
    allow["./clients/macos/Aurelia/Hosting/ServerDataMigrator.swift:aurelia-home"] = 1
    allow["./clients/macos/Aurelia/Hosting/ServerDataMigrator.swift:Aurelia Home Server"] = 1
    allow["./clients/macos/Aurelia/Networking/BonjourBrowser.swift:aurelia-home"] = 1
    allow["./clients/macos/AureliaTests/AureliaTests.swift:aurelia-home"] = 1
    allow["./clients/macos/AureliaTests/AureliaTests.swift:Aurelia Home Server"] = 1
  }
  NF && !allow[$0] { print "Unexpected retired product label: " $0; failed = 1 }
  END { exit failed }
'
echo "Current product names and compatibility allowlist verified."
