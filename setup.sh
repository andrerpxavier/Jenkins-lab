#!/bin/bash
set -e

# Função para instalar o Docker se não estiver presente
instalar_docker() {
  echo "🔍 Docker não encontrado. A iniciar instalação..."

  dnf install -y dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  echo "✅ Docker instalado com sucesso!"
}

# Verifica se o Docker está instalado
if ! command -v docker &> /dev/null; then
  instalar_docker
else
  echo "✅ Docker já está instalado."
fi

echo "✅ [1/5] Iniciando Docker Registry local..."
docker run -d --name registry --restart=always -p 5000:5000 registry:2

echo "✅ [2/5] Construindo imagem Jenkins personalizada..."
docker build -t jenkins-autocontido -f Dockerfile.jenkins .

echo "✅ [3/5] A iniciar Jenkins com Docker, Git e kubectl..."
docker run -d \
  --name jenkins \
  -u 0 \
  --restart=always \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.kube:/root/.kube \
  -v /usr/bin/kubectl:/usr/bin/kubectl \
  jenkins-autocontido

IP=$(hostname -I | awk '{print $1}')
echo -e "\n✅ Jenkins a correr em http://localhost:8080 ou http://$IP:8080"
