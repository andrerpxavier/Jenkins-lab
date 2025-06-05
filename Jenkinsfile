pipeline {
  agent any

  environment {
    IMAGE_NAME = "hello-nginx"
    TAG = "latest"
    REGISTRY = "localhost:5000" // opcional
  }

  stages {
    stage('Clone') {
      steps {
        git 'https://github.com/andrerpxavier/Jenkins-lab.git'
      }
    }

    stage('Build Docker Image') {
      steps {
        sh 'docker build -t $IMAGE_NAME:$TAG .'
      }
    }

    stage('Deploy to Kubernetes') {
      steps {
        sh 'kubectl apply -f k8s/deployment.yaml'
        sh 'kubectl apply -f k8s/service.yaml'
      }
    }
  }
}

