#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup.sh — Bootstrap the entire CI/CD infrastructure
# Usage: ./scripts/setup.sh [--local | --k8s | --bootstrap-argo]
#
#   --local            Start the local Docker Compose stack (Jenkins controller,
#                      SonarQube, Registry). Builds need Jenkins in a cluster:
#                      see "Running builds" in README.md.
#   --k8s              Create namespaces, secrets, and the Prometheus Pushgateway
#   --bootstrap-argo   Install Argo CD on the current kubectl context and apply
#                      the platform AppProject + root Application (app-of-apps)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MODE="${1:---local}"

# Argo CD release --bootstrap-argo installs (docs/cluster-setup.md and
# argocd/bootstrap/README.md name the same one).
ARGOCD_VERSION="v3.5.5"

# Seconds --local waits for each service before giving up.
JENKINS_WAIT="${JENKINS_WAIT:-300}"
SONAR_WAIT="${SONAR_WAIT:-600}"
REGISTRY_WAIT="${REGISTRY_WAIT:-60}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Prerequisites check ───────────────────────────────────────────────────────
# Only the tools the chosen mode uses.
check_prereqs() {
    info "Checking prerequisites for $MODE..."
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || error "Missing tools for $MODE: ${missing[*]}"
    info "All prerequisites found ✅"
}

# docker/docker-compose.yml marks .env optional (env_file: required: false),
# which needs the Compose v2 plugin, 2.24 or newer.
check_compose() {
    docker compose version &>/dev/null \
        || error "Docker Compose v2 ('docker compose') not found. Install it: https://docs.docker.com/compose/install/"
    local version major minor
    version="$(docker compose version --short 2>/dev/null)"
    version="${version#v}"
    major="${version%%.*}"
    minor="${version#*.}"; minor="${minor%%.*}"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] \
        || error "Could not read the Docker Compose version ('$version')"
    if (( major < 2 || (major == 2 && minor < 24) )); then
        error "Docker Compose $version is too old: docker/docker-compose.yml needs 2.24 or newer"
    fi
    info "Docker Compose $version ✅"
}

# Fail with the names of any of the given variables that are unset or empty.
require_env() {
    local missing=()
    for var in "$@"; do
        [[ -n "${!var:-}" ]] || missing+=("$var")
    done
    [[ ${#missing[@]} -eq 0 ]] || error "Set these in .env first: ${missing[*]}"
}

# ── Environment file ──────────────────────────────────────────────────────────
setup_env() {
    if [[ ! -f "$ROOT_DIR/.env" ]]; then
        info "Creating .env from .env.example..."
        cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
        warn "⚠️  Edit .env with your secrets before continuing"
        exit 0
    fi
    set -a
    # shellcheck disable=SC1091 # .env is the user's, created above
    source "$ROOT_DIR/.env"
    set +a
    info ".env loaded ✅"
}

# ── Local mode: Docker Compose ────────────────────────────────────────────────
# wait_until <what> <timeout seconds> <command...>: run the command every 5s
# until it succeeds, or fail after the timeout.
wait_until() {
    local what=$1 timeout=$2; shift 2
    local deadline=$(( $(date +%s) + timeout ))
    info "Waiting for $what (up to ${timeout}s)..."
    until "$@"; do
        [[ "$(date +%s)" -lt "$deadline" ]] \
            || { echo ""; error "$what is not ready after ${timeout}s. Check: docker compose -f $ROOT_DIR/docker/docker-compose.yml logs"; }
        sleep 5; echo -n "."
    done
    echo ""
}

http_ok() {
    [[ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" || true)" == 200 ]]
}

sonar_status() {
    curl -s -m 5 http://localhost:9000/api/system/status \
        | sed -n 's/.*"status":"\([A-Z_]*\)".*/\1/p' || true
}

sonar_up() {
    local status
    status="$(sonar_status)"
    case "$status" in
        UP) return 0 ;;
        DB_MIGRATION_NEEDED)
            echo ""
            error "SonarQube needs a database upgrade (its data is from an older version): open http://localhost:9000/setup, run the upgrade, then rerun this script" ;;
        DB_MIGRATION_RUNNING) return 1 ;;
        DOWN)
            echo ""
            error "SonarQube reports DOWN. Check: docker compose -f $ROOT_DIR/docker/docker-compose.yml logs sonarqube" ;;
        *) return 1 ;;
    esac
}

start_local() {
    info "Starting local CI/CD stack (Docker Compose)..."
    cd "$ROOT_DIR/docker"
    docker compose pull --ignore-buildable
    docker compose up -d

    wait_until "Jenkins" "$JENKINS_WAIT" http_ok http://localhost:8080/login
    info "Jenkins ready at http://localhost:8080 ✅"
    wait_until "SonarQube" "$SONAR_WAIT" sonar_up
    info "SonarQube ready at http://localhost:9000 ✅"
    wait_until "the Docker registry" "$REGISTRY_WAIT" http_ok http://localhost:5000/v2/
    info "Docker Registry ready at http://localhost:5000 ✅"
    echo ""
    echo "  Next: connect SonarQube to Jenkins. Log in at http://localhost:9000 as"
    echo "  admin/admin, set a new password, then run:"
    echo "       SONAR_ADMIN_PASSWORD=<new password> $SCRIPT_DIR/sonarqube-setup.sh"
    echo "  and put the SONAR_TOKEN it prints in .env (then restart Jenkins)."
    echo ""
    echo "  This Jenkins has no executors and its Kubernetes cloud expects to run"
    echo "  inside a cluster, so it does not run builds. To run the pipeline, run"
    echo "  Jenkins in a cluster: see \"Running builds\" in README.md."
}

# ── Argo CD bootstrap mode ────────────────────────────────────────────────────
bootstrap_argo() {
    info "Bootstrapping Argo CD (app-of-apps)..."

    # 1. Install Argo CD
    info "Creating argocd namespace (idempotent)..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

    # Server-side: the ApplicationSet CRD is too big for the annotation
    # client-side apply keeps (262144 bytes).
    info "Installing Argo CD $ARGOCD_VERSION..."
    kubectl apply --server-side --force-conflicts -n argocd \
        -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

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
# The .dockerconfigjson for registry-credentials, built from the environment
# so the password is never on a command line.
registry_config_json() {
    jq -n '{auths: {(env.DOCKER_REGISTRY): {
        username: env.DOCKER_USER,
        password: env.DOCKER_PASSWORD,
        auth: ("\(env.DOCKER_USER):\(env.DOCKER_PASSWORD)" | @base64)}}}'
}

setup_k8s() {
    require_env DOCKER_REGISTRY DOCKER_USER DOCKER_PASSWORD DB_HOST DB_PASSWORD
    export DOCKER_REGISTRY DOCKER_USER DOCKER_PASSWORD

    info "Setting up Kubernetes namespaces..."
    kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace staging    --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    # Both overlays pull with imagePullSecrets: registry-credentials and read
    # db-host and db-password from my-app-secrets. Values go through stdin.
    local ns
    for ns in production staging; do
        info "Creating registry-credentials in $ns..."
        registry_config_json \
          | kubectl create secret generic registry-credentials \
              --type=kubernetes.io/dockerconfigjson \
              --from-file=.dockerconfigjson=/dev/stdin \
              --namespace="$ns" --dry-run=client -o yaml \
          | kubectl apply -f -

        info "Creating my-app-secrets in $ns..."
        printf 'db-host=%s\ndb-password=%s\n' "$DB_HOST" "$DB_PASSWORD" \
          | kubectl create secret generic my-app-secrets \
              --from-env-file=/dev/stdin \
              --namespace="$ns" --dry-run=client -o yaml \
          | kubectl apply -f -
    done

    # Prometheus, Grafana and the alert rules come from the
    # kube-prometheus-stack Argo CD app (--bootstrap-argo).
    info "Applying Prometheus Pushgateway..."
    kubectl apply -f "$ROOT_DIR/monitoring/pushgateway.yaml"

    info "Kubernetes setup complete ✅"
}

# ── Install app dependencies ──────────────────────────────────────────────────
install_deps() {
    info "Installing app dependencies..."
    (cd "$ROOT_DIR/app" && npm ci)
    info "Dependencies installed ✅"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔═══════════════════════════════════════╗"
    echo "║     Jenkins CI/CD Setup Script        ║"
    echo "╚═══════════════════════════════════════╝"
    echo ""

    case "$MODE" in
        --local)
            check_prereqs docker curl node npm
            check_compose
            setup_env
            install_deps
            start_local ;;
        --k8s)
            check_prereqs kubectl jq
            setup_env
            setup_k8s ;;
        --bootstrap-argo)
            check_prereqs kubectl
            setup_env
            bootstrap_argo ;;
        *)  error "Unknown mode: $MODE. Use --local, --k8s, or --bootstrap-argo" ;;
    esac

    echo ""
    info "🎉 Setup complete!"
}

main "$@"
