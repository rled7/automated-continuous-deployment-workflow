# Changelog

All notable file-level changes to this repo, tracked per build.

## Build 001 — File layout cleanup
**Date:** 2026-05-05
**Scope:** Phase A, Task 1

### Renamed
- `README` → `README.md`

### Moved
- `Load test.js` → `tests/performance/load-test.js`
- `Smoke.test` → `tests/smoke/smoke.test.js`
- `Prometheus` → `monitoring/prometheus.yaml`
- `Jenkins` → `docker/jenkins/jenkins.yaml` (JCasC config; referenced by docker-compose volumes)

### Deleted (redundant draft)
- `Deployment` (content merged into `k8s/production/deployment.yaml`)
- `Docker compose` (content merged into `docker/docker-compose.yml`)
- `DockerFile` (duplicate of `docker/Dockerfile`; only whitespace difference)
- `Setup` (content merged into `scripts/setup.sh`)

### Merged content
- `Deployment` → `k8s/production/deployment.yaml`: merged Namespace resource, Deployment labels/annotations, topologySpreadConstraints, terminationGracePeriodSeconds, imagePullPolicy, env vars (NODE_ENV, PORT, DB_HOST, DB_PASSWORD, REDIS_URL), startupProbe, securityContext, volumeMounts/volumes, imagePullSecrets, HPA memory metric, Service resource, Ingress resource; kept stray's `memory: "256Mi"` request and probe timings (initialDelaySeconds: 15, periodSeconds: 20) as the more production-ready values.
- `Docker compose` → `docker/docker-compose.yml`: merged container_name, restart policies, privileged/user settings, Jenkins JCasC env vars and volume mounts, sonarqube lts-community image with postgres backend (sonar-db), sonarqube_logs volume, registry_data volume, app-db service, redis service, cicd network definition.
- `Setup` → `scripts/setup.sh`: replaced minimal stub with full production script including set -euo pipefail, prerequisites check, .env loading, docker-compose pull + readiness wait, full Kubernetes namespace/secret/monitoring setup, and npm ci step.

## Build 002 — Hygiene basics
**Date:** 2026-05-05
**Scope:** Phase A, Task 2

### Added
- `.gitignore`
- `.env.example`

### Untracked (kept on disk, removed from git)
- `app/node_modules/`
- `app/dist/`
