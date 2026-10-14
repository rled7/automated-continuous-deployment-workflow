# ─────────────────────────────────────────────────────────────────────────────
# Custom Jenkins agent image for the my-app pipeline.
# Bundles every CLI the Jenkinsfile invokes so stages don't fail with
# "command not found" on a vanilla agent.
#
# Base: jenkins/inbound-agent (Debian, JDK 17, includes the Jenkins agent JAR
# and the user account Jenkins expects). Custom additions are layered on top.
#
# Build:    docker build -t ghcr.io/<ORG>/jenkins-cicd-agent:<TAG> -f docker/jenkins-agent/Dockerfile docker/jenkins-agent
# Push:     docker push ghcr.io/<ORG>/jenkins-cicd-agent:<TAG>
# Use:      Update docker/jenkins/jenkins.yaml `clouds.kubernetes.templates`
#           to reference the pushed tag.
# ─────────────────────────────────────────────────────────────────────────────
# Trivy's GitHub release tarballs are gone (404 for v0.58.x and later), so its
# binary comes from the official image, pinned to the same version.
FROM aquasec/trivy:0.58.1 AS trivy

# The Debian release is pinned: package names differ between releases (on
# trixie docker.io is only the daemon; the CLI is docker-cli).
FROM jenkins/inbound-agent:latest-trixie-jdk17

USER root

# ── Tool versions (bumped via Dependabot/Renovate when ready) ────────────────
ENV NODE_VERSION=20.18.1 \
    KUBECTL_VERSION=v1.31.4 \
    KUSTOMIZE_VERSION=v5.5.0 \
    KUBECONFORM_VERSION=v0.6.7 \
    GITLEAKS_VERSION=8.21.4 \
    SYFT_VERSION=v1.18.1 \
    COSIGN_VERSION=v2.4.1 \
    GRYPE_VERSION=v0.85.0 \
    DEPENDENCY_CHECK_VERSION=12.2.2 \
    K6_VERSION=v0.55.0 \
    GH_VERSION=2.63.2 \
    PLAYWRIGHT_VERSION=1.64.0 \
    SONAR_SCANNER_VERSION=6.2.1.4610

# ── Base packages ────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates jq git unzip xz-utils gnupg \
        docker-cli docker-buildx \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js + npm (matches JCasC tool version, no separate install needed) ──
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        | tar -xJf - -C /usr/local --strip-components=1

# ── kubectl ──────────────────────────────────────────────────────────────────
RUN curl -fsSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl

# ── kustomize ────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
        | tar -xzf - -C /usr/local/bin

# ── kubeconform ──────────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
        | tar -xzf - -C /usr/local/bin kubeconform

# ── gitleaks ─────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
        | tar -xzf - -C /usr/local/bin gitleaks

# ── syft (SBOM) ──────────────────────────────────────────────────────────────
RUN curl -fsSL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
        | sh -s -- -b /usr/local/bin "${SYFT_VERSION}"

# ── cosign (image signing) ───────────────────────────────────────────────────
RUN curl -fsSLo /usr/local/bin/cosign \
        "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" \
    && chmod +x /usr/local/bin/cosign

# ── trivy (image vuln scan) ──────────────────────────────────────────────────
COPY --from=trivy /usr/local/bin/trivy /usr/local/bin/trivy

# ── grype (SBOM vulnerability scanner) ──────────────────────────────────────
# Build 019: grype scans CycloneDX / SPDX SBOMs for known CVEs using the
# Anchore Grype DB. Complements Trivy (different NVD feed cadence and heuristics).
# Used in the 'Scan SBOM' Jenkinsfile stage: grype sbom:reports/sbom.cdx.json
RUN curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \
        | sh -s -- -b /usr/local/bin "${GRYPE_VERSION}"

# ── OWASP Dependency Check ───────────────────────────────────────────────────
# Its database lives in /opt/dependency-check/data unless --data says
# otherwise. The agent runs as jenkins, so that directory must be jenkins's:
# otherwise every scan fails with "Unable to connect to the dependency-check
# database".
# 11.x cannot store some current NVD records (reference URLs longer than its
# 1000-character column). Releases since 12 are published on Maven Central.
RUN curl -fsSLo /tmp/dc.zip \
        "https://repo1.maven.org/maven2/org/owasp/dependency-check-cli/${DEPENDENCY_CHECK_VERSION}/dependency-check-cli-${DEPENDENCY_CHECK_VERSION}-release.zip" \
    && unzip -q /tmp/dc.zip -d /opt \
    && ln -s /opt/dependency-check/bin/dependency-check.sh /usr/local/bin/dependency-check.sh \
    && mkdir -p /opt/dependency-check/data \
    && chown -R jenkins:jenkins /opt/dependency-check/data \
    && rm /tmp/dc.zip

# ── k6 (load testing) ────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-amd64.tar.gz" \
        | tar -xzf - --strip-components=1 -C /usr/local/bin "k6-${K6_VERSION}-linux-amd64/k6"

# ── SonarScanner CLI (SonarQube Analysis stage; bundles its own JRE) ─────────
RUN curl -fsSLo /tmp/sonar.zip \
        "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" \
    && unzip -q /tmp/sonar.zip -d /opt \
    && ln -s "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64/bin/sonar-scanner" /usr/local/bin/sonar-scanner \
    && rm /tmp/sonar.zip

# ── GitHub CLI (used by Release stage) ───────────────────────────────────────
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
        | tar -xzf - --strip-components=2 -C /usr/local/bin "gh_${GH_VERSION}_linux_amd64/bin/gh"

# ── Playwright's Chromium (E2E Tests stage) ──────────────────────────────────
# The browser's system libraries come from apt, which needs root, and the
# pipeline runs as jenkins: they are installed here, with the browser for the
# Playwright version app/package-lock.json pins (keep PLAYWRIGHT_VERSION in
# step). If the app moves ahead, the stage downloads the newer browser into
# PLAYWRIGHT_BROWSERS_PATH as jenkins; the libraries rarely change. Only the
# headless shell, which headless runs use (the full browser adds ~400 MB).
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN npx -y "playwright@${PLAYWRIGHT_VERSION}" install --with-deps --only-shell chromium \
    && chown -R jenkins:jenkins /opt/ms-playwright \
    && rm -rf /var/lib/apt/lists/* /root/.npm

# ── Sanity check (fails the build if any tool is missing from PATH) ─────────
RUN node --version \
    && docker --version \
    && docker buildx version \
    && sonar-scanner --version \
    && npm --version \
    && kubectl version --client \
    && kustomize version \
    && kubeconform -v \
    && gitleaks version \
    && syft version \
    && cosign version \
    && trivy --version \
    && grype version \
    && dependency-check.sh --version \
    && k6 version \
    && gh --version

USER jenkins
