// Tears down a pull request's preview environment (namespace preview-pr-<N>,
// created by the Deploy → PR Preview stage) when the PR is closed. The job
// pr-preview-teardown in docker/jenkins/jenkins.yaml runs this file, started by
// GitHub's pull_request webhook through the Generic Webhook Trigger, which
// sets CHANGE_ID from the payload's number.
pipeline {
    agent {
        kubernetes {
            inheritFrom 'cicd-agent'
            defaultContainer 'cicd'
        }
    }
    options {
        timeout(time: 10, unit: 'MINUTES')
    }
    stages {
        stage('Teardown PR Preview') {
            steps {
                script {
                    // CHANGE_ID comes from a webhook payload: accept a PR number only.
                    if (!(params.CHANGE_ID ==~ /\d+/)) {
                        error "CHANGE_ID must be a pull request number, got '${params.CHANGE_ID}'"
                    }
                }
                withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
                    sh './scripts/pr-preview-down.sh "$CHANGE_ID"'
                }
            }
            post {
                success {
                    slackSend(
                        channel: '#deployments',
                        color: 'good',
                        message: "PR Preview #${params.CHANGE_ID} torn down — namespace preview-pr-${params.CHANGE_ID} deleted."
                    )
                }
                failure {
                    slackSend(
                        channel: '#deployments',
                        color: 'danger',
                        message: "WARNING: PR Preview #${params.CHANGE_ID} teardown FAILED — manual cleanup may be needed (namespace preview-pr-${params.CHANGE_ID})."
                    )
                }
            }
        }
    }
}
