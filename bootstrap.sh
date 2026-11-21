#!/bin/bash
# bootstrap.sh: the first step of rebuilding CFS-SERVER01 on a fresh Ubuntu Server (media guide, 5.10).
# Public on purpose: it holds no secrets. It asks for the two it needs, from Proton Pass:
#   CFS-SERVER01 · deploy key (GitHub)   its private key, to clone the private config repo
#   CFS-SERVER01 · git-crypt key         base64, to unlock the repo's secrets/
# Then it hands over to server-restore. Run as tuckersaurus (not root):  bash bootstrap.sh
set -euo pipefail
REPO_URL=github-cfs:cfs-homelab/cfs-server01.git
DEST=$HOME/cfs-server01
KEY=$HOME/.ssh/cfs-server01-deploy
DEPLOY_FP=SHA256:hnmK1BFAi8OsJf3pKt+giGndTOcUSVg46E548hRqX2k      # tab 8, deploy key
GITCRYPT_ID=179dcbcaea93d234                                     # tab 8: first 16 of the key's sha256

(( EUID != 0 )) || { echo "Run as tuckersaurus, not root (it uses sudo itself)."; exit 2; }
echo "== packages: git, git-crypt, restic, jq, curl"
sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q git git-crypt restic jq curl openssh-client

echo "== GitHub's SSH host keys (from api.github.com over HTTPS)"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
keys=$(curl -fsSL https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com " + .')
[[ -n "$keys" ]] || { echo "could not read GitHub's host keys"; exit 1; }
touch "$HOME/.ssh/known_hosts"
grep -q '^github.com ' "$HOME/.ssh/known_hosts" || printf '%s\n' "$keys" >> "$HOME/.ssh/known_hosts"
chmod 644 "$HOME/.ssh/known_hosts"

if [[ ! -s "$KEY" ]]; then
  echo "== deploy key"
  echo "Copy the private key of 'CFS-SERVER01 · deploy key (GitHub)' from Proton Pass, paste it here, then press Ctrl-D."
  echo "(Nothing shows while you paste.)"
  if [[ -t 0 ]]; then old=$(stty -g); stty -echo; fi
  ( umask 077; cat > "$KEY" ) || true
  if [[ -t 0 ]]; then stty "$old"; fi; echo
  fp=$(ssh-keygen -lf "$KEY" 2>/dev/null | awk '{ print $2 }') || true
  if [[ "$fp" != "$DEPLOY_FP" ]]; then
    rm -f "$KEY"; echo "That isn't the deploy key (fingerprint ${fp:-unreadable}, expected $DEPLOY_FP). Run again."; exit 1
  fi
  echo "deploy key ok: $fp"
fi
if ! grep -q '^Host github-cfs$' "$HOME/.ssh/config" 2>/dev/null; then
  printf 'Host github-cfs\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/cfs-server01-deploy\n  IdentitiesOnly yes\n' >> "$HOME/.ssh/config"
fi
chmod 600 "$HOME/.ssh/config"

if [[ ! -d "$DEST/.git" ]]; then
  echo "== clone $REPO_URL"
  git clone -q "$REPO_URL" "$DEST"
fi
git -C "$DEST" config user.name CFS-SERVER01
git -C "$DEST" config user.email backup@cfs-server01

if [[ -z "$(git -C "$DEST" config --get filter.git-crypt.smudge || true)" ]]; then
  echo "== unlock secrets/"
  read -rsp "Paste 'CFS-SERVER01 · git-crypt key' from Proton Pass (hidden), then Enter: " k || [[ -n "${k:-}" ]]; echo
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  printf '%s' "$k" | base64 -d > "$tmp" 2>/dev/null || true; unset k
  id=$(sha256sum < "$tmp" | cut -c1-16)
  if [[ "$id" != "$GITCRYPT_ID" ]]; then echo "That isn't the git-crypt key (id $id, expected $GITCRYPT_ID). Run again."; exit 1; fi
  git -C "$DEST" crypt unlock "$tmp"
  echo "unlocked"
fi

restore="$DEST/files$HOME/.local/bin/server-restore"
[[ -x "$restore" ]] || { echo "server-restore is not in the repo at $restore (the repo holds /home/tuckersaurus: install with that user name)"; exit 1; }
cat <<NEXT

Bootstrap done. Next, one part at a time (each shows its plan and asks first):
  $restore home
then, in a new shell (exec bash), the rest by name:
  server-restore system
  server-restore storage
  server-restore friend
  server-restore tailscale
  server-restore mail
  server-restore apps
  server-restore jobs
Add --dry-run to any of them to see the plan only.
NEXT
