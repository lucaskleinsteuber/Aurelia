# Signing Linux updates

Aurelia for Linux installs an update through the distribution's package manager, which runs as
root. A SHA-256 list published next to the package only proves that the download arrived intact:
anyone who can change the GitHub release (a stolen token, a compromised workflow) can replace the
package and its checksum together. The app therefore installs an update only when the release's
`SHA256SUMS` carries a [minisign](https://jedisct1.github.io/minisign/) signature made with the
owner's secret key. That key never goes to GitHub.

The Mac app does not need this: its update helper checks Apple's code signature and the team.

## One-time setup

1. Install minisign: `brew install minisign`.
2. Create the key pair, protected by a password:

   ```sh
   mkdir -p ~/.minisign
   minisign -G -p ~/.minisign/aurelia-linux.pub -s ~/.minisign/aurelia-linux.key
   ```

3. Back up `~/.minisign/aurelia-linux.key` and its password somewhere safe and offline. Without
   it no further Linux update can be installed automatically; a new key needs a manually
   installed app version.
4. Copy the second line of `~/.minisign/aurelia-linux.pub` (it starts with `RW`) into
   `SigningPublicKey` in `clients/linux/Aurelia.Linux.Core/Updates/UpdateFeed.cs` and commit it.

While `SigningPublicKey` is empty, a build installs no update at all and says so.

## Every release

`scripts/publish-linux-app-release.sh` signs `SHA256SUMS` with the secret key
(`AURELIA_MINISIGN_SECRET_KEY`, default `~/.minisign/aurelia-linux.key`, asks for its password),
checks the signature against the public key in `UpdateFeed.cs`, and only then uploads
`SHA256SUMS.minisig` with the packages. A release without a valid signature is shown in the app
but never installed.

## Moving to signed updates

Versions before this change do not check signatures and still install the next release normally.
The first version that contains the public key must reach each computer that way (or by hand);
from then on every update needs the signature.

## Linux server

The Linux server is updated by `sudo aurelia update` (also when the Mac app asks for it), installed
by the one-line `get-aurelia.sh` and built into the Docker image by `packaging/docker/fetch-server.sh`.
All three run as root and use the same key: `scripts/publish-release.sh --server` signs the server
release's `SHA256SUMS` the same way, checks the signature against `signing_public_key` in
`packaging/linux/aurelia` and uploads `SHA256SUMS.minisig` with the packages. The three scripts
check it with openssl, so servers need no minisign. They carry the same key and the same check;
`scripts/test-server-update-signature.sh` makes sure of that and that the key is the Linux app's.

Server builds before `first_signed_build` (153) were published without a signature and stay
installable by build number; every later build needs one. Servers with an older `aurelia` command
install the first signed version the old way and check signatures from then on.
