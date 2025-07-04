# Projeto: Pipeline CI/CD com Jenkins, Docker e Kubernetes

Este repositório demonstra uma pipeline de CI/CD completa com as seguintes tecnologias:

- Jenkins personalizado (auto-contido) com Docker, Git e `kubectl`
- Construção de imagem Docker para aplicação web
- Push da imagem para registry Docker local
- Deployment em cluster Kubernetes local
- Jenkins implementado diretamente em Kubernetes

---

## Estrutura do Projeto

```plaintext
Jenkins-lab/
├── Dockerfile              # Dockerfile da aplicação hello-nginx
├── main.html               # Página HTML de exemplo
├── Dockerfile.jenkins      # Jenkins com Docker, Git e kubectl instalados
├── Jenkinsfile             # Pipeline declarativa Jenkins
├── setup.sh                # Script automatizado de instalação e deployment
└── k8s/
    ├── deployment.yaml         # Deployment do hello-nginx
    ├── service.yaml            # Service do hello-nginx
    ├── sa-jenkins.yaml         # ServiceAccount + RBAC para Jenkins
    ├── volume-jenkins.yaml     # PV e PVC persistentes para Jenkins
    ├── deploy-jenkins.yaml     # Deployment do Jenkins no Kubernetes
    ├── service-jenkins.yaml    # Service NodePort do Jenkins
    └── nginx-hostport-pod.yaml.template  # Template do Pod nginx usado na pipeline
```

---

## 1. Construir a imagem personalizada do Jenkins

```bash
docker build -t jenkins-autocontido -f Dockerfile.jenkins .
```

## 2. Correr o Jenkins com permissões root

```bash
docker run -d \
  --name jenkins \
  -u 0 \
  --restart=always \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins-autocontido
```

## 3. Jenkinsfile (Pipeline Declarativa)

```groovy
pipeline {
  agent any

  environment {
    // Definir as variáveis
    KUBECTL      = "${WORKSPACE}/kubectl"
    NAMESPACE    = "default"
    CONFIGMAP    = "nginx-html"
    POD_NAME     = "nginx-server"
    HTML_REPO    = "https://github.com/richardtsteil/dev.git"
    HTML_FILE    = "main.html"
    HOST_PORT    = "8083"
  }

  stages {
    stage('Tranferir kubectl') {
      steps {
        sh '''
          curl -sLo "$KUBECTL" \
            "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
          chmod +x "$KUBECTL"
        '''
      }
    }

    stage('Rever o HTML') {
      steps {
        git url: "${HTML_REPO}", branch: 'master'
      }
    }

   stage('Criar o ConfigMap') {
      steps {
        sh """
          kubectl create configmap ${CONFIGMAP} \
            --from-file=index.html=${HTML_FILE} \
            --namespace=${NAMESPACE} \
            --dry-run=client -o yaml > cm.yaml

          kubectl apply -f cm.yaml
        """
      }
    }

    stage('Deploy nginx Pod') {
      steps {
        sh '''
          kubectl delete pod ${POD_NAME} --namespace=${NAMESPACE} --ignore-not-found=true
          sed -e "s|__POD_NAME__|${POD_NAME}|g" \
              -e "s|__NAMESPACE__|${NAMESPACE}|g" \
              -e "s|__HOST_PORT__|${HOST_PORT}|g" \
              -e "s|__CONFIGMAP__|${CONFIGMAP}|g" \
              k8s/nginx-hostport-pod.yaml.template > nginx-hostport-pod.yaml
          kubectl apply -f nginx-hostport-pod.yaml
        '''
      }
    }
  }

  post {
    success {
      script {
        def nodeName = sh(
          script: "kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.nodeName}'",
          returnStdout: true
        ).trim()
        // get that node's InternalIP
        def nodeIP = sh(
          script: "kubectl get node ${nodeName} -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'",
          returnStdout: true
        ).trim()
        echo "nginx is running at http://${nodeIP}:${HOST_PORT}"
      }
    }
    failure {
      echo "Deployment failed – check pipeline logs for details."
    }
  }
}
```

---

## 4. Dockerfile da Aplicação

```Dockerfile
FROM nginx:alpine
COPY main.html /usr/share/nginx/html/index.html
```

---

## 5. Deployment e Service Kubernetes

### deploy-jenkins.yaml
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jenkins
  namespace: jenkins
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jenkins-server
  template:
    metadata:
      labels:
        app: jenkins-server
    spec:
      serviceAccountName: jenkins-sa
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
      containers:
        - name: jenkins
          image: jenkins/jenkins:lts
          resources:
            limits:
              memory: "2Gi"
              cpu: "1000m"
            requests:
              memory: "500Mi"
              cpu: "500m"
          ports:
            - name: httpport
              containerPort: 8080
            - name: jnlpport
              containerPort: 50000
          livenessProbe:
            httpGet:
              path: "/login"
              port: 8080
            initialDelaySeconds: 90
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 5
          readinessProbe:
            httpGet:
              path: "/login"
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: jenkins-data
              mountPath: /var/jenkins_home
      volumes:
        - name: jenkins-data
          persistentVolumeClaim:
            claimName: jenkins-pvc

```

### sa-jenkins.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jenkins-cr
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/exec", "services", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-sa
  namespace: jenkins
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins-crb
subjects:
  - kind: ServiceAccount
    name: jenkins-sa
    namespace: jenkins
roleRef:
  kind: ClusterRole
  name: jenkins-cr
  apiGroup: rbac.authorization.k8s.io
```

### volume-jenkins.yaml
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: jenkins-pv
  labels:
    type: local
spec:
  storageClassName: local-storage
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Filesystem
  local:
    path: /mnt/jenkins
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - worker1
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jenkins-pvc
  namespace: jenkins
spec:
  storageClassName: local-storage
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 3Gi
```

### service-jenkins.yaml
```yaml
apiVersion: v1
kind: Service
metadata:
  name: jenkins-service
  namespace: jenkins
spec:
  type: NodePort
  selector:
    app: jenkins-server
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: 32000
    - port: 50000
      targetPort: 50000
      nodePort: 32001
```

---

## 6. Verificação Final

```bash
kubectl get pods -n jenkins
kubectl get svc -n jenkins
IP=$(hostname -I | awk '{print $1}')
curl http://$IP:32000
```

---

📌 ## Instruções para usar:
1. Faz clone do repositório
```bash
git clone https://github.com/andrerpxavier/Jenkins-lab.git
cd Jenkins-lab
```
2.Torna o script executável:
```bash
chmod +x setup.sh
```
3.Executa a configuração completa:
```bash
./setup.sh
```

---

## Resultado
A pipeline irá:
- Instalar e configurar Docker e Jenkins (caso necessário)
- Criar Docker registry local
- Buildar a imagem hello-nginx
- Fazer push para o registry local
- Aplicar os manifests no cluster Kubernetes
- Servir a aplicação via NodePort 32080 (encaminhada para a porta 8083)
- Servir o Jenkins na porta 32000 via Kubernetes
- Ao finalizar, o *setup.sh* exibe os links de acesso ao Jenkins e à aplicação Nginx
  e cria um redirecionamento local da porta 8083 para o NodePort 32080

✅ Sistema CI/CD totalmente funcional, automatizado com setup.sh
