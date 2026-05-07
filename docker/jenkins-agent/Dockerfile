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
FROM jenkins/inbound-agent:latest-jdk17

USER root

# ── Tool versions (bumped via Dependabot/Renovate when ready) ────────────────
ENV NODE_VERSION=20.18.1 \
    KUBECTL_VERSION=v1.31.4 \
    KUSTOMIZE_VERSION=v5.5.0 \
    KUBECONFORM_VERSION=v0.6.7 \
    GITLEAKS_VERSION=8.21.4 \
    SYFT_VERSION=v1.18.1 \
    COSIGN_VERSION=v2.4.1 \
    TRIVY_VERSION=v0.58.1 \
    GRYPE_VERSION=v0.85.0 \
    DEPENDENCY_CHECK_VERSION=11.1.1 \
    K6_VERSION=v0.55.0 \
    GH_VERSION=2.63.2

# ── Base packages ────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates jq git unzip xz-utils gnupg \
        docker.io \
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
RUN curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}/trivy_${TRIVY_VERSION#v}_Linux-64bit.tar.gz" \
        | tar -xzf - -C /usr/local/bin trivy

# ── grype (SBOM vulnerability scanner) ──────────────────────────────────────
# Build 019: grype scans CycloneDX / SPDX SBOMs for known CVEs using the
# Anchore Grype DB. Complements Trivy (different NVD feed cadence and heuristics).
# Used in the 'Scan SBOM' Jenkinsfile stage: grype sbom:reports/sbom.cdx.json
RUN curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \
        | sh -s -- -b /usr/local/bin "${GRYPE_VERSION}"

# ── OWASP Dependency Check ───────────────────────────────────────────────────
RUN curl -fsSLo /tmp/dc.zip \
        "https://github.com/jeremylong/DependencyCheck/releases/download/v${DEPENDENCY_CHECK_VERSION}/dependency-check-${DEPENDENCY_CHECK_VERSION}-release.zip" \
    && unzip -q /tmp/dc.zip -d /opt \
    && ln -s /opt/dependency-check/bin/dependency-check.sh /usr/local/bin/dependency-check.sh \
    && rm /tmp/dc.zip

# ── k6 (load testing) ────────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-amd64.tar.gz" \
        | tar -xzf - --strip-components=1 -C /usr/local/bin "k6-${K6_VERSION}-linux-amd64/k6"

# ── GitHub CLI (used by Release stage) ───────────────────────────────────────
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
        | tar -xzf - --strip-components=2 -C /usr/local/bin "gh_${GH_VERSION}_linux_amd64/bin/gh"

# ── Sanity check (fails the build if any tool is missing from PATH) ─────────
RUN node --version \
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
