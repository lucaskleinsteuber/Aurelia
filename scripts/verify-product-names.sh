#!/bin/sh
# The current product is Tarven. It was called Aurelia until Server 3.0.0 and Mac 2.30.0 (and before
# that by a two-word label). The old names stay only in the files below: migration and
# compatibility code (LegacyNames, LegacyAppData, AureliaHandover, the legacy header, cookie, mDNS,
# Keychain and configuration fallbacks), the Aurelia-Server bridge packages, frozen values,
# historical changelog entries and the Aurelia Classic rules. A new file that names Aurelia fails here.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"
allowed='
  docs/LINUX_UPDATE_SIGNING.md
  scripts/publish-linux-app-release.sh
  scripts/promote-release.sh
  scripts/test-linux-server-takeover.sh
  scripts/test-linux-server-install.sh
  docs/README.md
  docs/DOCKER.md
  docs/RENAMED.md
  README.md
  AGENTS.md
  CHANGELOG.md
  clients/ios/Configuration/TarvenIOS-Info.plist
  clients/ios/TarvenIOS/Core/IOSAPIClient.swift
  clients/ios/TarvenIOS/Core/IOSBonjourBrowser.swift
  clients/ios/TarvenIOS/Core/IOSSecurity.swift
  clients/ios/TarvenIOS/Core/IOSStreamRelay.swift
  clients/linux/Tarven.Linux.Core/Api/ServerTransport.cs
  clients/linux/Tarven.Linux.Core/Api/TarvenApi.cs
  clients/linux/Tarven.Linux.Core/Connection/ServerDiscovery.cs
  clients/linux/Tarven.Linux.Core/Management/ManagementClient.cs
  clients/linux/Tarven.Linux.Core/Platform/SecretServiceCredentialStore.cs
  clients/linux/Tarven.Linux.Core/Playback/LoopbackStreamRelay.cs
  clients/linux/Tarven.Linux.Core/Settings/LegacyAppData.cs
  clients/linux/Tarven.Linux.Core/Updates/UpdateFeed.cs
  clients/linux/Tarven.Linux.Tests/AppUpdateTests.cs
  clients/linux/Tarven.Linux.Tests/LegacyAppDataTests.cs
  clients/linux/Tarven.Linux/Program.cs
  clients/macos/Configuration/Tarven-Info.plist
  clients/macos/Configuration/Tarven.entitlements
  clients/macos/Tarven/Hosting/ServerDataMigrator.swift
  clients/macos/Tarven/Models/SecurityModels.swift
  clients/macos/Tarven/Networking/APIClient.swift
  clients/macos/Tarven/Networking/BonjourBrowser.swift
  clients/macos/Tarven/Networking/LoopbackStreamRelay.swift
  clients/macos/Tarven/Security/AureliaHandover.swift
  clients/macos/Tarven/Security/KeychainServerStore.swift
  clients/macos/Tarven/TarvenApp.swift
  clients/macos/Tarven/Updates/AppUpdateLogic.swift
  clients/macos/TarvenServerHost/ServerHostMain.swift
  clients/macos/TarvenTests/AppUpdateLogicTests.swift
  clients/macos/TarvenTests/AureliaHandoverTests.swift
  clients/macos/TarvenTests/ServerDiscoveryTests.swift
  clients/macos/TarvenTests/ServerSecurityTests.swift
  clients/macos/TarvenTests/TarvenTests.swift
  clients/macos/TarvenTests/TestEditionIsolationTests.swift
  clients/macos/TarvenTests/UpdateSigningFixture.swift
  clients/tvos/Configuration/TarvenTV-Info.plist
  clients/tvos/TarvenTV/Core/TVAPIClient.swift
  clients/tvos/TarvenTV/Core/TVBonjourBrowser.swift
  clients/tvos/TarvenTV/Core/TVSecurity.swift
  clients/tvos/TarvenTV/Core/TVStreamRelay.swift
  docs/CLIENT_PROTOCOL.md
  docs/LINUX_APP.md
  docs/SECURITY_MODEL.md
  docs/SERVER_MOVE.md
  docs/UPDATE_TEST.md
  packaging/docker/Dockerfile
  packaging/docker/tarven
  packaging/linux/get-aurelia.sh
  packaging/linux/get-tarven.sh
  packaging/linux/install.sh
  scripts/build-linux-server.sh
  scripts/build-macos-release.sh
  scripts/package-linux-app.sh
  scripts/publish-release.sh
  scripts/verify-profileless-macos-entitlements.sh
  src/Tarven.Server/Authentication/WebCookies.cs
  src/Tarven.Server/Program.cs
  src/Tarven.Server/Services/BonjourAdvertisementService.cs
  src/Tarven.Server/Services/DeviceAuthorizationService.cs
  src/Tarven.Server/Services/EncryptedBackupContainer.cs
  src/Tarven.Server/Services/LegacyNames.cs
  src/Tarven.Server/Services/PasskeyService.cs
  src/Tarven.Server/Services/ServerCommandLine.cs
  src/Tarven.Server/Services/ServerMoveCrypto.cs
  src/Tarven.Server/Services/ServerRuntimeOptions.cs
  src/Tarven.Server/WebApp/js/legacy-storage.js
  src/Tarven.Server/WebApp/js/server-move-view.js
  src/Tarven.Server/WebApp/js/settings-admin.js
  tests/Tarven.Server.Tests/LegacyNamesTests.cs
  tests/WebApp/legacy-storage.test.mjs
  tests/Website/releases.test.mjs
'
status=0
# git grep needs no extra tool; --untracked also checks new files that are not ignored yet.
for file in $(git grep --untracked -I -l -i aurelia -- . ':!Local' ':!scripts/verify-product-names.sh' || true); do
  case "$allowed" in
    *"
  $file
"*) ;;
    *) echo "Unexpected old product name (Aurelia) in $file"; status=1 ;;
  esac
done
for path in $(git ls-files --cached --others --exclude-standard | grep -i aurelia || true); do
  case "$path" in
    packaging/linux/get-aurelia.sh|clients/macos/Tarven/Security/AureliaHandover.swift|clients/macos/TarvenTests/AureliaHandoverTests.swift) ;;
    *) echo "Unexpected old product name (Aurelia) in the path $path"; status=1 ;;
  esac
done
[ "$status" -eq 0 ] || exit 1
echo "Current product names and compatibility allowlist verified."
