#!/bin/bash
# Aurelia is now called Tarven. This address of the one-line installer keeps working:
#   curl -fsSL https://raw.githubusercontent.com/lucaskleinsteuber/Tarven/main/packaging/linux/get-aurelia.sh | sudo bash
# It runs get-tarven.sh, which installs Tarven Server or takes an Aurelia Server installation over.
# Everything runs inside main, called on the last line, so a download that breaks off does not run.
main() {
  set -euo pipefail
  local address=https://raw.githubusercontent.com/lucaskleinsteuber/Tarven/main/packaging/linux/get-tarven.sh
  local script
  script=$(curl -fsSL --proto '=https' --retry 3 "$address")
  bash -c "$script"
}
main "$@"
