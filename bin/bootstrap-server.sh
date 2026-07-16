#!/usr/bin/env bash
#
# bootstrap-server.sh - v2.2.0
#
# Fleet base-setup script for Wayne's Debian/Ubuntu servers.
#
# What it does:
#   1. Installs a base package set (chosen interactively or via config)
#   2. Configures unattended-upgrades (security-only or security+updates,
#      optional auto-reboot, optional package blacklist, optional mail report)
#   3. Optionally configures UFW (default deny incoming, SSH + extra ports)
#   4. Optionally configures fail2ban (sshd jail)
#   5. Optionally enables AppArmor
#   6. Optionally enables auditd
#   7. Optionally builds an AIDE file-integrity database + daily check
#
# Usage:
#   sudo ./bootstrap-server.sh                  interactive whiptail wizard
#   sudo ./bootstrap-server.sh --config FILE    unattended, replay saved answers
#
# Run the wizard once locally, save answers to bootstrap.conf, then scp both
# files to each host and loop with --config for fleet rollout.
#
# SSH hardening is intentionally NOT included here - kept as a separate
# script to avoid lockout risk during unattended/looped runs.
#
# Changelog:
#   2.2.0 - guard against launching a second AIDE build on top of one already
#           running in the background (was causing AIDE to exit 21/LOCK_ERROR).
#   2.1.0 - AIDE build no longer blocks the script: excludes Docker/container/
#           VM-disk/bulk-data paths by default (the usual reason it runs for
#           hours instead of minutes) and runs the scan in the background.
#   2.0.0 - added whiptail menu front-end, --config flag to replay saved
#           answers unattended. Install logic is unchanged from 1.0.0.
#   1.0.0 - initial version (hand-edited config block, no menu)
#
set -euo pipefail

SCRIPT_VERSION="2.2.0"
LOG_FILE="/var/log/bootstrap-server.log"

# =============================================================================
# Colors / logging
# =============================================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }
info()  { echo -e "${GREEN}[+]${NC} $*"; log "[INFO] $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; log "[WARN] $*"; }
error() { echo -e "${RED}[x]${NC} $*"; log "[ERROR] $*"; }

[[ $EUID -ne 0 ]] && { error "Run this as root (sudo ./bootstrap-server.sh)."; exit 1; }
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# =============================================================================
# Defaults (used if no wizard and no --config)
# =============================================================================
CONFIG_FILE=""
ASSUME_YES=false
BASE_PACKAGES=(vim htop curl wget git tmux rsync ncdu jq unzip ca-certificates dnsutils net-tools)
UPDATE_ALL_PACKAGES=false
AUTO_REBOOT=false
AUTO_REBOOT_TIME="02:00"
MAIL_ADDRESS=""
SKIP_PACKAGES=()
ENABLE_UFW=true
SSH_PORT=22
EXTRA_ALLOWED_PORTS=()
ENABLE_FAIL2BAN=true
FAIL2BAN_BANTIME=3600
FAIL2BAN_FINDTIME=600
FAIL2BAN_MAXRETRY=5
ENABLE_APPARMOR=true
ENABLE_AUDITD=true
ENABLE_AIDE=true

# =============================================================================
# Argument parsing
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        *)
            error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Menu (whiptail)
# =============================================================================
run_wizard() {
    if ! command -v whiptail >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq whiptail
    fi

    local pkg_selection
    pkg_selection=$(whiptail --title "Base Packages" --checklist \
        "Space to toggle, Enter to confirm" 20 60 13 \
        "vim" "" ON "htop" "" ON "curl" "" ON "wget" "" ON "git" "" ON \
        "tmux" "" ON "rsync" "" ON "ncdu" "" ON "jq" "" ON "unzip" "" ON \
        "ca-certificates" "" ON "dnsutils" "" ON "net-tools" "" ON \
        3>&1 1>&2 2>&3)
    IFS=' ' read -r -a BASE_PACKAGES <<< "${pkg_selection//\"/}"

    local hardening_selection
    hardening_selection=$(whiptail --title "Hardening Features" --checklist \
        "Space to toggle, Enter to confirm" 16 70 5 \
        "UFW" "Firewall" ON \
        "FAIL2BAN" "Ban brute-force SSH attempts" ON \
        "APPARMOR" "Confine what programs can access" ON \
        "AUDITD" "Log security-relevant events" ON \
        "AIDE" "Detect unexpected file changes" ON \
        3>&1 1>&2 2>&3)
    ENABLE_UFW=false; ENABLE_FAIL2BAN=false; ENABLE_APPARMOR=false
    ENABLE_AUDITD=false; ENABLE_AIDE=false
    [[ "$hardening_selection" == *UFW* ]]      && ENABLE_UFW=true
    [[ "$hardening_selection" == *FAIL2BAN* ]] && ENABLE_FAIL2BAN=true
    [[ "$hardening_selection" == *APPARMOR* ]] && ENABLE_APPARMOR=true
    [[ "$hardening_selection" == *AUDITD* ]]   && ENABLE_AUDITD=true
    [[ "$hardening_selection" == *AIDE* ]]     && ENABLE_AIDE=true

    if whiptail --title "Automatic Updates" --yesno \
        "Install security patches only?\n\nChoose No to also install regular/feature updates automatically." 11 60; then
        UPDATE_ALL_PACKAGES=false
    else
        UPDATE_ALL_PACKAGES=true
    fi

    if whiptail --title "Auto Reboot" --yesno \
        "Let the server reboot itself automatically when an update needs it?\n\nSay No for cluster nodes, Proxmox hosts, or anything with a role - you don't want it restarting unattended." 12 70; then
        AUTO_REBOOT=true
        AUTO_REBOOT_TIME=$(whiptail --title "Reboot Time" --inputbox \
            "What time should it reboot, if needed? (24h, HH:MM)" 10 60 "$AUTO_REBOOT_TIME" 3>&1 1>&2 2>&3)
    else
        AUTO_REBOOT=false
    fi

    MAIL_ADDRESS=$(whiptail --title "Mail Reports" --inputbox \
        "Email address for unattended-upgrade error reports (leave blank to skip):" 10 65 "$MAIL_ADDRESS" 3>&1 1>&2 2>&3)

    local skip_input
    skip_input=$(whiptail --title "Package Blacklist" --inputbox \
        "Space-separated packages to NEVER auto-update (leave blank for none):" 10 65 "" 3>&1 1>&2 2>&3)
    read -r -a SKIP_PACKAGES <<< "$skip_input"

    if [[ "$ENABLE_UFW" == true ]]; then
        SSH_PORT=$(whiptail --title "SSH Port" --inputbox \
            "What port is SSH listening on?" 10 60 "$SSH_PORT" 3>&1 1>&2 2>&3)
        local ports_input
        ports_input=$(whiptail --title "Extra Ports" --inputbox \
            "Space-separated extra TCP ports to allow through the firewall (leave blank for none):" 10 65 "" 3>&1 1>&2 2>&3)
        read -r -a EXTRA_ALLOWED_PORTS <<< "$ports_input"
    fi

    if [[ "$ENABLE_FAIL2BAN" == true ]]; then
        FAIL2BAN_BANTIME=$(whiptail --title "fail2ban bantime (seconds)" --inputbox "" 10 60 "$FAIL2BAN_BANTIME" 3>&1 1>&2 2>&3)
        FAIL2BAN_FINDTIME=$(whiptail --title "fail2ban findtime (seconds)" --inputbox "" 10 60 "$FAIL2BAN_FINDTIME" 3>&1 1>&2 2>&3)
        FAIL2BAN_MAXRETRY=$(whiptail --title "fail2ban maxretry" --inputbox "" 10 60 "$FAIL2BAN_MAXRETRY" 3>&1 1>&2 2>&3)
    fi

    local summary
    summary="Packages: ${BASE_PACKAGES[*]}
Security-only updates: $([[ "$UPDATE_ALL_PACKAGES" == true ]] && echo No || echo Yes)
Auto-reboot: $AUTO_REBOOT ($AUTO_REBOOT_TIME)
UFW: $ENABLE_UFW | fail2ban: $ENABLE_FAIL2BAN | AppArmor: $ENABLE_APPARMOR | auditd: $ENABLE_AUDITD | AIDE: $ENABLE_AIDE"

    if ! whiptail --title "Ready?" --yesno "$summary\n\nInstall with these settings?" 18 65; then
        echo "Cancelled."
        exit 0
    fi

    if whiptail --title "Save Answers" --yesno "Save these answers to a file so you can reuse them on other servers unattended?" 10 65; then
        local save_path
        save_path=$(whiptail --title "Save Answers" --inputbox "Save to:" 10 60 "./bootstrap.conf" 3>&1 1>&2 2>&3)
        {
            echo "BASE_PACKAGES=(${BASE_PACKAGES[*]})"
            echo "UPDATE_ALL_PACKAGES=$UPDATE_ALL_PACKAGES"
            echo "AUTO_REBOOT=$AUTO_REBOOT"
            echo "AUTO_REBOOT_TIME=\"$AUTO_REBOOT_TIME\""
            echo "MAIL_ADDRESS=\"$MAIL_ADDRESS\""
            echo "SKIP_PACKAGES=(${SKIP_PACKAGES[*]})"
            echo "ENABLE_UFW=$ENABLE_UFW"
            echo "SSH_PORT=$SSH_PORT"
            echo "EXTRA_ALLOWED_PORTS=(${EXTRA_ALLOWED_PORTS[*]})"
            echo "ENABLE_FAIL2BAN=$ENABLE_FAIL2BAN"
            echo "FAIL2BAN_BANTIME=$FAIL2BAN_BANTIME"
            echo "FAIL2BAN_FINDTIME=$FAIL2BAN_FINDTIME"
            echo "FAIL2BAN_MAXRETRY=$FAIL2BAN_MAXRETRY"
            echo "ENABLE_APPARMOR=$ENABLE_APPARMOR"
            echo "ENABLE_AUDITD=$ENABLE_AUDITD"
            echo "ENABLE_AIDE=$ENABLE_AIDE"
        } > "$save_path"
        info "Saved answers to $save_path"
        echo "Reuse them unattended with: sudo ./bootstrap-server.sh --config $save_path"
    fi
}

if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] || { error "Config file not found: $CONFIG_FILE"; exit 1; }
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    info "Loaded config from $CONFIG_FILE - no prompts, running unattended."
elif [[ -t 0 ]]; then
    run_wizard
else
    warn "No terminal attached and no --config given - using built-in defaults."
fi

info "bootstrap-server.sh v$SCRIPT_VERSION starting. Log: $LOG_FILE"

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" ]]; then
        warn "This doesn't look like Debian or Ubuntu (ID=${ID:-unknown}). Continuing anyway."
    fi
fi

if [[ "$ENABLE_UFW" == true && "$ASSUME_YES" != true ]]; then
    echo ""
    warn "This will enable the firewall and only allow port $SSH_PORT (SSH) plus: ${EXTRA_ALLOWED_PORTS[*]:-none}"
    warn "Make sure that's the port you're actually connected on before continuing."
    read -r -p "Continue? [y/N] " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { echo "Aborted."; exit 0; }
fi

# =============================================================================
# 1. Packages
# =============================================================================
info "Updating package lists and installing packages..."

PACKAGES=("${BASE_PACKAGES[@]}" unattended-upgrades apt-listchanges needrestart)
[[ "$ENABLE_UFW" == true ]]      && PACKAGES+=(ufw)
[[ "$ENABLE_FAIL2BAN" == true ]] && PACKAGES+=(fail2ban)
[[ "$ENABLE_APPARMOR" == true ]] && PACKAGES+=(apparmor apparmor-utils)
[[ "$ENABLE_AUDITD" == true ]]   && PACKAGES+=(auditd audispd-plugins)
[[ "$ENABLE_AIDE" == true ]]     && PACKAGES+=(aide aide-common)

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq "${PACKAGES[@]}"
info "Packages installed: ${PACKAGES[*]}"

# =============================================================================
# 2. Unattended-upgrades
# =============================================================================
info "Configuring automatic updates..."

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Managed by bootstrap-server.sh - regenerated on every run, don't hand-edit.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

UU_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"

cat > "$UU_CONF" <<EOF
// Managed by bootstrap-server.sh v$SCRIPT_VERSION - regenerated on every run, don't hand-edit.
// Covers both Debian and Ubuntu origin names so this file works on either.

Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=\${distro_codename},label=Debian-Security";
    "o=Ubuntu,a=\${distro_codename}-security";
    "o=UbuntuESMApps,a=\${distro_codename}-apps-security";
    "o=UbuntuESM,a=\${distro_codename}-infra-security";
EOF

if [[ "$UPDATE_ALL_PACKAGES" == true ]]; then
cat >> "$UU_CONF" <<EOF
    "origin=Debian,codename=\${distro_codename},label=Debian";
    "origin=Debian,codename=\${distro_codename}-updates";
    "o=Ubuntu,a=\${distro_codename}-updates";
EOF
fi

echo "};" >> "$UU_CONF"

if [[ ${#SKIP_PACKAGES[@]} -gt 0 ]]; then
    {
        echo ""
        echo "Unattended-Upgrade::Package-Blacklist {"
        for pkg in "${SKIP_PACKAGES[@]}"; do
            echo "    \"$pkg\";"
        done
        echo "};"
    } >> "$UU_CONF"
fi

{
    echo ""
    echo "Unattended-Upgrade::Remove-Unused-Kernel-Packages \"true\";"
    echo "Unattended-Upgrade::Remove-Unused-Dependencies \"true\";"
    echo "Unattended-Upgrade::Automatic-Reboot \"$AUTO_REBOOT\";"
    echo "Unattended-Upgrade::Automatic-Reboot-Time \"$AUTO_REBOOT_TIME\";"
} >> "$UU_CONF"

if [[ -n "$MAIL_ADDRESS" ]]; then
    {
        echo ""
        echo "Unattended-Upgrade::Mail \"$MAIL_ADDRESS\";"
        echo "Unattended-Upgrade::MailReport \"only-on-error\";"
    } >> "$UU_CONF"
fi

# needrestart: list affected services instead of auto-restarting them or
# prompting interactively (a prompt would hang the automatic update run).
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/90-bootstrap.conf <<'EOF'
$nrconf{restart} = 'l';
EOF

systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
info "Automatic updates configured (security-only: $([[ "$UPDATE_ALL_PACKAGES" == true ]] && echo no || echo yes), auto-reboot: $AUTO_REBOOT)."

# =============================================================================
# 3. Firewall
# =============================================================================
if [[ "$ENABLE_UFW" == true ]]; then
    info "Configuring firewall..."
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow "$SSH_PORT"/tcp >/dev/null
    for port in "${EXTRA_ALLOWED_PORTS[@]}"; do
        [[ -n "$port" ]] && ufw allow "$port"/tcp >/dev/null
    done
    ufw --force enable >/dev/null
    info "Firewall enabled. Allowed: $SSH_PORT/tcp ${EXTRA_ALLOWED_PORTS[*]:-}"
fi

# =============================================================================
# 4. fail2ban
# =============================================================================
if [[ "$ENABLE_FAIL2BAN" == true ]]; then
    info "Configuring fail2ban..."
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = $FAIL2BAN_BANTIME
findtime = $FAIL2BAN_FINDTIME
maxretry = $FAIL2BAN_MAXRETRY

[sshd]
enabled = true
port    = $SSH_PORT
EOF
    systemctl enable --now fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    info "fail2ban enabled (ban ${FAIL2BAN_BANTIME}s after ${FAIL2BAN_MAXRETRY} failures in ${FAIL2BAN_FINDTIME}s)."
fi

# =============================================================================
# 5. AppArmor
# =============================================================================
if [[ "$ENABLE_APPARMOR" == true ]]; then
    systemctl enable --now apparmor >/dev/null 2>&1
    info "AppArmor enabled."
fi

# =============================================================================
# 6. auditd
# =============================================================================
if [[ "$ENABLE_AUDITD" == true ]]; then
    systemctl enable --now auditd >/dev/null 2>&1
    info "auditd enabled."
fi

# =============================================================================
# 7. AIDE (file integrity monitoring)
# =============================================================================
if [[ "$ENABLE_AIDE" == true ]]; then
    # Exclude paths that are large, volatile, and not meaningful to integrity-
    # check: container storage, VM disks, bulk data mounts. Without this,
    # aideinit can run for hours on any box running Docker/Proxmox/a NAS role.
    mkdir -p /etc/aide/aide.conf.d
    cat > /etc/aide/aide.conf.d/98_excludes.conf <<'EOF'
!/var/lib/docker
!/var/lib/containerd
!/var/lib/vz
!/mnt
!/srv
EOF

    # The initial scan can still take a long time on a big filesystem even
    # with the excludes above, so it runs in the background instead of
    # blocking the rest of this script. Guard against launching a second
    # one on top of an already-running build - AIDE exits with LOCK_ERROR
    # (21) if two instances fight over the same database file.
    if pgrep -x aide >/dev/null 2>&1; then
        warn "An AIDE process is already running (pid $(pgrep -x aide | tr '\n' ' ')) - skipping, to avoid a lock conflict. Check progress: tail -f /var/log/aide-init.log"
    elif command -v aideinit >/dev/null 2>&1; then
        nohup bash -c '
            aideinit >/var/log/aide-init.log 2>&1
            if [[ -f /var/lib/aide/aide.db.new ]]; then
                cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
                logger -t bootstrap-aide "AIDE database build finished."
            fi
        ' >/dev/null 2>&1 &
        disown
        info "AIDE database build started in the background (pid $!). Progress: tail -f /var/log/aide-init.log"
    fi

    cat > /etc/cron.daily/aide-check <<'EOF'
#!/bin/bash
[[ -f /var/lib/aide/aide.db ]] && /usr/bin/aide.wrapper --check | logger -t aide-check
EOF
    chmod +x /etc/cron.daily/aide-check
    info "Daily integrity check installed at /etc/cron.daily/aide-check (skips itself until the first database build finishes)."
fi

# =============================================================================
# Done
# =============================================================================
echo ""
info "Done. Log: $LOG_FILE"
