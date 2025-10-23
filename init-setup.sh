#!/bin/bash

# init-setup.sh
# Universal Linux initial server/desktop setup script
# Supports: Debian/Ubuntu (apt), Arch Linux (pacman)

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Detect distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_FAMILY=$ID_LIKE
    else
        error "Cannot detect OS. /etc/os-release not found"
    fi

    # Determine package manager
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt-get update"
        PKG_UPGRADE="apt-get upgrade -y"
        PKG_INSTALL="apt-get install -y"
        info "Detected Debian-based system (using apt)"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
        PKG_UPDATE="pacman -Sy"
        PKG_UPGRADE="pacman -Syu --noconfirm"
        PKG_INSTALL="pacman -S --noconfirm"
        info "Detected Arch-based system (using pacman)"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf check-update || true"  # check-update returns 100 when updates available
        PKG_UPGRADE="dnf upgrade -y"
        PKG_INSTALL="dnf install -y"
        info "Detected Fedora-based system (using dnf)"
    elif command -v zypper &> /dev/null; then
        PKG_MANAGER="zypper"
        PKG_UPDATE="zypper refresh"
        PKG_UPGRADE="zypper update -y"
        PKG_INSTALL="zypper install -y"
        info "Detected openSUSE-based system (using zypper)"
    else
        error "Unsupported package manager. This script supports apt, pacman, dnf, and zypper"
    fi
}

# Map package names for different distributions
get_package_name() {
    local generic_name=$1
    
    case "$PKG_MANAGER" in
        "pacman")
            case "$generic_name" in
                "openssh-server") echo "openssh" ;;
                "ufw") echo "ufw" ;;
                "neofetch") 
                    # neofetch is deprecated in Arch, use fastfetch instead
                    echo "fastfetch" 
                    ;;
                *) echo "$generic_name" ;;
            esac
            ;;
        "apt")
            case "$generic_name" in
                "openssh") echo "openssh-server" ;;
                *) echo "$generic_name" ;;
            esac
            ;;
        *)
            echo "$generic_name"
            ;;
    esac
}

# Check if running as root
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "This script must be run as root or with sudo"
    fi
}

# Get the actual user
get_actual_user() {
    # First try SUDO_USER
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        ACTUAL_USER="$SUDO_USER"
        USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
    # Then try DOAS_USER (for systems using doas instead of sudo)
    elif [ -n "${DOAS_USER:-}" ] && [ "$DOAS_USER" != "root" ]; then
        ACTUAL_USER="$DOAS_USER"
        USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
    # If running directly as root, prompt for username
    else
        read -p "Enter the username for setup: " ACTUAL_USER
        USER_HOME="/home/$ACTUAL_USER"
    fi

    if ! id "$ACTUAL_USER" &>/dev/null; then
        error "User $ACTUAL_USER does not exist"
    fi

    log "Setting up for user: $ACTUAL_USER"
    log "User home directory: $USER_HOME"
}

# Update system
update_system() {
    log "Updating system packages..."
    
    case "$PKG_MANAGER" in
        "pacman")
            # Update keyring first on Arch to avoid signature issues
            $PKG_INSTALL archlinux-keyring 2>/dev/null || true
            ;;
    esac
    
    $PKG_UPDATE || error "Failed to update package database"
    
    read -p "Do you want to upgrade all system packages? [y/n]: " do_upgrade
    if [[ "$do_upgrade" =~ ^[Yy]$ ]]; then
        $PKG_UPGRADE || error "Failed to upgrade system"
    else
        log "Skipping system upgrade"
    fi
}

# Install packages
install_packages() {
    log "Installing essential packages..."
    
    # Base packages (generic names)
    BASE_PACKAGES="vim tmux rsync sudo git curl"
    
    # Distribution-specific packages
    case "$PKG_MANAGER" in
        "pacman")
            BASE_PACKAGES="$BASE_PACKAGES base-devel"
            ;;
        "apt")
            BASE_PACKAGES="$BASE_PACKAGES build-essential"
            ;;
    esac
    
    # Add optional packages based on user choice
    read -p "Install system info tool (neofetch/fastfetch)? [y/n]: " install_fetch
    if [[ "$install_fetch" =~ ^[Yy]$ ]]; then
        BASE_PACKAGES="$BASE_PACKAGES neofetch"
    fi
    
    read -p "Install SSH server? [y/n]: " install_ssh
    if [[ "$install_ssh" =~ ^[Yy]$ ]]; then
        BASE_PACKAGES="$BASE_PACKAGES openssh-server"
    fi
    
    read -p "Install UFW firewall? [y/n]: " install_ufw
    if [[ "$install_ufw" =~ ^[Yy]$ ]]; then
        BASE_PACKAGES="$BASE_PACKAGES ufw"
    fi
    
    # Convert generic names to distro-specific names and install
    TRANSLATED_PACKAGES=""
    for package in $BASE_PACKAGES; do
        TRANSLATED_PACKAGES="$TRANSLATED_PACKAGES $(get_package_name $package)"
    done
    
    log "Installing: $TRANSLATED_PACKAGES"
    $PKG_INSTALL $TRANSLATED_PACKAGES || warn "Some packages may have failed to install"
    
    # Enable SSH service if installed
    if [[ "$install_ssh" =~ ^[Yy]$ ]]; then
        enable_ssh_service
    fi
}

# Enable SSH service
enable_ssh_service() {
    log "Enabling SSH service..."
    
    if command -v systemctl &> /dev/null; then
        systemctl enable --now sshd 2>/dev/null || \
        systemctl enable --now ssh 2>/dev/null || \
        warn "Could not enable SSH service"
    elif command -v rc-update &> /dev/null; then
        rc-update add sshd default 2>/dev/null || \
        warn "Could not enable SSH service"
    fi
}

# Generate SSH key
generate_ssh_key() {
    SSH_KEY_PATH="$USER_HOME/.ssh/id_ed25519"
    
    if [ ! -f "$SSH_KEY_PATH" ]; then
        log "Generating SSH key for $ACTUAL_USER..."
        sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/.ssh"
        sudo -u "$ACTUAL_USER" chmod 700 "$USER_HOME/.ssh"
        
        read -p "Do you want to set a passphrase for the SSH key? (recommended) [y/n]: " set_passphrase
        if [[ "$set_passphrase" =~ ^[Yy]$ ]]; then
            sudo -u "$ACTUAL_USER" ssh-keygen -t ed25519 -f "$SSH_KEY_PATH"
        else
            warn "Creating SSH key without passphrase (less secure)"
            sudo -u "$ACTUAL_USER" ssh-keygen -t ed25519 -N '' -f "$SSH_KEY_PATH"
        fi
        
        # Set proper permissions
        sudo -u "$ACTUAL_USER" chmod 600 "$SSH_KEY_PATH"
        sudo -u "$ACTUAL_USER" chmod 644 "$SSH_KEY_PATH.pub"
    else
        log "SSH key already exists, skipping generation"
    fi
}

# Setup dotfiles
setup_dotfiles() {
    log "Setting up dotfiles..."
    
    # Allow custom repo URL
    read -p "Enter dotfiles repo URL [default: https://github.com/wretchedghost/wretchedghost_dotfiles]: " custom_repo
    DOTFILES_REPO="${custom_repo:-https://github.com/wretchedghost/wretchedghost_dotfiles}"
    
    GIT_DIR="$USER_HOME/git"
    DOTFILES_DIR="$GIT_DIR/$(basename $DOTFILES_REPO .git)"
    
    # Create git directory and clone repo as the actual user
    if [ ! -d "$DOTFILES_DIR" ]; then
        sudo -u "$ACTUAL_USER" mkdir -p "$GIT_DIR"
        sudo -u "$ACTUAL_USER" git clone "$DOTFILES_REPO" "$DOTFILES_DIR" || error "Failed to clone dotfiles"
    else
        log "Dotfiles already cloned, pulling latest changes..."
        sudo -u "$ACTUAL_USER" bash -c "cd '$DOTFILES_DIR' && git pull" || warn "Failed to pull latest dotfiles"
    fi
    
    # Backup existing configs before overwriting
    log "Backing up existing configs..."
    BACKUP_DIR="$USER_HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"
    sudo -u "$ACTUAL_USER" mkdir -p "$BACKUP_DIR"
    
    # Find all dotfiles in the repo
    cd "$DOTFILES_DIR"
    for item in .[^.]*; do
        if [ -e "$item" ] && [ "$item" != ".git" ] && [ "$item" != ".gitignore" ]; then
            if [ -e "$USER_HOME/$item" ]; then
                sudo -u "$ACTUAL_USER" cp -r "$USER_HOME/$item" "$BACKUP_DIR/" 2>/dev/null || true
            fi
        fi
    done
    
    # Sync dotfiles to home directory
    log "Syncing dotfiles to home directory..."
    sudo -u "$ACTUAL_USER" rsync -av --exclude='.git' --exclude='.gitignore' --exclude='README.md' \
        --exclude='*.sh' --exclude='LICENSE' \
        . "$USER_HOME/" || warn "Some files may not have been copied"
    
    log "Configs backed up to: $BACKUP_DIR"
}

# Install AUR helper for Arch
install_aur_helper() {
    if [ "$PKG_MANAGER" = "pacman" ]; then
        read -p "Do you want to install an AUR helper (yay)? [y/n]: " install_aur
        if [[ "$install_aur" =~ ^[Yy]$ ]]; then
            log "Installing yay AUR helper..."
            
            # Install as the actual user, not root
            temp_dir="/tmp/yay-install-$$"
            sudo -u "$ACTUAL_USER" mkdir -p "$temp_dir"
            cd "$temp_dir"
            
            sudo -u "$ACTUAL_USER" git clone https://aur.archlinux.org/yay.git
            cd yay
            sudo -u "$ACTUAL_USER" makepkg -si --noconfirm
            
            cd /
            rm -rf "$temp_dir"
            
            log "AUR helper (yay) installed successfully"
        fi
    fi
}

# Install Tailscale
install_tailscale() {
    while true; do
        read -p "Do you want to install Tailscale? [y/n]: " response
        case "$response" in 
            [Yy]* )
                log "Installing Tailscale..."
                
                if ! command -v tailscale &> /dev/null; then
                    case "$PKG_MANAGER" in
                        "pacman")
                            # Check if yay is available for AUR installation
                            if command -v yay &> /dev/null; then
                                sudo -u "$ACTUAL_USER" yay -S --noconfirm tailscale
                            else
                                $PKG_INSTALL tailscale
                            fi
                            systemctl enable --now tailscaled
                            ;;
                        *)
                            # Use official install script for other distros
                            TAILSCALE_SCRIPT="/tmp/tailscale-install.sh"
                            curl -fsSL https://tailscale.com/install.sh -o "$TAILSCALE_SCRIPT" || error "Failed to download Tailscale installer"
                            bash "$TAILSCALE_SCRIPT" || error "Failed to install Tailscale"
                            rm -f "$TAILSCALE_SCRIPT"
                            ;;
                    esac
                else
                    log "Tailscale already installed"
                fi
                
                log "Starting Tailscale..."
                tailscale up
                break
                ;;
            [Nn]* )
                log "Skipping Tailscale installation"
                break
                ;;
            *)
                echo "Invalid input. Please answer 'y' or 'n'."
                ;;
        esac
    done
}

# Configure UFW firewall
configure_ufw() {
    if command -v ufw &> /dev/null; then
        read -p "Do you want to configure basic UFW firewall rules? [y/n]: " setup_ufw
        if [[ "$setup_ufw" =~ ^[Yy]$ ]]; then
            log "Configuring UFW..."
            
            # Allow SSH
            ufw allow OpenSSH 2>/dev/null || ufw allow 22/tcp
            
            # Allow Tailscale if installed
            if command -v tailscale &> /dev/null; then
                ufw allow 41641/udp 2>/dev/null || true
            fi
            
            # Enable UFW
            ufw --force enable
            log "UFW enabled with SSH allowed"
        fi
    fi
}

# Main installation flow
main() {
    clear
    echo "=========================================="
    echo "     Universal Linux Setup Script"
    echo "=========================================="
    echo
    
    # Check root privileges
    check_root
    
    # Detect distribution
    detect_distro
    
    # Get actual user
    get_actual_user
    
    # Update system
    update_system
    
    # Install packages
    install_packages
    
    # Generate SSH key
    read -p "Generate SSH key for $ACTUAL_USER? [y/n]: " gen_ssh
    if [[ "$gen_ssh" =~ ^[Yy]$ ]]; then
        generate_ssh_key
    fi
    
    # Setup dotfiles
    read -p "Setup dotfiles from git repository? [y/n]: " setup_dots
    if [[ "$setup_dots" =~ ^[Yy]$ ]]; then
        setup_dotfiles
    fi
    
    # Install AUR helper (Arch only)
    install_aur_helper
    
    # Install Tailscale
    install_tailscale
    
    # Configure UFW
    configure_ufw
    
    log "Setup complete!"
    echo
    echo "=========================================="
    echo "Remember to:"
    echo "  1. Source your new bashrc: source ~/.bashrc"
    echo "  2. Review and adjust firewall rules if needed"
    echo "  3. Add your SSH public key to authorized_keys on remote servers"
    if [ "$PKG_MANAGER" = "pacman" ]; then
        echo "  4. Consider enabling multilib repository in /etc/pacman.conf if needed"
    fi
    echo "=========================================="
}

# Run main function
main "$@"
