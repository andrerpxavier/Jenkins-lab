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

configurar_docker_worker() {
  WORKER_IP=$1
  REGISTRY_IP=$2
  echo "🔧 A preparar configuração no worker $WORKER_IP..."

  echo "🔍 A verificar acesso SSH root@$WORKER_IP..."
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 root@$WORKER_IP 'echo SSH OK' 2>/dev/null | grep -q 'SSH OK'; then
    echo "⚠️  Acesso SSH sem password falhou. Vamos tentar configurar com ssh-copy-id..."
    if [ -f ~/.ssh/id_rsa.pub ]; then
      ssh-copy-id root@$WORKER_IP || {
        echo "❌ Não foi possível configurar acesso SSH ao worker $WORKER_IP."
        return 1
      }
    else
      echo "❌ Chave SSH não encontrada (~/.ssh/id_rsa.pub). Aborta configuração para $WORKER_IP."
      return 1
    fi
  else
    echo "✅ Acesso SSH sem password já está funcional."
  fi

  echo "🔧 A configurar Docker em $WORKER_IP..."

  ssh root@$WORKER_IP bash -s <<EOF
if ! command -v docker &> /dev/null; then
  echo "🧱 Docker não encontrado. A instalar via dnf..."
  dnf install -y docker
  systemctl enable docker --now
else
  echo "✅ Docker já está instalado."
fi

echo "⚙️  A configurar /etc/docker/daemon.json com registry inseguro..."
mkdir -p /etc/docker
cat <<JSON > /etc/docker/daemon.json
{
  "insecure-registries": ["$REGISTRY_IP:5000"]
}
JSON

echo "🔄 A reiniciar Docker..."
systemctl daemon-reexec
systemctl restart docker

sleep 2
echo "🔍 A testar ligação ao registry: http://$REGISTRY_IP:5000..."
curl --max-time 5 http://$REGISTRY_IP:5000/v2/_catalog || echo '❌ Erro ao contactar o registry'
EOF
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

echo "🔐 A verificar se existe chave SSH..."

if [ ! -f ~/.ssh/id_rsa.pub ]; then
  echo "🔧 Nenhuma chave encontrada. A gerar uma nova chave SSH RSA sem passphrase..."
  ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa || {
    echo "❌ Erro ao gerar a chave SSH. Abortar."
    exit 1
  }
  echo "✅ Chave SSH criada em ~/.ssh/id_rsa.pub"
else
  echo "✅ Chave SSH já existe."
fi

echo "🔎 A detetar workers no cluster Kubernetes..."

REGISTRY_IP=$(hostname -I | awk '{print $1}')
WORKER_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')

for NODE in $WORKER_NODES; do
  IP=$(kubectl get node $NODE -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  configurar_docker_worker "$IP" "$REGISTRY_IP"
done

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

echo "✅ Docker configurado com suporte para registry local."


docker push localhost:5000/jenkins-autocontido || {
  echo "❌ Falha ao fazer push da imagem Jenkins para o registry local."
  exit 1
}


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

echo "🔎 A validar todos os ficheiros YAML (syntaxe e recursos)..."
for file in k8s/*.yaml; do
  if [ ! -f "$file" ]; then
    echo "❌ Ficheiro não encontrado: $file"
    exit 1
  fi
  echo "🧪 Validar $file..."
  kubectl apply --dry-run=client -f "$file" > /dev/null || {
    echo "❌ Erro de validação: $file"
    exit 1
  }
done

kubectl apply -f k8s/rbac-jenkins-admin.yaml


echo "✅ [5/8] Aplicar permissões RBAC (ServiceAccount + ClusterRole)..."
kubectl apply -f k8s/sa-jenkins.yaml

echo "✅ [6/8] Criar volume persistente Jenkins..."

# Apagar PVC antigo se existir
if kubectl get pvc -n jenkins jenkins-pvc &>/dev/null; then
  echo "⚠️  PVC jenkins-pvc já existe. A eliminar..."
  kubectl delete pvc jenkins-pvc -n jenkins --wait=true
fi

# Apagar PV antigo se existir
if kubectl get pv jenkins-pv &>/dev/null; then
  echo "⚠️  PV jenkins-pv já existe. A eliminar..."
  kubectl delete pv jenkins-pv --wait=true
fi

mkdir -p /mnt/jenkins && chmod 755 /mnt/jenkins && chown -R 1000:1000 /mnt/jenkins
kubectl apply -f k8s/volume-jenkins.yaml

echo "⏳ A Aguardar que o PVC fique ligado ao PV..."
until kubectl get pvc -n jenkins jenkins-pvc -o jsonpath='{.status.phase}' | grep -q "Bound"; do
  sleep 2
done
echo "✅ PVC ligado ao PV com sucesso."


echo "✅ [7/8] Aplicar deployment e service Kubernetes..."

REGISTRY_IP=$(hostname -I | awk '{print $1}')
sed -i "s|image: .*:5000/jenkins-autocontido|image: ${REGISTRY_IP}:5000/jenkins-autocontido|" k8s/deploy-jenkins.yaml

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

echo "⏳ A aguardar que o pod do Jenkins fique em estado Running ..."
TIMEOUT=180
SECONDS_WAITED=0

while true; do
  STATUS=$(kubectl get pod -n jenkins -l app=jenkins -o jsonpath="{.items[0].status.phase}" 2>/dev/null || echo "Erro")
  if [[ "$STATUS" == "Running" ]]; then
    echo "✅ Jenkins está em execução."
    break
  fi
  if (( SECONDS_WAITED >= TIMEOUT )); then
    echo "❌ Timeout: Jenkins não ficou pronto em $TIMEOUT segundos."
    exit 1
  fi
  sleep 3
  ((SECONDS_WAITED+=3))
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

