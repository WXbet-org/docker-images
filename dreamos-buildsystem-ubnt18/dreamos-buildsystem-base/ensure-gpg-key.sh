#!/bin/bash
# Ensure a GPG signing key exists in $HOME/.gnupg/ for optional
# opendreambox package-feed signing (PACKAGE_FEED_SIGN='1').
#
# Idempotent: only generates a key when no keyring is present yet.
# Called from:
#   * entrypoint.sh          -- runs on every container start, so users
#                               that pull a newer image get a key even if
#                               they never re-run bootstrap-buildenv
#   * bootstrap-buildenv     -- safety net for entry via `docker exec` on
#                               a container started before this script
#                               was added to the image
#
# Emits nothing on the reuse path (silence on hot start); prints a short
# banner + "done" line only when a key is actually generated.
set -euo pipefail

GPG_HOME="$HOME/.gnupg"
GPG_PASSPHRASE_FILE="$GPG_HOME/passphrase"

mkdir -p "$GPG_HOME"
chmod 700 "$GPG_HOME"

# Trigger: no keyring exists yet in ~/.gnupg (fresh mount).
# gpg2 uses pubring.kbx, gpg1 pubring.gpg -- if neither is present,
# this homedir has never had a key.
if [ -f "$GPG_HOME/pubring.kbx" ] || [ -f "$GPG_HOME/pubring.gpg" ]; then
    exit 0
fi

echo ">>> No keyring in $GPG_HOME -- generating GPG signing key (~30-60s of entropy)"

GPG_PASS=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
printf '%s\n' "$GPG_PASS" > "$GPG_PASSPHRASE_FILE"
chmod 600 "$GPG_PASSPHRASE_FILE"

gpg --batch --pinentry-mode loopback --generate-key >/dev/null 2>&1 <<GPGEOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: dreamos-buildsystem
Name-Email: builder@dreamos-buildsystem.local
Expire-Date: 0
Passphrase: $GPG_PASS
%commit
GPGEOF

unset GPG_PASS
echo ">>> GPG signing key created; passphrase saved to $GPG_PASSPHRASE_FILE"
