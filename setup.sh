#!/bin/bash
set -e

# Função para instalar o Docker se não estiver presente
instalar_docker() {
  echo "🔍 Docker não encontrado. A iniciar instalação..."

  dnf install -y dnf-plugins-core epel-release
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || {
    echo "❌ Falha ao adicionar o repositório da Docker."
    exit 1
  }

  dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
    echo "❌ Falha na instalação dos pacotes Docker."
    exit 1
  }

  systemctl enable docker
  systemctl start docker

  if ! command -v docker &> /dev/null; then
    echo "❌ Docker não foi instalado corretamente. Verifica os logs acima."
    exit 1
  fi

  echo "✅ Docker instalado com sucesso!"
}

# Verifica se o Docker está instalado
if ! command -v docker &> /dev/null; then
  instalar_docker
else
  echo "✅ Docker já está instalado."
fi

echo "✅ [1/5] Iniciando Docker Registry local..."
if docker ps -a --format '{{.Names}}' | grep -Eq '^registry$'; then
  echo "⚠️  Registry existente encontrado. A remover..."
  docker rm -f registry
fi

docker run -d --name registry --restart=always -p 5000:5000 registry:2 || {
  echo "⚠️ O registry pode já estar a correr ou ocorreu um erro. Verifica com 'docker ps -a'."
}

echo "✅ [2/5] Construindo imagem Jenkins personalizada..."
docker build -t jenkins-autocontido -f Dockerfile.jenkins . || {
  echo "❌ Falha ao construir a imagem personalizada do Jenkins."
  exit 1
}

echo "✅ [3/5] A iniciar Jenkins com Docker, Git e kubectl..."
if docker ps -a --format '{{.Names}}' | grep -Eq '^jenkins$'; then
  echo "⚠️  Jenkins existente encontrado. A remover..."
  docker rm -f jenkins
fi

docker run -d \
  --name jenkins \
  -u 0 \
  --restart=always \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.kube:/root/.kube \
  -v /usr/bin/kubectl:/usr/bin/kubectl \
  jenkins-autocontido || {
    echo "❌ Falha ao iniciar o container do Jenkins."
    exit 1
}

# Aguarda brevemente para garantir que o Jenkins escreve a password
echo "⏳ A aguardar inicialização do Jenkins..."
sleep 10

echo "🔐 Password inicial do Jenkins:"
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword || {
  echo "❌ Não foi possível obter a password inicial. Verifica se o Jenkins está a correr corretamente."
}

IP=$(hostname -I | awk '{print $1}')
echo -e "\n✅ Jenkins a correr em: http://localhost:8080 ou http://$IP:8080"
