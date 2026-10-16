// Every way a pipeline can ask for its agent. Each one must end up in a
// cicd-agent pod (docker/jenkins/jenkins.yaml) whose steps have the tools and
// a Docker daemon. The jenkins stage resolves each agent with the Kubernetes
// plugin's own code; the pipeline stage runs this job in kind.
// See docs/agent-resolution.md.
def check = '''
  # The dind sidecar can still be starting when the first step runs.
  for i in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
  missing=0
  for c in git node npm trivy sonar-scanner kubectl kustomize; do
    command -v "$c" >/dev/null || { echo "MISSING $c"; missing=1; }
  done
  docker version --format 'Docker server {{.Server.Version}}' || missing=1
  exit $missing
'''

pipeline {
    agent none
    options { timeout(time: 30, unit: 'MINUTES') }
    stages {
        stage('kubernetes inheritFrom') {
            agent {
                kubernetes {
                    inheritFrom 'cicd-agent'
                    defaultContainer 'cicd'
                }
            }
            steps { sh check }
        }
        stage('kubernetes label (deprecated)') {
            agent {
                kubernetes {
                    label 'cicd-agent'
                }
            }
            steps { sh check }
        }
        stage('kubernetes yaml only') {
            agent {
                kubernetes {
                    yaml '''
                        apiVersion: v1
                        kind: Pod
                        metadata:
                          labels:
                            purpose: agent-forms
                    '''
                }
            }
            steps { sh check }
        }
        stage('label') {
            agent { label 'cicd-agent' }
            steps { sh check }
        }
        stage('any') {
            agent any
            steps { sh check }
        }
    }
}
