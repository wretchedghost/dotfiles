#!/usr/bin/env bash
#
# onboarding.sh - v1.0.0
#
# Fresh-host onboarding script for Wayne's Debian/Ubuntu fleet.
#
# What it does:
#   1. Installs core packages: vim, tmux, mosh, tailscale, syncthing,
#      openssh-server, openssh-client, rsync, git, sudo
#   2. Generates an ed25519 SSH keypair for the target user (skips if one
#      already exists)
#   3. Clones github.com/wretchedghost/dotfiles and symlinks top-level
#      dotfiles into the target user's home (existing files backed up,
#      never clobbered)
#   4. Sets vim as the default editor (update-alternatives, EDITOR/VISUAL,
#      git core.editor)
#   5. Ensures the target user is a member of the sudo group
#   6. Enables/starts sshd, tailscaled, and syncthing@<user>
#
# Usage:
#   sudo ./onboarding.sh <target-username>
#
# Must be run as root (or via sudo), and the target user must already
# exist (create with `adduser <username>` first if it doesn't).
# Idempotent -- safe to re-run.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "Run this as root, e.g.: sudo $0 <username>"
  exit 1
fi

TARGET_USER="${1:-}"
if [[ -z "$TARGET_USER" ]]; then
  err "Usage: $0 <target-username>"
  exit 1
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  err "User '$TARGET_USER' does not exist. Create it first: adduser $TARGET_USER"
  exit 1
fi

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
DOTFILES_REPO="https://github.com/wretchedghost/dotfiles.git"
DOTFILES_DIR="$TARGET_HOME/.dotfiles"

if [[ ! -d "$TARGET_HOME" ]]; then
  err "Home directory $TARGET_HOME not found for user $TARGET_USER"
  exit 1
fi

log "Onboarding host for user: $TARGET_USER ($TARGET_HOME)"

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
log "Updating package index..."
apt-get update -qq

log "Installing base packages..."
apt-get install -y \
  vim \
  tmux \
  mosh \
  openssh-server \
  openssh-client \
  rsync \
  git \
  sudo \
  curl \
  gpg \
  apt-transport-https

# ---------------------------------------------------------------------------
# 2. Tailscale (official install script)
# ---------------------------------------------------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
  log "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
else
  log "Tailscale already installed, skipping."
fi

# ---------------------------------------------------------------------------
# 3. Syncthing (official apt repo)
# ---------------------------------------------------------------------------
if ! command -v syncthing >/dev/null 2>&1; then
  log "Adding Syncthing apt repo and installing..."
  curl -fsSL https://syncthing.net/release-key.gpg | \
    gpg --dearmor -o /usr/share/keyrings/syncthing-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net syncthing stable" \
    > /etc/apt/sources.list.d/syncthing.list
  apt-get update -qq
  apt-get install -y syncthing
else
  log "Syncthing already installed, skipping."
fi

# ---------------------------------------------------------------------------
# 4. SSH ed25519 keypair
# ---------------------------------------------------------------------------
SSH_DIR="$TARGET_HOME/.ssh"
KEY_PATH="$SSH_DIR/id_ed25519"

sudo -u "$TARGET_USER" mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$KEY_PATH" ]]; then
  log "SSH ed25519 key already exists at $KEY_PATH, skipping generation."
else
  log "Generating ed25519 SSH keypair..."
  sudo -u "$TARGET_USER" ssh-keygen -t ed25519 \
    -C "${TARGET_USER}@$(hostname)-$(date +%Y%m%d)" \
    -f "$KEY_PATH" -N ""
fi

# ---------------------------------------------------------------------------
# 5. Dotfiles
# ---------------------------------------------------------------------------
if [[ -d "$DOTFILES_DIR/.git" ]]; then
  log "Dotfiles repo already present, pulling latest..."
  sudo -u "$TARGET_USER" git -C "$DOTFILES_DIR" pull --ff-only
else
  log "Cloning dotfiles repo..."
  sudo -u "$TARGET_USER" git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi

log "Symlinking dotfiles into $TARGET_HOME..."
BACKUP_DIR="$TARGET_HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
backed_up=false

shopt -s dotglob
for src in "$DOTFILES_DIR"/*; do
  name=$(basename "$src")

  # Skip repo/meta files that aren't meant to be symlinked into $HOME
  case "$name" in
    .git|README*|LICENSE*|install.sh|.gitignore)
      continue
      ;;
  esac

  dest="$TARGET_HOME/$name"

  if [[ -L "$dest" ]]; then
    # Already a symlink -- just re-point it at the current repo copy
    ln -sfn "$src" "$dest"
  elif [[ -e "$dest" ]]; then
    if ! $backed_up; then
      sudo -u "$TARGET_USER" mkdir -p "$BACKUP_DIR"
      backed_up=true
    fi
    warn "Backing up existing $name -> $BACKUP_DIR/"
    mv "$dest" "$BACKUP_DIR/"
    sudo -u "$TARGET_USER" ln -s "$src" "$dest"
  else
    sudo -u "$TARGET_USER" ln -s "$src" "$dest"
  fi
done
shopt -u dotglob

chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR" "$DOTFILES_DIR"
[[ "$backed_up" == true ]] && chown -R "$TARGET_USER:$TARGET_USER" "$BACKUP_DIR"

# ---------------------------------------------------------------------------
# 6. Vim as default editor
# ---------------------------------------------------------------------------
log "Setting vim as default editor..."
update-alternatives --set editor "$(command -v vim)" 2>/dev/null || true
update-alternatives --set vi "$(command -v vim)" 2>/dev/null || true

sudo -u "$TARGET_USER" git config --global core.editor vim

BASHRC="$TARGET_HOME/.bashrc"
if ! grep -q '^export EDITOR=vim' "$BASHRC" 2>/dev/null; then
  {
    echo ''
    echo '# Set by onboarding.sh'
    echo 'export EDITOR=vim'
    echo 'export VISUAL=vim'
  } | sudo -u "$TARGET_USER" tee -a "$BASHRC" >/dev/null
fi

# ---------------------------------------------------------------------------
# 7. Sudo group membership
# ---------------------------------------------------------------------------
if id -nG "$TARGET_USER" | grep -qw sudo; then
  log "$TARGET_USER is already in the sudo group."
else
  log "Adding $TARGET_USER to the sudo group..."
  usermod -aG sudo "$TARGET_USER"
  warn "Group change requires a fresh login/session for $TARGET_USER to take effect."
fi

# ---------------------------------------------------------------------------
# 8. Enable services
# ---------------------------------------------------------------------------
log "Enabling services (sshd, tailscaled, syncthing)..."
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
systemctl enable --now tailscaled 2>/dev/null || true
systemctl enable --now "syncthing@${TARGET_USER}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
log "Onboarding complete for $TARGET_USER on $(hostname)."
echo
echo "  Public key (add to GitHub / authorized_keys elsewhere):"
echo "  ------------------------------------------------------"
cat "$KEY_PATH.pub"
echo "  ------------------------------------------------------"
echo
echo "  Next manual steps:"
echo "    - tailscale up                (authenticate this node)"
echo "    - open http://<host>:8384     (pair Syncthing devices)"
echo "    - log out/in as $TARGET_USER  (for the sudo group change to apply)"
if [[ "$backed_up" == true ]]; then
  echo "    - review backed-up pre-existing dotfiles in: $BACKUP_DIR"
fi
