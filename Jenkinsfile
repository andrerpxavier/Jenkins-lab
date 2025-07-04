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
