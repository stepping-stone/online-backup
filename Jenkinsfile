#!groovy
@Library('rpmlib') _

pipeline {
   agent {
        docker {
            image 'localhost:5000/sst/build-base:latest'
            registryUrl 'http://localhost:5000'
        }
    }
    stages{
        stage('Checkout'){
            steps {
                checkout scm
            }
        }
        stage('Build'){
            steps {
                sh '/usr/local/scripts/build.sh'
            }
            post {
                always {
                    stash includes: '*.rpm', name: 'RPMs'
                }
            }
        }
        stage('Publish'){
            agent{ label 'master' }
            steps {
                unstash 'RPMs'
                publishRPM '.'
            }
        }
    }
}
