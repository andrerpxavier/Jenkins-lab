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

# ---------------------------
# Função para instalar Java 17
# ---------------------------


instalar_java() {
  echo "🔍 A instalar Java ..."
  dnf install -y java-17-openjdk
  if ! command -v java &> /dev/null; then
    echo "❌ Falha ao instalar Java."
    exit 1
  fi
  echo "✅ Java instalado com sucesso."
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
echo "✅ [1/8] Iniciando Docker Registry local..."
if docker ps -a --format '{{.Names}}' | grep -Eq '^registry$'; then
  docker rm -f registry
fi
docker run -d --name registry --restart=always -p 5000:5000 registry:2

echo "✅ [2/8] Construindo imagem Jenkins personalizada..."
docker build -t jenkins-autocontido -f Dockerfile.jenkins .

echo "✅ [3/8] A fazer push da imagem jenkins-autocontido para o registry local..."
docker tag jenkins-autocontido localhost:5000/jenkins-autocontido

echo "✅ A configurar Docker para aceitar o registry local (localhost:5000)..."

# Criar ou atualizar /etc/docker/daemon.json
cat <<EOF > /etc/docker/daemon.json
{
  "insecure-registries": ["localhost:5000"]
}
EOF

# Reiniciar o Docker
systemctl restart docker

# Aguardar que o Docker volte a responder
sleep 5

echo "✅ Docker configurado com suporte para registry local inseguro."


docker push localhost:5000/jenkins-autocontido


echo "🔍 Validar que a imagem está no registry local..."
curl -s http://localhost:5000/v2/_catalog | grep "jenkins-autocontido" || {
  echo "❌ A imagem não foi corretamente enviada para o registry local!"
  exit 1
}

# ---------------------------
# Jenkins container via Docker
# ---------------------------
#echo "✅ [3/8] A iniciar Jenkins standalone..."

# Remove o Jenkins anterior se existir
#if docker ps -a --format '{{.Names}}' | grep -Eq '^jenkins$'; then
#  echo "⚠️  Jenkins já existia. A remover..."
#  docker rm -f jenkins
#fi

#docker run -d \
#  --name jenkins \
#  -u 0 \
#  --restart=always \
#  -p 8080:8080 -p 50000:50000 \
#  -v jenkins_home:/var/jenkins_home \
#  -v /var/run/docker.sock:/var/run/docker.sock \
#  jenkins-autocontido || {
#    echo "❌ Falha ao iniciar o container do Jenkins."
#    exit 1
#}

# ---------------------------
# Jenkins via Kubernetes YAMLs
# ---------------------------
echo "✅ [4/8] Criar namespace Jenkins no cluster..."

if kubectl get namespace jenkins &> /dev/null; then
  echo "⚠️  Namespace 'jenkins' já existe. A eliminar..."
  kubectl delete namespace jenkins --wait=true
  echo "✅ Namespace antigo removido com sucesso."
fi

kubectl create namespace jenkins

echo "🔎 A verificar existência de todos os ficheiros YAML necessários..."
for file in k8s/*.yaml; do
  if [ ! -f "$file" ]; then
    echo "❌ Ficheiro não encontrado: $file"
    exit 1
  else
    echo "✅ Encontrado: $file"
  fi
done
kubectl apply -f k8s/rbac-jenkins-admin.yaml


echo "✅ [5/8] Aplicar permissões RBAC (ServiceAccount + ClusterRole)..."
kubectl apply -f k8s/sa-jenkins.yaml

echo "✅ [6/8] Criar volume persistente Jenkins..."
mkdir -p /mnt/jenkins && chmod 755 /mnt/jenkins
kubectl apply -f k8s/volume-jenkins.yaml

echo "✅ [7/8] Aplicar deployment e service Kubernetes..."
kubectl apply -f k8s/deploy-jenkins.yaml
kubectl apply -f k8s/service-jenkins.yaml

sleep 40  # Dá tempo ao Jenkins para gerar o ficheiro

instalar_java



IP=$(hostname -I | awk '{print $1}')
#echo -e "\n✅ Jenkins a correr em: http://localhost:8080 ou http://$IP:8080"
#echo -e "📦 Jenkins Kubernetes exposto via NodePort em: http://$IP:32000 (caso ativado)\n"
JENKINS_URL="http://$IP:32000"

#ADMIN_PWD_FILE="/var/lib/docker/volumes/jenkins_home/_data/secrets/initialAdminPassword"
#echo "⏳ A aguardar password inicial do Jenkins..."

#until [ -f "$ADMIN_PWD_FILE" ]; do
#  sleep 2
#done

#ADMIN_PWD=$(cat "$ADMIN_PWD_FILE")
echo "⏳ A aguardar que o Jenkins esteja em estado Running..."

until kubectl get pod -n jenkins -l app=jenkins -o jsonpath="{.items[0].status.phase}" 2>/dev/null | grep -q "Running"; do
  sleep 2
done

ADMIN_POD=$(kubectl get pods -n jenkins -l app=jenkins -o jsonpath="{.items[0].metadata.name}")
ADMIN_PWD=$(kubectl -n jenkins exec -it "$ADMIN_POD" -- cat /var/jenkins_home/secrets/initialAdminPassword | tr -d '\r')


echo -e "✅ Password inicial do Jenkins: \\e[1;32m$ADMIN_PWD\\e[0m"

# ---------------------------
# Jenkins CLI: criar job + build
# ---------------------------
echo "✅ [8/8] Criar job hello-nginx-pipeline..."

echo "⏳ A aguardar que o Jenkins aceite conexões HTTP..."

#until curl -s http://localhost:8080/login > /dev/null; do
#  sleep 2
#done

#wget -q http://localhost:8080/jnlpJars/jenkins-cli.jar -O jenkins-cli.jar

until curl -s "$JENKINS_URL/login" > /dev/null; do
  sleep 2
done

wget -q "$JENKINS_URL/jnlpJars/jenkins-cli.jar" -O jenkins-cli.jar

#java -jar jenkins-cli.jar -s http://localhost:8080/ -auth admin:$ADMIN_PWD install-plugin git docker-workflow kubernetes-cli workflow-aggregator ws-cleanup -restart
java -jar jenkins-cli.jar -s $JENKINS_URL -auth admin:$ADMIN_PWD install-plugin git docker-workflow kubernetes-cli workflow-aggregator ws-cleanup -restart

echo "⏳ A aguardar que o Jenkins esteja pronto a aceitar ligações..."

until curl -s "$JENKINS_URL/login" | grep -q "<title>Sign in"; do
  sleep 3
done

echo "⏳ A aguardar reinício do Jenkins após plugins..."
sleep 40

cat <<EOF > hello-nginx.xml
<flow-definition plugin="workflow-job">
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>https://github.com/andrerpxavier/Jenkins-lab.git</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
  </definition>
  <triggers/>
</flow-definition>
EOF

#java -jar jenkins-cli.jar -s http://localhost:8080/ -auth admin:$ADMIN_PWD create-job hello-nginx-pipeline < hello-nginx.xml
#java -jar jenkins-cli.jar -s http://localhost:8080/ -auth admin:$ADMIN_PWD build hello-nginx-pipeline
java -jar jenkins-cli.jar -s $JENKINS_URL -auth admin:$ADMIN_PWD create-job hello-nginx-pipeline < hello-nginx.xml
java -jar jenkins-cli.jar -s $JENKINS_URL -auth admin:$ADMIN_PWD build hello-nginx-pipeline


echo "🎉 Jenkins configurado com sucesso e pipeline executado!"

