# Common commands. Run `make` or `make help` to list targets.
.DEFAULT_GOAL := help

# ── Repo-wide ────────────────────────────────────────────────────────────────
.PHONY: help install lint format check clean

help: ## List available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install: ## Install root + app dev dependencies
	npm install
	cd app && npm install

lint: ## ESLint (app)
	cd app && npm run lint

format: ## Prettier write across the whole repo
	npx prettier --write .

check: ## Repo sanity check (lint, manifests, scripts)
	./scripts/check-repo.sh

clean: ## Remove build / test / coverage artifacts
	rm -rf app/dist app/coverage app/reports reports

# ── App ──────────────────────────────────────────────────────────────────────
.PHONY: dev test test-unit test-integration test-e2e test-mutation migrate

dev: ## Run the app locally with hot reload
	cd app && npm run dev

test: ## Unit + integration tests
	cd app && npm test

test-unit: ## Unit tests only
	cd app && npm run test:unit

test-integration: ## Integration tests only
	cd app && npm run test:integration

test-e2e: ## Playwright E2E (requires running app or BASE_URL)
	cd app && npm run test:e2e

test-mutation: ## Stryker mutation tests (slow)
	cd app && npm run test:mutation

migrate: ## Run knex migrations against the configured DB
	cd app && npm run migrate

# ── Docker / images ──────────────────────────────────────────────────────────
.PHONY: build build-multiarch agent-image

build: ## Build the production image (single arch, local tag)
	docker build -t my-app:dev -f docker/Dockerfile .

build-multiarch: ## Multi-arch build (amd64 + arm64) — requires buildx + binfmt
	docker buildx build --platform linux/amd64,linux/arm64 -t my-app:dev -f docker/Dockerfile .

agent-image: ## Build the custom Jenkins agent image
	docker build -t jenkins-cicd-agent:dev -f docker/jenkins-agent/Dockerfile docker/jenkins-agent

# ── Local stack (docker-compose) ─────────────────────────────────────────────
.PHONY: up down logs

up: ## Boot local CI stack (Jenkins, SonarQube, Postgres, Redis, registry, app)
	docker-compose -f docker/docker-compose.yml up -d

down: ## Stop the local CI stack
	docker-compose -f docker/docker-compose.yml down

logs: ## Tail local stack logs
	docker-compose -f docker/docker-compose.yml logs -f

# ── Cluster / GitOps ─────────────────────────────────────────────────────────
.PHONY: bootstrap kind-up kind-down skaffold-dev skaffold-run

kind-up: ## Spin up the local kind cluster (config in docs/cluster-setup.md)
	kind create cluster --config docs/kind-config.yaml || true

kind-down: ## Tear down the kind cluster
	kind delete cluster

bootstrap: ## Bootstrap Argo CD + platform Apps on the current cluster
	./scripts/setup.sh --bootstrap-argo

skaffold-dev: ## Live-reload dev against the current cluster
	skaffold dev

skaffold-run: ## One-shot deploy via Skaffold
	skaffold run

# ── Secrets ──────────────────────────────────────────────────────────────────
.PHONY: seal-secret

# Usage: make seal-secret NS=production NAME=my-app-secrets KEYS="db-host=app-db db-password=changeme"
seal-secret: ## Seal a Secret with kubeseal. Args: NS, NAME, KEYS
	@./scripts/seal-secret.sh $(NS) $(NAME) $(KEYS)

# ── Repo governance ──────────────────────────────────────────────────────────
.PHONY: branch-protection release

branch-protection: ## Apply GitHub branch protection rules via gh API
	./scripts/setup-branch-protection.sh

# Usage: make release VERSION=1.2.3
release: ## Bump app/package.json, commit, tag (no push)
	@./scripts/release.sh $(VERSION)
