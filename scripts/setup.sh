#!/bin/bash

case "$1" in
  "local")
    echo "🚀 Starting local CI/CD stack..."
    cd docker
    docker compose up -d
    echo "Jenkins: http://localhost:8080"
    echo "SonarQube: http://localhost:9000"
    echo "Registry: localhost:5000"
    ;;
  "k8s")
    echo "Kubernetes setup not implemented for local demo"
    ;;
  *)
    echo "Usage: $0 {local|k8s}"
    ;;
esac

