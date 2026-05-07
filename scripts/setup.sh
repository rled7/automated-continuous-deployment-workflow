#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup.sh — Bootstrap the entire CI/CD infrastructure
# Usage: ./scripts/setup.sh [--local | --k8s | --bootstrap-argo]
#
#   --local            Start the local Docker Compose stack (Jenkins, SonarQube, Registry)
#   --k8s              Create namespaces, secrets, and apply monitoring manifests
#   --bootstrap-argo   Install Argo CD on the current kubectl context and apply
#                      the platform AppProject + root Application (app-of-apps)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MODE="${1:---local}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Prerequisites check ───────────────────────────────────────────────────────
check_prereqs() {
    info "Checking prerequisites..."
    local missing=()
    for cmd in docker docker-compose kubectl git node npm; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || error "Missing tools: ${missing[*]}"
    info "All prerequisites found ✅"
}

# ── Environment file ──────────────────────────────────────────────────────────
setup_env() {
    if [[ ! -f "$ROOT_DIR/.env" ]]; then
        info "Creating .env from .env.example..."
        cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
        warn "⚠️  Edit .env with your secrets before continuing"
        exit 0
    fi
    set -a; source "$ROOT_DIR/.env"; set +a
    info ".env loaded ✅"
}

# ── Local mode: Docker Compose ────────────────────────────────────────────────
start_local() {
    info "Starting local CI/CD stack (Docker Compose)..."
    cd "$ROOT_DIR/docker"
    docker-compose pull
    docker-compose up -d

    info "Waiting for Jenkins to be ready..."
    until curl -s http://localhost:8080/login | grep -q 'Jenkins'; do
        sleep 5; echo -n "."
    done
    echo ""
    info "Jenkins ready at http://localhost:8080 ✅"
    info "SonarQube ready at http://localhost:9000 ✅"
    info "Docker Registry at http://localhost:5000 ✅"
}

# ── Argo CD bootstrap mode ────────────────────────────────────────────────────
bootstrap_argo() {
    info "Bootstrapping Argo CD (app-of-apps)..."

    # Validate required tools
    local missing=()
    for cmd in kubectl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || error "Missing tools for --bootstrap-argo: ${missing[*]}"

    # 1. Install Argo CD
    info "Creating argocd namespace (idempotent)..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

    info "Installing Argo CD..."
    kubectl apply -n argocd \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    # 2. Wait for argocd-server
    info "Waiting for argocd-server rollout (up to 3 minutes)..."
    kubectl rollout status -n argocd deployment/argocd-server --timeout=180s

    # 3. Apply platform AppProject and root Application
    info "Applying platform AppProject..."
    kubectl apply -f "$ROOT_DIR/argocd/bootstrap/projects/platform.yaml"

    info "Applying root bootstrap Application..."
    kubectl apply -f "$ROOT_DIR/argocd/bootstrap/root.yaml"

    # 4. Print follow-up steps
    echo ""
    info "Argo CD bootstrap complete ✅"
    echo ""
    echo "  Next steps:"
    echo ""
    echo "  1. Watch platform components sync:"
    echo "       kubectl get applications -n argocd --watch"
    echo ""
    echo "  2. Once all platform apps are Healthy/Synced, apply my-app:"
    echo "       kubectl apply -f $ROOT_DIR/argocd/AppProject.yaml"
    echo "       kubectl apply -f $ROOT_DIR/argocd/Application-staging.yaml"
    echo "       kubectl apply -f $ROOT_DIR/argocd/Application-production.yaml"
    echo ""
    echo "  3. Seal cluster secrets before the app can start:"
    echo "       $SCRIPT_DIR/seal-secret.sh production my-app-secrets \\"
    echo "           db-host=<value> db-password=<value> \\"
    echo "         > $ROOT_DIR/k8s/secrets/my-app-secrets.yaml"
    echo "       (See docs/secrets.md for full details.)"
    echo ""
    echo "  4. Install kubeseal CLI if not present:"
    echo "       brew install kubeseal  # or download from GitHub releases"
    echo ""
    echo "  5. Access Argo CD UI:"
    echo "       kubectl port-forward svc/argocd-server -n argocd 8081:443"
    echo "       # https://localhost:8081"
    echo "       # Password: kubectl -n argocd get secret argocd-initial-admin-secret \\"
    echo "       #   -o jsonpath='{.data.password}' | base64 -d"
}

# ── Kubernetes mode ───────────────────────────────────────────────────────────
setup_k8s() {
    info "Setting up Kubernetes namespaces..."
    kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace staging    --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    info "Creating Docker registry secret..."
    kubectl create secret docker-registry docker-registry-secret \
        --docker-server="$DOCKER_REGISTRY" \
        --docker-username="$DOCKER_USER" \
        --docker-password="$DOCKER_PASSWORD" \
        --namespace=production --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret docker-registry docker-registry-secret \
        --docker-server="$DOCKER_REGISTRY" \
        --docker-username="$DOCKER_USER" \
        --docker-password="$DOCKER_PASSWORD" \
        --namespace=staging --dry-run=client -o yaml | kubectl apply -f -

    info "Creating app secrets..."
    kubectl create secret generic my-app-secrets \
        --from-literal=db-host="$DB_HOST" \
        --from-literal=db-password="$DB_PASSWORD" \
        --namespace=production --dry-run=client -o yaml | kubectl apply -f -

    info "Applying monitoring stack..."
    kubectl apply -f "$ROOT_DIR/monitoring/" --namespace=monitoring

    info "Kubernetes setup complete ✅"
}

# ── Install app dependencies ──────────────────────────────────────────────────
install_deps() {
    info "Installing app dependencies..."
    cd "$ROOT_DIR/app" && npm ci
    info "Dependencies installed ✅"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔═══════════════════════════════════════╗"
    echo "║     Jenkins CI/CD Setup Script        ║"
    echo "╚═══════════════════════════════════════╝"
    echo ""

    check_prereqs
    setup_env
    install_deps

    case "$MODE" in
        --local)           start_local     ;;
        --k8s)             setup_k8s       ;;
        --bootstrap-argo)  bootstrap_argo  ;;
        *)       error "Unknown mode: $MODE. Use --local, --k8s, or --bootstrap-argo" ;;
    esac

    echo ""
    info "🎉 Setup complete! Push a commit to trigger the pipeline."
}

main "$@"
