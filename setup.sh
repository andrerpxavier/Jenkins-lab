#!/bin/bash

set -e

# 1. Subir o registry local (se não existir)
echo ✅ "[1/5] Iniciando Docker Registry local..."
docker inspect registry >/dev/null 2>&1 || \
  docker run -d -p 5000:5000 --name registry registry:2

# 2. Construir imagem Jenkins personalizada
echo ✅ "[2/5] Construindo imagem Jenkins personalizada..."
docker build -t jenkins-autocontido -f Dockerfile.jenkins .

# 3. Apagar Jenkins antigo (se existir)
echo ✅ "[3/5] Removendo Jenkins anterior (se existir)..."
docker rm -f jenkins >/dev/null 2>&1 || true

# 4. Correr Jenkins com Docker e kubectl incluído
echo ✅ "[4/5] Iniciando Jenkins com Docker e kubectl..."
docker run -d \
  --name jenkins \
  -u 0 \
  --restart=always \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins-autocontido

# 5. Mostrar a password inicial do Jenkins
echo "\n⚠️ Jenkins inicializado. Password de acesso:"
docker exec -it jenkins cat /var/jenkins_home/secrets/initialAdminPassword
IP=$(hostname -I | awk '{print $1}')
echo -e "\n✅ Jenkins a correr em http://localhost:8080 e acessível através de http://$IP:8080"
