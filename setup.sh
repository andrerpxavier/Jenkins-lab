
#!/bin/bash
set -e
# ---------------------------
# Função para instalar Docker
# ---------------------------
instalar_docker() {
  echo "🔍 Docker não encontrado. A iniciar instalação..."

  # Corrigir possíveis repos quebrados do CentOS
  BASEOS_REPO="/etc/yum.repos.d/CentOS-Stream-BaseOS.repo"
  APPSTREAM_REPO="/etc/yum.repos.d/CentOS-Stream-AppStream.repo"

  if [ -f "$BASEOS_REPO" ]; then
    sed -i '/^baseurl=/d' "$BASEOS_REPO"
    sed -i 's|^mirrorlist=.*|mirrorlist=https://mirrors.centos.org/mirrorlist?arch=$basearch&repo=centos-stream-baseos&infra=$infra|' "$BASEOS_REPO"
  fi

  if [ -f "$APPSTREAM_REPO" ]; then
    sed -i '/^baseurl=/d' "$APPSTREAM_REPO"
    sed -i 's|^mirrorlist=.*|mirrorlist=https://mirrors.centos.org/mirrorlist?arch=$basearch&repo=centos-stream-appstream&infra=$infra|' "$APPSTREAM_REPO"
  fi

  dnf clean all
  dnf makecache -y

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

preparar_cache_docker_rpms() {
  echo "📦 A preparar cache local dos pacotes Docker..."

  CACHE_DIR="./docker_rpm_cache"
  mkdir -p "$CACHE_DIR"

  # Instalar repositórios e preparar cache
  dnf install -y dnf-plugins-core epel-release
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

  # Download dos pacotes necessários e dependências
  dnf download --resolve --alldeps --downloaddir="$CACHE_DIR" \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  echo "✅ Cache local criada em $CACHE_DIR"
}

configurar_worker() {
  local WORKER_IP="$1"
  local REGISTRY_IP="$2"

  echo "🔧 A preparar configuração no worker $WORKER_IP..."

  echo "🌐 A testar conectividade com $WORKER_IP..."
  ping -c 2 "$WORKER_IP" > /dev/null || {
    echo "❌ ICMP falhou."
    return 1
  }

  echo "🔍 A verificar acesso SSH root@$WORKER_IP..."
  if ! ssh -o BatchMode=yes root@"$WORKER_IP" 'echo ok' &>/dev/null; then
    echo "⚠️  SSH sem password falhou. A tentar ssh-copy-id..."
    ssh-copy-id -f root@"$WORKER_IP" || {
      echo "❌ ssh-copy-id falhou."
      return 1
    }
  fi

  echo "🧠 A verificar se o worker tem menos de 4GB de RAM..."
  RAM_MB=$(ssh root@"$WORKER_IP" "free -m | awk '/^Mem:/ { print \$2 }'")
  if [ "$RAM_MB" -lt 4096 ]; then
    echo "➕ A criar swapfile de 4GB no worker $WORKER_IP..."
    ssh root@"$WORKER_IP" bash -s <<'EOF'
  if ! grep -q '/swapfile' /proc/swaps; then
    fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  EOF
  else
    echo "✅ O worker tem RAM suficiente. Swap não necessária."
  fi

  echo "📤 A copiar cache de RPMs para o worker..."
  scp -r ./docker_rpm_cache root@"$WORKER_IP":/root/ || {
    echo "❌ Falha ao copiar pacotes RPM para $WORKER_IP"
    return 1
  }

echo "🐳 A configurar Docker remotamente..."
ssh root@"$WORKER_IP" bash -s <<EOF
if ! command -v docker &>/dev/null; then
  echo "🧱 Docker não encontrado. A instalar via cache local..."
  dnf install -y /root/docker_rpm_cache/*.rpm
else
  echo "✅ Docker já está instalado."
fi

echo "⚙️  A configurar /etc/docker/daemon.json com registry inseguro..."
mkdir -p /etc/docker
cat <<EOC > /etc/docker/daemon.json
{
  "insecure-registries": ["${REGISTRY_IP}:5000"]
}
EOC

echo "🔄 A reiniciar Docker..."
systemctl restart docker || echo "⚠️  Falha ao reiniciar Docker."

echo "♻️  A reiniciar kubelet..."
systemctl daemon-reexec
systemctl restart kubelet
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

preparar_cache_docker_rpms

REGISTRY_IP=$(hostname -I | awk '{print $1}')
WORKER_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')

# Construir a imagem e exportar tarball ANTES de configurar os workers
echo "📥 A garantir que a imagem registry:2 está disponível localmente..."
docker pull registry:2

echo "✅ [1/8] Iniciando Docker Registry local..."
if docker ps -a --format '{{.Names}}' | grep -Eq '^registry$'; then
  docker rm -f registry
fi
docker run -d --name registry --restart=always -p 5000:5000 registry:2

echo "✅ [2/8] Construindo imagem Jenkins personalizada..."
REGISTRY_IP=$(hostname -I | awk '{print $1}')
REGISTRY="${REGISTRY_IP}:5000"
docker build -t jenkins-autocontido -f Dockerfile.jenkins .
docker tag jenkins-autocontido:latest ${REGISTRY}/jenkins-autocontido:latest

echo "📦 A exportar imagem Jenkins como tarball..."
docker save -o jenkins-autocontido.tar ${REGISTRY}/jenkins-autocontido:latest

#verificação de sucesso
if [ ! -f jenkins-autocontido.tar ]; then
  echo "❌ Erro: A exportação da imagem falhou!"
  exit 1
fi

# Agora sim, configurar os workers com tudo já pronto
for NODE in $WORKER_NODES; do
  IP=$(kubectl get node $NODE -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  configurar_worker  "$IP" "$REGISTRY_IP"
done

echo "✅ A configurar Docker para aceitar o registry local e remoto (localhost e IP)..."

cat <<EOF > /etc/docker/daemon.json
{
  "insecure-registries": ["localhost:5000", "${REGISTRY_IP}:5000"]
}
EOF

systemctl daemon-reexec
systemctl restart docker
sleep 5

echo "✅ Docker configurado com suporte para registry local."

echo "✅ [3/8] A fazer push da imagem jenkins-autocontido para o registry local..."
docker push ${REGISTRY}/jenkins-autocontido:latest || {
  echo "❌ Falha ao fazer push da imagem Jenkins para o registry local."
  exit 1
}

echo "🔍 Validar que a imagem está no registry local..."
if ! curl -s http://${REGISTRY_IP}:5000/v2/_catalog | grep -q "jenkins-autocontido"; then
  echo "❌ A imagem não foi corretamente enviada para o registry local!"
  exit 1
fi

# Enviar imagem para os workers e carregá-la com o runtime correto
for NODE in $WORKER_NODES; do
  IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  echo "📤 A enviar imagem Jenkins para o worker $NODE ($IP)..."
  scp -o StrictHostKeyChecking=no jenkins-autocontido.tar root@"$IP":/tmp/

  echo "🔍 A detetar o runtime do worker $NODE..."
  CONTAINERD_ATIVO=$(ssh -o StrictHostKeyChecking=no root@"$IP" "ps aux | grep kubelet | grep -q containerd && echo sim || echo nao")

  if [ "$CONTAINERD_ATIVO" = "sim" ]; then
    echo "📦 A carregar imagem com containerd (ctr)..."
    ssh -o StrictHostKeyChecking=no root@"$IP" "ctr -n k8s.io images import /tmp/jenkins-autocontido.tar && rm /tmp/jenkins-autocontido.tar"
  else
    echo "🐳 A carregar imagem com Docker..."
    ssh -o StrictHostKeyChecking=no root@"$IP" "docker load -i /tmp/jenkins-autocontido.tar && rm /tmp/jenkins-autocontido.tar"
  fi
done

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

echo "✅ [7/8] Aplicar deployment e service Kubernetes..."

echo "✅ Avançar com o deployment do Jenkins..."
kubectl apply -f k8s/deploy-jenkins.yaml
kubectl apply -f k8s/service-jenkins.yaml

echo "⏳ A Aguardar que o PVC fique ligado ao PV..."
until kubectl get pvc -n jenkins jenkins-pvc -o jsonpath='{.status.phase}' | grep -q "Bound"; do
  sleep 2
done
echo "✅ PVC ligado ao PV com sucesso."

echo "🔄 A reiniciar pod do Jenkins para usar a imagem atualizada..."
kubectl delete pod -n jenkins --all
echo "⏳ A aguardar que o pod do Jenkins fique em Running..."
until kubectl get pod -n jenkins -l app=jenkins -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; do
  kubectl get pods -n jenkins
  sleep 3
done

sleep 40  # Dá tempo ao Jenkins para gerar o ficheiro

instalar_java



IP=$(hostname -I | awk '{print $1}')
#echo -e "\n✅ Jenkins a correr em: http://localhost:8080 ou http://$IP:8080"
#echo -e "📦 Jenkins Kubernetes exposto via NodePort em: http://$IP:32000 (caso ativado)\n"
JENKINS_URL="http://$IP:32000"
NGINX_URL="http://$IP:8083"

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

until curl -s "$JENKINS_URL/login" > /dev/null; do
  sleep 2
done

wget -q "$JENKINS_URL/jnlpJars/jenkins-cli.jar" -O jenkins-cli.jar

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

if java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth admin:"$ADMIN_PWD" get-job hello-nginx-pipeline >/dev/null 2>&1; then
  echo "⚠️  Job hello-nginx-pipeline já existe. Atualizando..."
  java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth admin:"$ADMIN_PWD" update-job hello-nginx-pipeline < hello-nginx.xml
else
  echo "✅ A criar job hello-nginx-pipeline..."
  java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth admin:"$ADMIN_PWD" create-job hello-nginx-pipeline < hello-nginx.xml
fi
java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth admin:"$ADMIN_PWD" build hello-nginx-pipeline

# Redirecionar a porta externa 8083 para o NodePort 32080, se ainda nao existir
if ! iptables -t nat -C PREROUTING -p tcp --dport 8083 -j REDIRECT --to-ports 32080 2>/dev/null; then
  iptables -t nat -A PREROUTING -p tcp --dport 8083 -j REDIRECT --to-ports 32080
fi
if ! iptables -t nat -C OUTPUT -p tcp --dport 8083 -j REDIRECT --to-ports 32080 2>/dev/null; then
  iptables -t nat -A OUTPUT -p tcp --dport 8083 -j REDIRECT --to-ports 32080
fi


echo "🎉 Jenkins configurado com sucesso e pipeline executado!"
echo "🔗 Jenkins: $JENKINS_URL"
echo "🔗 Nginx: $NGINX_URL"
