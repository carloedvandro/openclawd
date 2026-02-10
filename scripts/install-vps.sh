#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# OpenClaw VPS Installer (Ollama Edition)
# Usage: bash <(curl -sSL https://your-domain/install-vps.sh)
# ============================================================================

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

OPENCLAW_DIR="/opt/openclaw"
OPENCLAW_STATE_DIR="$HOME/.openclaw"
OPENCLAW_CONFIG="$OPENCLAW_STATE_DIR/openclaw.json"
OPENCLAW_SERVICE="openclaw-gateway"
NODE_MIN_VERSION=22

banner() {
  echo -e "${CYAN}"
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║       OpenClaw VPS Installer              ║"
  echo "  ║       Ollama Local AI Edition              ║"
  echo "  ╚═══════════════════════════════════════════╝"
  echo -e "${NC}"
}

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
ask()   { echo -en "${BOLD}$1${NC} "; }

# ---------------------------------------------------------------------------
# 1. Check root
# ---------------------------------------------------------------------------
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root. Use: sudo bash <(curl -sSL ...)"
  fi
}

# ---------------------------------------------------------------------------
# 2. Check / install Node.js 22+
# ---------------------------------------------------------------------------
ensure_node() {
  if command -v node &>/dev/null; then
    local ver
    ver=$(node -v | sed 's/v//' | cut -d. -f1)
    if [[ "$ver" -ge "$NODE_MIN_VERSION" ]]; then
      log "Node.js $(node -v) detected (>= $NODE_MIN_VERSION)"
      return
    fi
    warn "Node.js $(node -v) found but < $NODE_MIN_VERSION. Installing newer version..."
  else
    warn "Node.js not found. Installing..."
  fi

  if command -v apt-get &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  elif command -v dnf &>/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
    dnf install -y nodejs
  elif command -v yum &>/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
    yum install -y nodejs
  else
    error "Unsupported package manager. Install Node.js 22+ manually and re-run."
  fi

  log "Node.js $(node -v) installed"
}

# ---------------------------------------------------------------------------
# 3. Install pnpm
# ---------------------------------------------------------------------------
ensure_pnpm() {
  if command -v pnpm &>/dev/null; then
    log "pnpm $(pnpm -v) detected"
    return
  fi
  warn "pnpm not found. Installing..."
  npm install -g pnpm
  log "pnpm $(pnpm -v) installed"
}

# ---------------------------------------------------------------------------
# 4. Install git
# ---------------------------------------------------------------------------
ensure_git() {
  if command -v git &>/dev/null; then
    log "git detected"
    return
  fi
  warn "git not found. Installing..."
  if command -v apt-get &>/dev/null; then
    apt-get install -y git
  elif command -v dnf &>/dev/null; then
    dnf install -y git
  elif command -v yum &>/dev/null; then
    yum install -y git
  fi
  log "git installed"
}

# ---------------------------------------------------------------------------
# 5. Clone and build OpenClaw
# ---------------------------------------------------------------------------
install_openclaw() {
  if [[ -d "$OPENCLAW_DIR" ]]; then
    warn "OpenClaw directory exists at $OPENCLAW_DIR"
    ask "Reinstall? (y/N):"
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      log "Skipping clone/build, using existing installation"
      return
    fi
    rm -rf "$OPENCLAW_DIR"
  fi

  log "Cloning OpenClaw..."
  git clone https://github.com/openclaw/openclaw.git "$OPENCLAW_DIR"

  cd "$OPENCLAW_DIR"
  log "Installing dependencies..."
  pnpm install --frozen-lockfile

  log "Building..."
  pnpm build

  log "OpenClaw built successfully at $OPENCLAW_DIR"
}

# ---------------------------------------------------------------------------
# 6. Interactive configuration
# ---------------------------------------------------------------------------
configure_openclaw() {
  echo ""
  echo -e "${BOLD}=== Configuration ===${NC}"
  echo ""

  # Ollama endpoint
  local default_ollama_url="http://127.0.0.1:11434/v1"
  ask "Ollama API URL [$default_ollama_url]:"
  read -r ollama_url
  ollama_url="${ollama_url:-$default_ollama_url}"

  # Model
  local default_model="llama3.2:3b"
  ask "Default model [$default_model]:"
  read -r model_name
  model_name="${model_name:-$default_model}"

  # Gateway token
  local default_token
  default_token=$(openssl rand -hex 16 2>/dev/null || echo "openclaw-$(date +%s)")
  ask "Gateway auth token [$default_token]:"
  read -r gateway_token
  gateway_token="${gateway_token:-$default_token}"

  # Gateway port
  local default_port="18789"
  ask "Gateway port [$default_port]:"
  read -r gateway_port
  gateway_port="${gateway_port:-$default_port}"

  # Create config directory
  mkdir -p "$OPENCLAW_STATE_DIR"
  chmod 700 "$OPENCLAW_STATE_DIR"

  # Write config
  cat > "$OPENCLAW_CONFIG" <<CONFIGEOF
{
  "gateway": {
    "bind": "lan",
    "port": ${gateway_port},
    "auth": {
      "mode": "token",
      "token": "${gateway_token}"
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/${model_name}"
      }
    }
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "${ollama_url}",
        "api": "openai-completions",
        "apiKey": "ollama",
        "models": [
          {
            "id": "${model_name}",
            "name": "${model_name}",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 128000,
            "maxTokens": 8192
          }
        ]
      }
    }
  }
}
CONFIGEOF

  chmod 600 "$OPENCLAW_CONFIG"
  log "Config written to $OPENCLAW_CONFIG"
  echo ""
  echo -e "${BOLD}Summary:${NC}"
  echo "  Provider:  ollama"
  echo "  Model:     ollama/${model_name}"
  echo "  Ollama:    ${ollama_url}"
  echo "  Gateway:   0.0.0.0:${gateway_port}"
  echo "  Token:     ${gateway_token}"
  echo ""
}

# ---------------------------------------------------------------------------
# 7. Create systemd service
# ---------------------------------------------------------------------------
create_systemd_service() {
  local service_file="/etc/systemd/system/${OPENCLAW_SERVICE}.service"

  cat > "$service_file" <<SERVICEEOF
[Unit]
Description=OpenClaw Gateway (Ollama)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${OPENCLAW_DIR}
ExecStart=$(command -v node) ${OPENCLAW_DIR}/dist/entry.js gateway run --bind lan --force
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
Environment=OLLAMA_API_KEY=ollama

[Install]
WantedBy=multi-user.target
SERVICEEOF

  systemctl daemon-reload
  systemctl enable "$OPENCLAW_SERVICE"
  log "Systemd service created: $OPENCLAW_SERVICE"
}

# ---------------------------------------------------------------------------
# 8. Start gateway
# ---------------------------------------------------------------------------
start_gateway() {
  ask "Start gateway now? (Y/n):"
  read -r answer
  if [[ "$answer" == "n" || "$answer" == "N" ]]; then
    log "Skipping start. Run manually: systemctl start $OPENCLAW_SERVICE"
    return
  fi

  systemctl restart "$OPENCLAW_SERVICE"
  sleep 2

  if systemctl is-active --quiet "$OPENCLAW_SERVICE"; then
    log "Gateway is running!"
    echo ""
    echo -e "${GREEN}${BOLD}=== OpenClaw is ready! ===${NC}"
    echo ""
    echo "  Gateway:   http://$(hostname -I | awk '{print $1}'):18789"
    echo "  Status:    systemctl status $OPENCLAW_SERVICE"
    echo "  Logs:      journalctl -u $OPENCLAW_SERVICE -f"
    echo "  Restart:   systemctl restart $OPENCLAW_SERVICE"
    echo "  Config:    $OPENCLAW_CONFIG"
    echo ""
  else
    warn "Gateway may not have started correctly."
    echo "  Check: journalctl -u $OPENCLAW_SERVICE -n 50"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  banner
  check_root
  ensure_node
  ensure_pnpm
  ensure_git
  install_openclaw
  configure_openclaw
  create_systemd_service
  start_gateway

  echo -e "${GREEN}${BOLD}Installation complete!${NC}"
}

main "$@"
