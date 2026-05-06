pipeline {
    // Build 013: agents come from the custom Jenkins agent image (docs/agent-image.md).
    // The image bundles node, kubectl, kustomize, kubeconform, gitleaks, syft, cosign,
    // trivy, dependency-check.sh, k6, and gh — so no `tools {}` block is needed.
    agent {
        kubernetes {
            label 'cicd-agent'
            defaultContainer 'cicd'
        }
    }

    environment {
        APP_NAME        = 'my-app'
        DOCKER_REGISTRY = credentials('docker-registry-url')
        DOCKER_CREDS    = credentials('docker-registry-credentials')
        // Bug 5 fix: KUBECONFIG_CRED removed — kubeconfig is fetched via
        // withCredentials inside deployToKubernetes() (more idiomatic, scoped)
        SLACK_CHANNEL   = '#deployments'
        GIT_COMMIT_SHORT = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
        IMAGE_TAG       = "${APP_NAME}:${BUILD_NUMBER}-${GIT_COMMIT_SHORT}"
        FULL_IMAGE      = "${DOCKER_REGISTRY}/${IMAGE_TAG}"
        SONAR_TOKEN     = credentials('sonarqube-token')
        // Bug 1 fix: ENV is computed in a script{} block inside Checkout so
        // the function call is not evaluated inside the environment{} block
    }

    options {
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
    }

    triggers {
        githubPush()
        // Bug 8 note: pollSCM is a safety-net fallback for environments where
        // GitHub webhooks cannot reach Jenkins (e.g. local/firewalled installs).
        // In production with working webhooks this will rarely fire.
        pollSCM('H/5 * * * *')
    }

    stages {

        // ─── STAGE 1: CHECKOUT ───────────────────────────────────────────────
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_AUTHOR     = sh(script: "git log -1 --format='%an'", returnStdout: true).trim()
                    env.GIT_MESSAGE    = sh(script: "git log -1 --format='%s'",  returnStdout: true).trim()
                    env.GIT_BRANCH_NAME = sh(script: "git rev-parse --abbrev-ref HEAD", returnStdout: true).trim()
                    // Bug 1 fix: compute ENV here instead of in environment{} block
                    // to avoid mixing Groovy function calls with declarative env vars
                    env.ENV = getEnvironment()
                }
                echo "📦 Branch: ${env.GIT_BRANCH_NAME} | Author: ${env.GIT_AUTHOR}"
                notifySlack("🔄 *Build Started* — ${APP_NAME} #${BUILD_NUMBER}\n*Branch:* ${env.GIT_BRANCH_NAME}\n*Commit:* ${env.GIT_MESSAGE}")
            }
        }

        // ─── STAGE 2: STATIC ANALYSIS & SECURITY SCAN ───────────────────────
        stage('Code Quality & Security') {
            parallel {
                stage('SonarQube Analysis') {
                    steps {
                        withSonarQubeEnv('SonarQube') {
                            sh '''
                                sonar-scanner \
                                  -Dsonar.projectKey=${APP_NAME} \
                                  -Dsonar.sources=./app \
                                  -Dsonar.host.url=${SONAR_HOST_URL} \
                                  -Dsonar.login=${SONAR_TOKEN}
                            '''
                        }
                        // Wait for Quality Gate (fail pipeline if gate fails)
                        timeout(time: 5, unit: 'MINUTES') {
                            waitForQualityGate abortPipeline: true
                        }
                    }
                }
                stage('Dependency Vulnerability Scan') {
                    steps {
                        sh '''
                            cd app
                            mkdir -p reports/dependency-check
                            # OWASP Dependency Check
                            dependency-check.sh \
                              --project "${APP_NAME}" \
                              --scan . \
                              --format "HTML" \
                              --out reports/dependency-check \
                              --failOnCVSS 8
                        '''
                    }
                    post {
                        always {
                            publishHTML(target: [
                                allowMissing: false,
                                reportDir: 'app/reports/dependency-check',
                                reportFiles: 'dependency-check-report.html',
                                reportName: 'OWASP Dependency Check'
                            ])
                        }
                    }
                }
                stage('Lint') {
                    steps {
                        sh '''
                            cd app
                            mkdir -p reports
                            npm run lint -- --format checkstyle --output-file reports/eslint.xml || true
                        '''
                        recordIssues(tools: [esLint(pattern: 'app/reports/eslint.xml')])
                    }
                }
                // Build 009 — point 13: secret scanning via gitleaks.
                // || true makes this warn-only for now; tighten to fail on
                // CRITICAL findings once a baseline suppression list is established.
                stage('Gitleaks') {
                    steps {
                        sh '''
                            mkdir -p reports
                            gitleaks detect --source . --report-format sarif --report-path reports/gitleaks.sarif --redact || true
                        '''
                    }
                    post {
                        always {
                            archiveArtifacts artifacts: 'reports/gitleaks.sarif', allowEmptyArchive: true
                        }
                    }
                }
            }
        }

        // ─── STAGE 3: BUILD ───────────────────────────────────────────────────
        stage('Build') {
            steps {
                sh '''
                    cd app
                    npm ci --prefer-offline
                    npm run build
                '''
                echo "✅ Build complete"
            }
            post {
                success {
                    archiveArtifacts artifacts: 'app/dist/**', fingerprint: true
                }
            }
        }

        // ─── STAGE 4: VALIDATE MANIFESTS ─────────────────────────────────────
        // Build 009 — point 15: kubeconform validates every kustomize overlay.
        // -ignore-missing-schemas is required because Argo Rollouts CRDs do not
        // have schemas in the default kubeconform schema set.
        stage('Validate Manifests') {
            steps {
                sh '''
                    mkdir -p reports
                    # Validate every kustomize overlay
                    for overlay in k8s/overlays/*/; do
                        echo "Validating $overlay"
                        kubectl kustomize "$overlay" | kubeconform -strict -summary -output text -ignore-missing-schemas - | tee -a reports/kubeconform.txt
                    done
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/kubeconform.txt', allowEmptyArchive: true
                }
            }
        }

        // ─── STAGE 5: UNIT & INTEGRATION TESTS ───────────────────────────────
        stage('Test') {
            parallel {
                stage('Unit Tests') {
                    steps {
                        sh '''
                            cd app
                            mkdir -p reports
                            npm run test:unit -- \
                              --coverage \
                              --coverageReporters=cobertura \
                              --reporters=jest-junit \
                              --outputFile=reports/junit-unit.xml
                        '''
                    }
                    post {
                        always {
                            junit 'app/reports/junit-unit.xml'
                            cobertura coberturaReportFile: 'app/coverage/cobertura-coverage.xml',
                                      failUnhealthy: true,
                                      failUnstable: false,
                                      lineCoverageTargets: '80, 70, 60'
                        }
                    }
                }
                stage('Integration Tests') {
                    steps {
                        sh '''
                            cd app
                            mkdir -p reports
                            npm run test:integration -- \
                              --reporters=jest-junit \
                              --outputFile=reports/junit-integration.xml
                        '''
                    }
                    post {
                        always {
                            junit 'app/reports/junit-integration.xml'
                        }
                    }
                }
            }
        }

        // ─── STAGE 6: DEPLOY → PR PREVIEW ────────────────────────────────────
        // Build 009 — point 29: wire scripts/pr-preview-up.sh (added in Build 011).
        // This stage runs only on pull-request builds (changeRequest() condition).
        // PR teardown lives in a separate Jenkins job triggered by the GitHub
        // "pull_request closed" webhook — see scripts/pr-preview-down.sh.
        stage('Deploy → PR Preview') {
            when {
                changeRequest()
            }
            steps {
                withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG_FILE')]) {
                    sh '''
                        export KUBECONFIG=$KUBECONFIG_FILE
                        ./scripts/pr-preview-up.sh ${CHANGE_ID}
                    '''
                }
            }
            post {
                success {
                    notifySlack("🌿 *PR Preview Ready* — PR #${CHANGE_ID}: https://preview-pr-${CHANGE_ID}.${APP_NAME}.internal")
                }
            }
        }

        // ─── STAGE 7: DOCKER BUILD & PUSH ────────────────────────────────────
        stage('Docker Build & Push') {
            steps {
                script {
                    // Bug 7 fix: strip any scheme from the credential value so we
                    // don't end up with "https://https://..." if the credential
                    // already contains the scheme.
                    def registryUrl = "${DOCKER_REGISTRY}".replaceFirst(/^https?:\/\//, '')
                    docker.withRegistry("https://${registryUrl}", 'docker-registry-credentials') {
                        def appImage = docker.build("${FULL_IMAGE}", "-f docker/Dockerfile .")

                        // Container image vulnerability scan (Trivy)
                        sh "trivy image --exit-code 1 --severity HIGH,CRITICAL ${FULL_IMAGE} || true"

                        appImage.push()
                        appImage.push('latest')
                        echo "🐳 Pushed ${FULL_IMAGE}"
                    }

                    // Build 009 — point 13: generate SBOM and sign the image.
                    sh """
                        mkdir -p reports
                        # Generate CycloneDX SBOM with syft
                        syft "${FULL_IMAGE}" -o cyclonedx-json > reports/sbom.cdx.json
                    """

                    // Keyless cosign signing via OIDC (Sigstore / Fulcio + Rekor).
                    // In production this requires the Jenkins agent to have a valid
                    // OIDC token issued by a Fulcio-trusted OIDC provider.
                    sh """
                        COSIGN_EXPERIMENTAL=1 cosign sign --yes "${FULL_IMAGE}"
                    """

                    archiveArtifacts artifacts: 'reports/sbom.cdx.json', allowEmptyArchive: true
                }
            }
        }

        // ─── STAGE 8: DEPLOY TO STAGING ──────────────────────────────────────
        stage('Deploy → Staging') {
            when { branch 'develop' }
            steps {
                script {
                    deployToKubernetes('staging', FULL_IMAGE)
                    runSmokeTests('staging')
                }
            }
        }

        // ─── STAGE 9: PERFORMANCE TESTS (STAGING) ────────────────────────────
        stage('Performance Tests') {
            when { branch 'develop' }
            steps {
                sh '''
                    mkdir -p reports
                    k6 run \
                      --out json=reports/k6-results.json \
                      --env BASE_URL=https://staging.${APP_NAME}.internal \
                      tests/performance/load-test.js
                '''
            }
            post {
                always {
                    publishHTML(target: [
                        reportDir: 'reports',
                        reportFiles: 'k6-results.json',
                        reportName: 'k6 Performance Report'
                    ])
                }
            }
        }

        // ─── STAGE 10: DEPLOY TO PRODUCTION ──────────────────────────────────
        stage('Deploy → Production') {
            when { branch 'main' }
            steps {
                // Manual gate for production
                timeout(time: 15, unit: 'MINUTES') {
                    input message: "Deploy ${IMAGE_TAG} to PRODUCTION?", ok: 'Deploy Now'
                }
                script {
                    // Save current image for potential rollback
                    env.PREVIOUS_IMAGE = sh(
                        script: "kubectl get deployment ${APP_NAME} -n production -o jsonpath='{.spec.template.spec.containers[0].image}' || echo 'none'",
                        returnStdout: true
                    ).trim()

                    deployToKubernetes('production', FULL_IMAGE)
                    runSmokeTests('production')
                }
            }
        }

        // ─── STAGE 11: RELEASE ───────────────────────────────────────────────
        // Build 009 — point 18: wire scripts/release.sh (added in Build 010).
        // Triggered only when a vX.Y.Z annotated tag is pushed to origin.
        // NOTE: the `gh` CLI must be available on the Jenkins agent (install via
        // the agent Dockerfile or a tools{} block using a custom tool installer).
        stage('Release') {
            when {
                buildingTag()
                tag pattern: "v\\d+\\.\\d+\\.\\d+", comparator: "REGEXP"
            }
            steps {
                // Re-tag the already-built image with the SemVer tag and push
                sh '''
                    docker tag ${FULL_IMAGE} ${DOCKER_REGISTRY}/${APP_NAME}:${TAG_NAME}
                    docker push ${DOCKER_REGISTRY}/${APP_NAME}:${TAG_NAME}
                '''
                // Create a GitHub Release via gh CLI.
                // gh requires a GitHub token; wrap in withCredentials so the
                // token is available as GH_TOKEN without leaking into the log.
                withCredentials([string(credentialsId: 'github-credentials', variable: 'GH_TOKEN')]) {
                    sh '''
                        gh release create ${TAG_NAME} \
                          --title "Release ${TAG_NAME}" \
                          --notes "Automated release for ${TAG_NAME}. See CHANGELOG.md for details."
                    '''
                }
            }
        }

    } // end stages

    // ─── POST ─────────────────────────────────────────────────────────────────
    post {
        success {
            notifySlack("✅ *Deployment Successful* — ${APP_NAME} #${BUILD_NUMBER}\n*Image:* `${IMAGE_TAG}`\n*Env:* ${ENV}")
        }
        failure {
            script {
                notifySlack("🚨 *Pipeline FAILED* — ${APP_NAME} #${BUILD_NUMBER}\n*Stage:* ${env.STAGE_NAME}\n*Branch:* ${env.GIT_BRANCH_NAME}")
                if (env.BRANCH_NAME == 'main' && env.PREVIOUS_IMAGE && env.PREVIOUS_IMAGE != 'none') {
                    echo "⚠️  Production deploy failed — initiating automatic rollback to ${env.PREVIOUS_IMAGE}"
                    rollback('production', env.PREVIOUS_IMAGE)
                    notifySlack("🔁 *Auto-Rollback Completed* — ${APP_NAME} rolled back to `${env.PREVIOUS_IMAGE}`")
                }
            }
        }
        unstable {
            notifySlack("⚠️ *Build Unstable* — ${APP_NAME} #${BUILD_NUMBER} — check test results")
        }
        always {
            cleanWs()
        }
    }

} // end pipeline

// ─── SHARED FUNCTIONS ─────────────────────────────────────────────────────────

def deployToKubernetes(String namespace, String image) {
    withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
        sh """
            export KUBECONFIG=\${KUBECONFIG}

            # Set the image in the Kustomize overlay and apply
            cd k8s/overlays/${namespace}
            kustomize edit set image my-app=${image}
            kubectl apply -k . --namespace=${namespace}

            # Wait for rollout to complete (timeout 5 min)
            kubectl rollout status deployment/${APP_NAME} \
              --namespace=${namespace} \
              --timeout=300s

            echo "✅ Deployed to ${namespace}"
        """
    }
}

def rollback(String namespace, String previousImage) {
    withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
        sh """
            export KUBECONFIG=\${KUBECONFIG}
            kubectl set image deployment/${APP_NAME} \
              ${APP_NAME}=${previousImage} \
              --namespace=${namespace}
            kubectl rollout status deployment/${APP_NAME} \
              --namespace=${namespace} \
              --timeout=180s
            echo "🔁 Rollback complete → ${previousImage}"
        """
    }
}

def runSmokeTests(String env) {
    // Bug 9 fix: use dir() block instead of bare "cd tests" — the latter is
    // fragile because the working directory is not guaranteed across sh steps.
    // Bug 2 fix: run npm ci before the test command so smoke-test deps are
    // installed (the tests/ directory has its own package.json).
    dir('tests') {
        sh """
            npm ci --prefer-offline --no-audit --no-fund
            BASE_URL=https://${env}.${APP_NAME}.internal \
            npm run test:smoke -- \
              --reporters=jest-junit \
              --outputFile=reports/junit-smoke-${env}.xml
        """
    }
    junit "tests/reports/junit-smoke-${env}.xml"
}

def notifySlack(String message) {
    slackSend(
        channel: env.SLACK_CHANNEL,
        color: currentBuild.result == 'SUCCESS' ? 'good' : 'danger',
        message: message
    )
}

def getEnvironment() {
    def branch = env.BRANCH_NAME ?: 'unknown'
    if (branch == 'main') return 'production'
    if (branch == 'develop') return 'staging'
    return 'development'
}
