#!/usr/bin/env bash
#==============================================================================
# OpenClaw Provisioning Script — Hetzner Minimal VDS
# OpenRouter + Kimi K2.5 Configuration
#
# Optimized for Hetzner CX/CAX minimal Ubuntu images where:
#   - dbus-user-session is missing (breaks user systemd)
#   - Kernel updates require reboot before apt can continue
#   - 'su -' doesn't give a proper dbus session (must SSH directly)
#
# Usage:
#   1. SSH into your fresh Hetzner VDS as root
#   2. Upload or paste this script
#   3. Run:
#        export OPENROUTER_API_KEY="sk-or-your-key-here"
#        bash openclaw-setup.sh
#
# Safe to run multiple times — skips completed steps.
#==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

#==============================================================================
# CONFIGURATION
#==============================================================================

OPENROUTER_KEY="${OPENROUTER_API_KEY:-}"
PRIMARY_MODEL="openrouter/moonshotai/kimi-k2.5"
FALLBACK_1="openrouter/moonshotai/kimi-k2-0905"
FALLBACK_2="openrouter/google/gemini-2.5-flash"
OC_USER="openclaw"
GATEWAY_PORT=18789
SSH_PORT=22

#==============================================================================
# PRE-FLIGHT
#==============================================================================

echo ""
echo "=============================================="
echo "  OpenClaw — Hetzner Minimal VDS Setup"
echo "  OpenRouter + Kimi K2.5"
echo "=============================================="
echo ""

[[ -z "$OPENROUTER_KEY" ]] && err "OPENROUTER_API_KEY not set.\n  export OPENROUTER_API_KEY=\"sk-or-your-key-here\""
command -v apt &>/dev/null || err "This script requires apt (Ubuntu/Debian)."

info "API key: ${OPENROUTER_KEY:0:12}...${OPENROUTER_KEY: -4}"
info "Primary model: $PRIMARY_MODEL"
echo ""

#==============================================================================
# PHASE 1: System update — reboot if kernel changed
#
# On Hetzner minimal images, apt upgrade often pulls a new kernel.
# dpkg/apt will hang on subsequent installs until you reboot.
# We detect this and auto-reboot, resuming via @reboot cron.
#==============================================================================

# Are we resuming after a reboot?
if [[ -f /tmp/.openclaw-setup-rebooted ]]; then
    log "Resumed after reboot — continuing setup..."
    rm -f /tmp/.openclaw-setup-rebooted
    SCRIPT_PATH=$(readlink -f "$0")
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
else
    log "Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt update -qq
    apt upgrade -y -qq

    if [[ -f /var/run/reboot-required ]]; then
        warn "Kernel updated — rebooting first (apt hangs without this)."

        touch /tmp/.openclaw-setup-rebooted
        SCRIPT_PATH=$(readlink -f "$0")
        CRON_LINE="@reboot OPENROUTER_API_KEY=\"$OPENROUTER_KEY\" bash $SCRIPT_PATH"
        (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_LINE") | crontab -

        log "Rebooting in 3 seconds — script will resume automatically..."
        sleep 3
        reboot
        exit 0
    fi
fi

#==============================================================================
# PHASE 2: Install dependencies
#
# dbus-user-session is CRITICAL on Hetzner minimal images.
# Without it, user-level systemd doesn't work and you get:
#   "Failed to connect to bus: No such file or directory"
# This must be installed BEFORE creating the user or enabling linger.
#==============================================================================

log "Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt install -y -qq \
    curl \
    git \
    build-essential \
    ufw \
    jq \
    unzip \
    dbus-user-session

log "All dependencies installed (including dbus-user-session)"

#==============================================================================
# PHASE 3: Create openclaw user with proper systemd support
#
# Key issues on Hetzner minimal:
#   - 'su - openclaw' does NOT start a dbus session → systemctl --user fails
#   - You MUST SSH directly as the user for user systemd to work
#   - loginctl enable-linger lets user services run without active login
#==============================================================================

if id "$OC_USER" &>/dev/null; then
    info "User '$OC_USER' already exists"
else
    log "Creating user '$OC_USER'..."
    useradd -m -s /bin/bash "$OC_USER"
    usermod -aG sudo "$OC_USER"
    echo "$OC_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$OC_USER
    chmod 440 /etc/sudoers.d/$OC_USER
fi

# Enable linger — required for user systemd services to persist
loginctl enable-linger "$OC_USER"
log "Linger enabled for $OC_USER"

# Set password for SSH login (if not already set)
if passwd -S "$OC_USER" 2>/dev/null | grep -qE " L |NP"; then
    echo ""
    warn "Set a password for '$OC_USER' — needed for SSH login:"
    warn "(user systemd only works via SSH, not 'su -')"
    echo ""
    passwd "$OC_USER"
    echo ""
fi

# Copy root's SSH keys to openclaw user (if they exist)
if [[ -f /root/.ssh/authorized_keys ]]; then
    OC_SSH_DIR="/home/$OC_USER/.ssh"
    mkdir -p "$OC_SSH_DIR"
    cp /root/.ssh/authorized_keys "$OC_SSH_DIR/authorized_keys"
    chown -R "$OC_USER:$OC_USER" "$OC_SSH_DIR"
    chmod 700 "$OC_SSH_DIR"
    chmod 600 "$OC_SSH_DIR/authorized_keys"
    log "Copied SSH keys to $OC_USER — key-based SSH login enabled"
fi

#==============================================================================
# PHASE 4: Firewall
#==============================================================================

log "Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'SSH'
ufw deny "$GATEWAY_PORT" comment 'OpenClaw gateway - localhost only'
ufw --force enable
log "Firewall active"

#==============================================================================
# PHASE 5: Install OpenClaw (as openclaw user)
#==============================================================================

run_as_oc() {
    sudo -u "$OC_USER" bash -c "$1"
}

log "Installing OpenClaw..."
run_as_oc 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard'

# Verify
if run_as_oc 'export PATH="$HOME/.npm-global/bin:$PATH" && openclaw --version' &>/dev/null; then
    OC_VER=$(run_as_oc 'export PATH="$HOME/.npm-global/bin:$PATH" && openclaw --version 2>/dev/null')
    log "OpenClaw installed: $OC_VER"
else
    err "OpenClaw installation failed."
fi

#==============================================================================
# PHASE 6: Write configuration
#
# Config uses JSON5 (comments OK, trailing commas OK).
# Schema is strictly validated — unknown keys prevent gateway from starting.
# Only known-valid keys are used here (verified against zod-schema.ts).
#==============================================================================

log "Writing configuration..."

OC_HOME="/home/$OC_USER"
OC_DIR="$OC_HOME/.openclaw"

run_as_oc "mkdir -p $OC_DIR/credentials $OC_DIR/workspace"

cat > "$OC_DIR/openclaw.json" << OCEOF
{
  // OpenClaw — Hetzner VDS
  // Primary: Kimi K2.5 via OpenRouter
  // Docs: https://docs.openclaw.ai/gateway/configuration

  gateway: {
    port: $GATEWAY_PORT,
    mode: "local",
    bind: "loopback",
    auth: {
      mode: "token"
    }
  },

  env: {
    OPENROUTER_API_KEY: "$OPENROUTER_KEY"
  },

  agents: {
    defaults: {
      model: {
        primary: "$PRIMARY_MODEL",
        fallbacks: [
          "$FALLBACK_1",
          "$FALLBACK_2"
        ]
      },
      models: {
        "$PRIMARY_MODEL": {
          alias: "kimi",
          thinking: "medium"
        },
        "$FALLBACK_1": {
          alias: "kimi-k2"
        }
      }
    }
  }
}
OCEOF

chown -R "$OC_USER:$OC_USER" "$OC_DIR"

log "Configuration written"

#==============================================================================
# PHASE 7: Harden permissions
#==============================================================================

log "Hardening permissions..."
run_as_oc "chmod 700 $OC_DIR"
run_as_oc "chmod 600 $OC_DIR/openclaw.json"
run_as_oc "chmod 700 $OC_DIR/credentials"

#==============================================================================
# PHASE 8: Onboarding
#
# Non-interactive onboard sets up auth profile and installs systemd service.
# This runs as the openclaw user but WITHOUT a proper dbus session
# (we're using sudo, not SSH). So --install-daemon may partially fail.
# That's OK — we handle it in the next phase.
#==============================================================================

log "Running onboarding..."
run_as_oc "export PATH=\"\$HOME/.npm-global/bin:\$PATH\" && \
    openclaw onboard \
    --auth-choice apiKey \
    --token-provider openrouter \
    --token \"$OPENROUTER_KEY\" \
    --install-daemon" 2>/dev/null || {
    warn "Onboarding completed with warnings (expected — no dbus via sudo)."
    warn "Systemd service will be set up when you SSH in as $OC_USER."
}

#==============================================================================
# PHASE 9: Create a helper script for first SSH login
#
# Since we can't fully set up systemd user services from root/sudo,
# this script runs on first SSH login as the openclaw user to finish setup.
#==============================================================================

cat > "$OC_HOME/finish-setup.sh" << 'FINISHEOF'
#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[OK] $1"; }
info() { echo "[i]  $1"; }

export PATH="$HOME/.npm-global/bin:$PATH"

echo ""
echo "Finishing OpenClaw setup (systemd user services)..."
echo ""

# Verify dbus session is available
if systemctl --user status &>/dev/null; then
    log "User systemd session is active"
else
    echo "ERROR: User systemd not available. Make sure you SSH'd in directly"
    echo "       (not via 'su -'). Also verify dbus-user-session is installed."
    exit 1
fi

# Install and start the gateway service
openclaw gateway install 2>/dev/null || true
systemctl --user enable openclaw-gateway 2>/dev/null || true
systemctl --user start openclaw-gateway 2>/dev/null || true

if systemctl --user is-active openclaw-gateway &>/dev/null; then
    log "Gateway service running"
else
    log "Starting gateway manually..."
    openclaw gateway start &
    sleep 3
fi

# Validate config
log "Running doctor..."
openclaw doctor --fix 2>/dev/null || openclaw doctor || true

echo ""
log "Setup complete!"
echo ""
info "Quick commands:"
echo "  openclaw tui              — chat in terminal"
echo "  openclaw doctor           — health check"
echo "  openclaw status           — gateway status"
echo "  openclaw configure        — set up Telegram/Discord/etc"
echo "  openclaw models           — list available models"
echo "  /thinking high            — change thinking level (in chat)"
echo ""
info "Logs:"
echo "  journalctl --user -u openclaw-gateway -f"
echo ""
info "Config:"
echo "  nano ~/.openclaw/openclaw.json"
echo "  systemctl --user restart openclaw-gateway"
echo ""

# Self-destruct
rm -f "$HOME/finish-setup.sh"
FINISHEOF

chown "$OC_USER:$OC_USER" "$OC_HOME/finish-setup.sh"
chmod +x "$OC_HOME/finish-setup.sh"

#==============================================================================
# DONE
#==============================================================================

echo ""
echo "=============================================="
echo "  Phase 1 Complete — SSH in to finish"
echo "=============================================="
echo ""
log "OpenClaw installed and configured"
log "User: $OC_USER"
log "Model: $PRIMARY_MODEL (Kimi K2.5)"
log "Gateway: localhost:$GATEWAY_PORT"
echo ""
warn "IMPORTANT — Complete setup by SSH'ing in as $OC_USER:"
echo ""
echo "    ssh $OC_USER@\$(hostname -I | awk '{print \$1}')"
echo ""
echo "  Then run:"
echo ""
echo "    bash finish-setup.sh"
echo ""
echo "  This starts the gateway service with proper systemd/dbus."
echo "  (Do NOT use 'su - $OC_USER' — systemd won't work.)"
echo ""
echo "=============================================="
echo ""
