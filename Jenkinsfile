pipeline {
  agent any

  environment {
    IMAGE_NAME = "hello-nginx"
    IMAGE_TAG = "latest"
    REGISTRY = "${env.REGISTRY_ADDR ?: 'localhost:5000'}"
    K8S_DEPLOYMENT_PATH = "k8s/deployment.yaml"
    K8S_SERVICE_PATH = "k8s/service.yaml"
  }

  stages {
    stage('Preparar Workspace') {
      steps {
        cleanWs()
      }
    }

    stage('Clone Repositório') {
      steps {
        git branch: 'main', url: 'https://github.com/andrerpxavier/Jenkins-lab.git'
      }
    }

    stage('Iniciar Registry Local') {
      steps {
        sh '''
          if ! docker ps --format '{{.Names}}' | grep -q '^registry$'; then
            if docker ps -a --format '{{.Names}}' | grep -q '^registry$'; then
              docker rm -f registry
            fi
            docker run -d --name registry --restart=always -p 5000:5000 registry:2
          fi
        '''
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
        sh '''
          export KUBECONFIG=/tmp/kubeconfig

          SERVER="https://kubernetes.default.svc"
          NAMESPACE="default"
          TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
          CA_CERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

          cat <<EOF > $KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    server: $SERVER
    certificate-authority: $CA_CERT
contexts:
- name: in-cluster-context
  context:
    cluster: in-cluster
    namespace: $NAMESPACE
    user: in-cluster-user
current-context: in-cluster-context
users:
- name: in-cluster-user
  user:
    token: $TOKEN
EOF

          sed "s|localhost:5000|${REGISTRY}|g" ${K8S_DEPLOYMENT_PATH} | kubectl --kubeconfig=$KUBECONFIG apply -f -
          sed "s|localhost:5000|${REGISTRY}|g" ${K8S_SERVICE_PATH}   | kubectl --kubeconfig=$KUBECONFIG apply -f -
        '''
      }
    }
  }
}
