#!/bin/bash
set -e

# ---------------------------
# Função para instalar Docker
# ---------------------------
instalar_docker() {
  echo "🔍 Docker não encontrado. A iniciar instalação..."
  dnf install -y dnf-plugins-core epel-release
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker

  if ! command -v docker &> /dev/null; then
    echo "❌ Docker não foi instalado corretamente."
    exit 1
  fi

  echo "✅ Docker instalado com sucesso!"
}

# ------------------------------
# Verificação e instalação base
# ------------------------------
if ! command -v docker &> /dev/null; then
  instalar_docker
else
  echo "✅ Docker já está instalado."
fi

# ---------------------------
# Jenkins Registry + Imagem
# ---------------------------
echo "✅ [1/7] Iniciando Docker Registry local..."
if docker ps -a --format '{{.Names}}' | grep -Eq '^registry$'; then
  docker rm -f registry
fi
docker run -d --name registry --restart=always -p 5000:5000 registry:2

echo "✅ [2/7] Construindo imagem Jenkins personalizada..."
docker build -t jenkins-autocontido -f Dockerfile.jenkins .

# ---------------------------
# Jenkins container via Docker
# ---------------------------
echo "✅ [3/7] A iniciar Jenkins standalone..."

# Remove o Jenkins anterior se existir
if docker ps -a --format '{{.Names}}' | grep -Eq '^jenkins$'; then
  echo "⚠️  Jenkins já existia. A remover..."
  docker rm -f jenkins
fi

docker run -d \
  --name jenkins \
  -u 0 \
  --restart=always \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins-autocontido || {
    echo "❌ Falha ao iniciar o container do Jenkins."
    exit 1
}

# ---------------------------
# Jenkins via Kubernetes YAMLs
# ---------------------------
echo "✅ [4/7] Criar namespace Jenkins no cluster..."

if kubectl get namespace jenkins &> /dev/null; then
  echo "⚠️  Namespace 'jenkins' já existe. A eliminar..."
  kubectl delete namespace jenkins --wait=true
  echo "✅ Namespace antigo removido com sucesso."
fi

kubectl create namespace jenkins


echo "✅ [5/7] Aplicar permissões RBAC (ServiceAccount + ClusterRole)..."
kubectl apply -f k8s/sa-jenkins.yaml

echo "✅ [6/7] Criar volume persistente Jenkins..."
mkdir -p /mnt/jenkins && chmod 755 /mnt/jenkins
kubectl apply -f k8s/volume-jenkins.yaml

echo "✅ [7/7] Aplicar deployment e service Kubernetes..."
kubectl apply -f k8s/deploy-jenkins.yaml
kubectl apply -f k8s/service-jenkins.yaml

IP=$(hostname -I | awk '{print $1}')
echo -e "\n✅ Jenkins a correr em: http://localhost:8080 ou http://$IP:8080"
echo -e "📦 Jenkins Kubernetes exposto via NodePort em: http://$IP:32000 (caso ativado)\n"
