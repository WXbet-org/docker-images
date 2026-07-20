#!/bin/bash
# Container entrypoint: seed dotfiles on an empty $HOME bind-mount, start
# sshd in the background, then exec the CMD.
#
# Runs as the `builder` user; sudo is passwordless so we can start sshd
# and generate host keys on first start.
set -euo pipefail

# The host mount at /home/builder shadows the base image's dotfiles from
# /etc/skel on first start (mount = empty dir). Seed them so the shell
# behaves normally. -n so user customisations survive subsequent starts.
for f in .bashrc .profile .bash_logout; do
    [ -f "/etc/skel/$f" ] && cp -n "/etc/skel/$f" "$HOME/$f" 2>/dev/null || true
done

# Seed a git identity if the user hasn't set one. Many OE recipe scripts
# (patch application via `git am`, submodule updates) require an author
# to be configured or they fail silently mid-run.
if [ ! -f "$HOME/.gitconfig" ]; then
    git config --global user.email "builder@dreamos-buildsystem.local"
    git config --global user.name  "dreamos-buildsystem builder"
fi

# Rewrite SSH URLs for github.com to https:// so clones of public forks
# work without an SSH key mounted into the container. Both the short
# form (`git@github.com:owner/repo`) and the long form used by bitbake's
# git fetcher when `protocol=ssh` is set (`ssh://git@github.com/owner/repo`)
# need to be caught.
#
# --unset-all + --add pattern makes the setup idempotent across restarts
# (no duplicate entries pile up in ~/.gitconfig).
#
# To use real SSH instead, run:
#   git config --global --unset-all url."https://github.com/".insteadOf
git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
git config --global --add       url."https://github.com/".insteadOf "git@github.com:"
git config --global --add       url."https://github.com/".insteadOf "ssh://git@github.com/"

# Generate host keys on first start (idempotent -- only creates missing ones).
if [ ! -f /etc/ssh/ssh_host_ed25519_key ] || [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    sudo ssh-keygen -A >/dev/null
fi

# sshd needs /run/sshd to exist (tmpfs is empty at container start).
sudo mkdir -p /run/sshd

# Start sshd unless already running (allows `docker exec` re-entry).
if ! pgrep -x sshd >/dev/null 2>&1; then
    sudo /usr/sbin/sshd
fi

# Auto-bootstrap the standard four BuildEnv checkouts on the very first
# container start (marker in $HOME so the host bind-mount persists it).
# To re-trigger later: `rm ~/.auto-bootstrap-done` and restart.
# To skip entirely on first start: run with `-e AUTO_BOOTSTRAP=0`.
if [ "${AUTO_BOOTSTRAP:-1}" != "0" ] && [ ! -f "$HOME/.auto-bootstrap-done" ]; then
    echo "==============================================================="
    echo "  First-time setup: auto-bootstrapping the 4 standard BuildEnvs"
    echo "  This takes several minutes (git clone + make update x4)."
    echo "  Set AUTO_BOOTSTRAP=0 to skip. Marker: ~/.auto-bootstrap-done"
    echo "==============================================================="
    export GIT_TERMINAL_PROMPT=0   # no interactive prompts if a URL fails
    for entry in \
        "opendreambox:krogoth" \
        "opendreambox:pyro" \
        "dreamlegacy:krogoth" \
        "dreamlegacy:pyro"; do
        fork="${entry%%:*}"
        branch="${entry##*:}"
        echo
        echo ">>> bootstrap-buildenv $fork $branch"
        bootstrap-buildenv "$fork" "$branch" </dev/null \
            || echo "!!! bootstrap-buildenv $fork $branch FAILED -- continuing"
    done
    touch "$HOME/.auto-bootstrap-done"
    echo
    echo "==============================================================="
    echo "  Auto-bootstrap complete."
    echo "==============================================================="
fi

exec "$@"
