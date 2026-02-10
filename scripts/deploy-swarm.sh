#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# OpenClaw Docker Swarm Deploy Script (Ollama Edition)
#
# Usage (no servidor):
#   curl -sSL https://raw.githubusercontent.com/carloedvandro/openclawd/main/scripts/deploy-swarm.sh | bash
#
# Ou manualmente:
#   bash deploy-swarm.sh
# ============================================================================

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

DEPLOY_DIR="/opt/openclaw"
STACK_NAME="openclaw"
REPO_URL="https://github.com/carloedvandro/openclawd.git"
BRANCH="main"

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
ask()   { echo -en "${BOLD}$1${NC} "; }

banner() {
  echo -e "${CYAN}"
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║    OpenClaw - Docker Swarm Deploy          ║"
  echo "  ║    Ollama Local AI Edition                 ║"
  echo "  ╚═══════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ---------------------------------------------------------------------------
# 1. Verificações
# ---------------------------------------------------------------------------
check_prerequisites() {
  if ! command -v docker &>/dev/null; then
    error "Docker não encontrado. Instale o Docker primeiro."
  fi

  if ! docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
    warn "Docker Swarm não está ativo. Inicializando..."
    docker swarm init 2>/dev/null || true
  fi

  log "Docker Swarm ativo"
}

# ---------------------------------------------------------------------------
# 2. Clonar/atualizar repositório
# ---------------------------------------------------------------------------
setup_repo() {
  if [[ -d "$DEPLOY_DIR/.git" ]]; then
    log "Repositório existente em $DEPLOY_DIR. Atualizando..."
    cd "$DEPLOY_DIR"
    git fetch origin
    git reset --hard "origin/$BRANCH"
  else
    log "Clonando repositório..."
    rm -rf "$DEPLOY_DIR"
    git clone --branch "$BRANCH" "$REPO_URL" "$DEPLOY_DIR"
    cd "$DEPLOY_DIR"
  fi
  log "Código fonte pronto em $DEPLOY_DIR"
}

# ---------------------------------------------------------------------------
# 3. Configuração interativa
# ---------------------------------------------------------------------------
configure() {
  echo ""
  echo -e "${BOLD}=== Configuração ===${NC}"
  echo ""

  # Ollama endpoint
  local default_ollama_url="https://apiollama.ychat-ia.com.br/v1"
  ask "URL do Ollama API [$default_ollama_url]:"
  read -r OLLAMA_URL
  OLLAMA_URL="${OLLAMA_URL:-$default_ollama_url}"

  # Modelo
  local default_model="llama3.2:3b"
  ask "Modelo padrão [$default_model]:"
  read -r MODEL_NAME
  MODEL_NAME="${MODEL_NAME:-$default_model}"

  # Token do gateway
  local default_token
  default_token=$(openssl rand -hex 16 2>/dev/null || echo "openclaw-$(date +%s)")
  ask "Token de autenticação do gateway [$default_token]:"
  read -r GW_TOKEN
  GW_TOKEN="${GW_TOKEN:-$default_token}"

  # Porta
  local default_port="18789"
  ask "Porta do gateway [$default_port]:"
  read -r GW_PORT
  GW_PORT="${GW_PORT:-$default_port}"

  # Gerar openclaw-config.json
  cat > "$DEPLOY_DIR/openclaw-config.json" <<EOF
{
  "gateway": {
    "bind": "lan",
    "port": ${GW_PORT},
    "auth": {
      "mode": "token",
      "token": "${GW_TOKEN}"
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/${MODEL_NAME}"
      }
    }
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "${OLLAMA_URL}",
        "api": "openai-completions",
        "apiKey": "ollama",
        "models": [
          {
            "id": "${MODEL_NAME}",
            "name": "${MODEL_NAME}",
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
EOF

  log "Configuração salva"
  echo ""
  echo -e "${BOLD}Resumo:${NC}"
  echo "  Provider:  ollama"
  echo "  Modelo:    ollama/${MODEL_NAME}"
  echo "  Ollama:    ${OLLAMA_URL}"
  echo "  Gateway:   0.0.0.0:${GW_PORT}"
  echo "  Token:     ${GW_TOKEN}"
  echo ""
}

# ---------------------------------------------------------------------------
# 4. Build da imagem Docker
# ---------------------------------------------------------------------------
build_image() {
  log "Construindo imagem Docker (pode levar alguns minutos)..."
  cd "$DEPLOY_DIR"
  docker build -f Dockerfile.ollama -t openclaw-ollama:latest . 2>&1 | tail -5
  log "Imagem openclaw-ollama:latest construída"
}

# ---------------------------------------------------------------------------
# 5. Remover stack anterior (se existir)
# ---------------------------------------------------------------------------
remove_old_stack() {
  if docker stack ls 2>/dev/null | grep -q "$STACK_NAME"; then
    warn "Stack '$STACK_NAME' já existe. Removendo..."
    docker stack rm "$STACK_NAME"
    # Aguardar remoção completa
    local retries=0
    while docker stack ps "$STACK_NAME" &>/dev/null && [[ $retries -lt 30 ]]; do
      sleep 2
      retries=$((retries + 1))
    done
    sleep 3
    log "Stack anterior removida"
  fi
}

# ---------------------------------------------------------------------------
# 6. Deploy no Swarm
# ---------------------------------------------------------------------------
deploy_stack() {
  log "Fazendo deploy no Docker Swarm..."
  cd "$DEPLOY_DIR"
  docker stack deploy -c docker-stack.yml "$STACK_NAME"
  log "Stack '$STACK_NAME' deployed"

  # Aguardar container iniciar
  echo -n "  Aguardando inicialização"
  local retries=0
  while [[ $retries -lt 30 ]]; do
    sleep 2
    echo -n "."
    local state
    state=$(docker stack ps "$STACK_NAME" --format '{{.CurrentState}}' 2>/dev/null | head -1)
    if echo "$state" | grep -qi "running"; then
      echo ""
      log "Container rodando!"
      break
    fi
    retries=$((retries + 1))
  done

  if [[ $retries -ge 30 ]]; then
    echo ""
    warn "Timeout aguardando container. Verifique com: docker stack ps $STACK_NAME"
  fi
}

# ---------------------------------------------------------------------------
# 7. Verificar deploy
# ---------------------------------------------------------------------------
verify_deploy() {
  sleep 5
  echo ""
  echo -e "${BOLD}=== Status do Deploy ===${NC}"
  echo ""
  docker stack ps "$STACK_NAME" --format "table {{.Name}}\t{{.CurrentState}}\t{{.Error}}" 2>/dev/null || true
  echo ""

  # Testar endpoint
  local server_ip
  server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "167.86.84.197")

  if curl -sf -o /dev/null "http://127.0.0.1:${GW_PORT:-18789}" 2>/dev/null; then
    log "Gateway respondendo na porta ${GW_PORT:-18789}"
  else
    warn "Gateway ainda não respondeu (pode levar mais alguns segundos)"
  fi

  echo ""
  echo -e "${GREEN}${BOLD}=== OpenClaw Instalado! ===${NC}"
  echo ""
  echo "  Gateway:     http://${server_ip}:${GW_PORT:-18789}"
  echo "  Status:      docker stack ps $STACK_NAME"
  echo "  Logs:        docker service logs ${STACK_NAME}_openclaw -f"
  echo "  Remover:     docker stack rm $STACK_NAME"
  echo "  Config:      $DEPLOY_DIR/openclaw-config.json"
  echo ""
  echo -e "  ${YELLOW}Importante: guarde seu token de acesso!${NC}"
  echo "  Token:       ${GW_TOKEN:-localtoken}"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  banner
  check_prerequisites
  setup_repo
  configure
  build_image
  remove_old_stack
  deploy_stack
  verify_deploy

  echo -e "${GREEN}${BOLD}Deploy concluído!${NC}"
}

main "$@"
