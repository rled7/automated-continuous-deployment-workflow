// Nightly: keeps dependency-check's vulnerability database on the shared
// volume current (scripts/dependency-check-db-update.sh), so builds scan it
// with --noupdate instead of downloading NVD themselves. The job
// dependency-check-db-update in docker/jenkins/jenkins.yaml runs this file.
//
// Needs DEPENDENCY_CHECK_DATA on the cicd-agent pod template, backed by a
// persistent volume (see jenkins.yaml). Without it builds update their own
// copy and there is nothing to keep current.
pipeline {
    agent {
        kubernetes {
            inheritFrom 'cicd-agent'
            defaultContainer 'cicd'
        }
    }
    options {
        timeout(time: 90, unit: 'MINUTES')
        disableConcurrentBuilds()
    }
    stages {
        stage('Update the dependency-check database') {
            steps {
                withCredentials([string(credentialsId: 'nvd-api-key', variable: 'NVD_API_KEY')]) {
                    sh '''
                        if [ -z "${DEPENDENCY_CHECK_DATA:-}" ]; then
                            echo "No shared database (DEPENDENCY_CHECK_DATA) on the pod template: builds update their own."
                            exit 0
                        fi
                        scripts/dependency-check-db-update.sh "$DEPENDENCY_CHECK_DATA"
                    '''
                }
            }
        }
    }
}
