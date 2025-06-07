#!/bin/bash
set -e

log() {
  echo -e "[$(date +'%H:%M:%S')] $@"
}

log "🚀 Início da configuração Jenkins-lab..."

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_IP=$(hostname -I | awk '{print $1}')
WORKER_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')

# -------------------------------
# Preparar cache Docker (se necessário)
# -------------------------------
preparar_cache_docker_rpms() {
  log "📦 A preparar cache local dos pacotes Docker..."
  CACHE_DIR="$BASE_DIR/docker_rpm_cache"
  mkdir -p "$CACHE_DIR"
  dnf install -y dnf-plugins-core epel-release
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf download --resolve --alldeps --downloaddir="$CACHE_DIR" \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  log "✅ Cache local criada em $CACHE_DIR"
}

if [ ! -d "$BASE_DIR/docker_rpm_cache" ] || [ -z "$(ls -A "$BASE_DIR/docker_rpm_cache")" ]; then
  preparar_cache_docker_rpms
else
  log "✅ Cache de pacotes Docker já existente."
fi

# -------------------------------
# Geração da imagem Jenkins tar
# -------------------------------
if [ ! -f "$BASE_DIR/jenkins-autocontido.tar" ]; then
  log "📦 A guardar imagem Jenkins como tar..."
  docker save -o "$BASE_DIR/jenkins-autocontido.tar" jenkins-autocontido:latest
else
  log "✅ Imagem Jenkins já exportada localmente"
fi

if [ ! -f "$BASE_DIR/jenkins-autocontido.tar" ]; then
  log "❌ Erro: Falhou a criação de jenkins-autocontido.tar"
  exit 1
fi

# -------------------------------
# Função de configuração remota
# -------------------------------
configurar_worker() {
  local WORKER_IP="$1"
  local REGISTRY_IP="$2"

  log "🔧 A preparar configuração no worker $WORKER_IP..."

  ping -c 2 "$WORKER_IP" > /dev/null || {
    log "❌ ICMP falhou para $WORKER_IP"
    return 1
  }

  if ! ssh -o BatchMode=yes root@"$WORKER_IP" 'echo ok' &>/dev/null; then
    log "⚠️  SSH sem password falhou. A tentar ssh-copy-id..."
    ssh-copy-id -f root@"$WORKER_IP" || {
      log "❌ ssh-copy-id falhou para $WORKER_IP"
      return 1
    }
  fi

  RAM_MB=$(ssh root@"$WORKER_IP" "free -m | awk '/^Mem:/ { print \$2 }'")
  if [ "$RAM_MB" -lt 2000 ]; then
    log "➕ A criar swapfile no worker $WORKER_IP..."
    ssh root@"$WORKER_IP" "fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
    ssh root@"$WORKER_IP" "grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab"
  else
    log "✅ RAM suficiente no worker $WORKER_IP"
  fi

  log "📤 A copiar cache RPMs para $WORKER_IP..."
  scp -r "$BASE_DIR/docker_rpm_cache" root@"$WORKER_IP":/root/

  log "🐳 A configurar Docker no worker $WORKER_IP..."
  ssh root@"$WORKER_IP" bash -s <<EOF
if ! command -v docker &>/dev/null; then
  dnf install -y /root/docker_rpm_cache/*.rpm
fi
mkdir -p /etc/docker
echo '{ "insecure-registries": ["$REGISTRY_IP:5000"] }' > /etc/docker/daemon.json
systemctl restart docker
systemctl daemon-reexec
systemctl restart kubelet
EOF

  log "📤 A transferir imagem Jenkins para o worker..."
  scp "$BASE_DIR/jenkins-autocontido.tar" root@"$WORKER_IP":/root/
  ssh root@"$WORKER_IP" "docker load -i /root/jenkins-autocontido.tar && rm /root/jenkins-autocontido.tar"
}

# -------------------------------
# Loop de configuração dos workers
# -------------------------------
log "==================== FASE: CONFIGURAR WORKERS ===================="

for NODE in $WORKER_NODES; do
  IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  configurar_worker "$IP" "$REGISTRY_IP"
done

# -------------------------------
# Limpeza final (opcional)
# -------------------------------
rm -f "$BASE_DIR/jenkins-autocontido.tar"

log "🎉 Configuração dos workers concluída com sucesso."
