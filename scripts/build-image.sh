#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# OpenClaw - Build Docker Image (Ollama Edition)
#
# Este script APENAS constrói a imagem Docker. Não cria serviços.
# Depois de construir, crie a stack no Portainer usando docker-stack.yml.
#
# Uso:
#   bash <(curl -sSL https://raw.githubusercontent.com/carloedvandro/openclawd/main/scripts/build-image.sh)
# ============================================================================

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

DEPLOY_DIR="/opt/openclaw"
REPO_URL="https://github.com/carloedvandro/openclawd.git"
BRANCH="main"
IMAGE_NAME="openclaw-ollama:latest"

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║    OpenClaw - Build Image                  ║"
echo "  ║    Ollama Local AI Edition                 ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

# Verificar Docker
if ! command -v docker &>/dev/null; then
  error "Docker não encontrado."
fi
log "Docker disponível"

# Clonar ou atualizar repositório
if [[ -d "$DEPLOY_DIR/.git" ]]; then
  log "Atualizando repositório em $DEPLOY_DIR..."
  cd "$DEPLOY_DIR"
  git fetch origin
  git reset --hard "origin/$BRANCH"
else
  log "Clonando repositório..."
  rm -rf "$DEPLOY_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$DEPLOY_DIR"
  cd "$DEPLOY_DIR"
fi
log "Código fonte pronto"

# Criar openclaw-config.json com valores padrão
CONFIG_FILE="$DEPLOY_DIR/openclaw-config.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "Criando configuração padrão..."
  cat > "$CONFIG_FILE" <<'EOF'
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "localtoken"
    },
    "controlUi": {
      "allowInsecureAuth": true
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/llama3.2:3b"
      }
    }
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://ollama_ollama:11434/v1",
        "api": "openai-completions",
        "apiKey": "ollama",
        "models": [
          {
            "id": "llama3.2:3b",
            "name": "Llama 3.2 3B",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 128000,
            "maxTokens": 8192
          },
          {
            "id": "llama3.1:8b",
            "name": "Llama 3.1 8B",
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
  log "Configuração salva em $CONFIG_FILE"
else
  log "Configuração existente mantida: $CONFIG_FILE"
fi

# Build da imagem
log "Construindo imagem Docker '$IMAGE_NAME'..."
echo "  (isso pode levar 5-10 minutos na primeira vez)"
echo ""
docker build -f Dockerfile.ollama -t "$IMAGE_NAME" .

echo ""
log "Imagem '$IMAGE_NAME' construída com sucesso!"
echo ""
echo -e "${GREEN}${BOLD}=== Próximo Passo ===${NC}"
echo ""
echo "  Agora crie uma nova Stack no Portainer:"
echo ""
echo "  1. Abra o Portainer"
echo "  2. Vá em Stacks → Add Stack"
echo "  3. Nome: openclaw"
echo "  4. Cole o conteúdo abaixo no Web Editor:"
echo ""
echo -e "${CYAN}--- Copie daqui ---${NC}"
cat <<'STACKEOF'
version: "3.8"

services:
  gateway:
    image: openclaw-ollama:latest
    ports:
      - "18789:18789"
    environment:
      - NODE_ENV=production
      - NODE_OPTIONS=--max-old-space-size=1024
      - OLLAMA_API_KEY=ollama
      - OLLAMA_BASE_URL=http://ollama_ollama:11434/v1
    volumes:
      - openclaw-data:/home/node/.openclaw
      - /opt/openclaw/openclaw-config.json:/home/node/.openclaw/openclaw.json:ro
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 5
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 512M
    networks:
      - NET
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:18789').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

volumes:
  openclaw-data:

networks:
  NET:
    external: true
STACKEOF
echo -e "${CYAN}--- Até aqui ---${NC}"
echo ""
echo "  5. Clique em 'Deploy the stack'"
echo ""
echo -e "  Após deploy, acesse: ${BOLD}http://$(hostname -I 2>/dev/null | awk '{print $1}'):18789${NC}"
echo ""
