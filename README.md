# Projeto: Pipeline CI/CD com Jenkins, Docker e Kubernetes

Este repositório demonstra uma pipeline de CI/CD completa com as seguintes tecnologias:
- Jenkins personalizado com Docker e Git
- Construção de imagem Docker
- Push para registry local
- Deployment em cluster Kubernetes local

---

## Estrutura do Projeto

```plaintext
Jenkins-lab/
├── Dockerfile            # Dockerfile da aplicação hello-nginx
├── main.html             # Página HTML de exemplo
├── Dockerfile.jenkins    # Jenkins com Docker e Git
├── Jenkinsfile           # Pipeline declarativa Jenkins
└── k8s/
    ├── deployment.yaml   # Deployment do Kubernetes
    └── service.yaml      # Service do Kubernetes
```

---

## 1. Construir a imagem personalizada do Jenkins

```bash
docker build -t jenkins-with-docker -f Dockerfile.jenkins .
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
  -v ~/.kube:/root/.kube \
  -v /usr/bin/kubectl:/usr/bin/kubectl \
  jenkins-with-docker
```

## 3. Jenkinsfile (Pipeline)

```groovy
pipeline {
  agent any

  environment {
    IMAGE_NAME = "hello-nginx"
    IMAGE_TAG = "latest"
    REGISTRY = "localhost:5000"
    K8S_DEPLOYMENT_PATH = "k8s/deployment.yaml"
    K8S_SERVICE_PATH = "k8s/service.yaml"
  }

  stages {
    stage('Preparar Workspace') {
      steps { cleanWs() }
    }

    stage('Clone Repositório') {
      steps {
        git branch: 'main', url: 'https://github.com/andrerpxavier/Jenkins-lab.git'
      }
    }

    stage('Build da imagem Docker') {
      steps {
        sh """
          docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .
          docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
        """
      }
    }

    stage('Push para Registry Local') {
      steps {
        sh "docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
      }
    }

    stage('Atualizar Deployment Kubernetes') {
      steps {
        sh "kubectl apply -f ${K8S_DEPLOYMENT_PATH}"
        sh "kubectl apply -f ${K8S_SERVICE_PATH}"
      }
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

### deployment.yaml
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      nodeName: servidor1
      containers:
        - name: nginx
          image: localhost:5000/hello-nginx
          imagePullPolicy: Always
          ports:
            - containerPort: 80
```

### service.yaml
```yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-nginx-service
spec:
  selector:
    app: hello
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
      nodePort: 30080
  type: NodePort
```

---

## 6. Verificação Final

```bash
kubectl get pods
kubectl get svc
curl http://<IP-do-servidor>:30080
```

---

## Resultado
A aplicação é automaticamente: 
- clonada do GitHub;
- convertida em imagem Docker;
- enviada para o registry local;
- implementada no cluster Kubernetes.

✅ Pipeline concluída com sucesso!
