pipeline {
    agent any

    environment {
        APP_NAME        = 'my-app'
        DOCKER_REGISTRY = credentials('docker-registry-url')
        DOCKER_CREDS    = credentials('docker-registry-credentials')
        KUBECONFIG_CRED = credentials('kubeconfig')
        SLACK_CHANNEL   = '#deployments'
        GIT_COMMIT_SHORT = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
        IMAGE_TAG       = "${APP_NAME}:${BUILD_NUMBER}-${GIT_COMMIT_SHORT}"
        FULL_IMAGE      = "${DOCKER_REGISTRY}/${IMAGE_TAG}"
        SONAR_TOKEN     = credentials('sonarqube-token')
        ENV             = getEnvironment()
    }

    options {
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
    }

    triggers {
        githubPush()
        pollSCM('H/5 * * * *') // fallback polling every 5 minutes
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
                            npm run lint -- --format checkstyle --output-file reports/eslint.xml || true
                        '''
                        recordIssues(tools: [esLint(pattern: 'app/reports/eslint.xml')])
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

        // ─── STAGE 4: UNIT & INTEGRATION TESTS ───────────────────────────────
        stage('Test') {
            parallel {
                stage('Unit Tests') {
                    steps {
                        sh '''
                            cd app
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

        // ─── STAGE 5: DOCKER BUILD & PUSH ────────────────────────────────────
        stage('Docker Build & Push') {
            steps {
                script {
                    docker.withRegistry("https://${DOCKER_REGISTRY}", 'docker-registry-credentials') {
                        def appImage = docker.build("${FULL_IMAGE}", "-f docker/Dockerfile .")

                        // Container image vulnerability scan (Trivy)
                        sh "trivy image --exit-code 1 --severity HIGH,CRITICAL ${FULL_IMAGE} || true"

                        appImage.push()
                        appImage.push('latest')
                        echo "🐳 Pushed ${FULL_IMAGE}"
                    }
                }
            }
        }

        // ─── STAGE 6: DEPLOY TO STAGING ──────────────────────────────────────
        stage('Deploy → Staging') {
            when { branch 'develop' }
            steps {
                script {
                    deployToKubernetes('staging', FULL_IMAGE)
                    runSmokeTests('staging')
                }
            }
        }

        // ─── STAGE 7: PERFORMANCE TESTS (STAGING) ────────────────────────────
        stage('Performance Tests') {
            when { branch 'develop' }
            steps {
                sh '''
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

        // ─── STAGE 8: DEPLOY TO PRODUCTION ───────────────────────────────────
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

            # Substitute image tag in manifests
            sed -i 's|IMAGE_PLACEHOLDER|${image}|g' k8s/${namespace}/*.yaml

            # Apply manifests (rolling update)
            kubectl apply -f k8s/${namespace}/ --namespace=${namespace}

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
    sh """
        cd tests
        BASE_URL=https://${env}.${APP_NAME}.internal \
        npm run test:smoke -- \
          --reporters=jest-junit \
          --outputFile=reports/junit-smoke-${env}.xml
    """
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