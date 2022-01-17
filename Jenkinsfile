#!groovy
@Library('rpmlib') _

pipeline {
    agent any
    stages{
        stage('Build'){
           agent {
                docker {
                    image 'localhost:5000/sst/build-base:latest'
                    registryUrl 'http://localhost:5000'
                }
            }
            steps {
                sh 'git clone https://github.com/stepping-stone/online-backup.git'
                sh 'cp online-backup/onlinebackup.spec /home/rpmbuild/SPECS/'
                sh 'cd /home/rpmbuild && spectool -g -R SPECS/onlinebackup.spec'
                sh 'cd /home/rpmbuild && sudo yum-builddep -y SPECS/onlinebackup.spec'
                sh 'cd /home/rpmbuild && rpmbuild -ba SPECS/onlinebackup.spec'
                sh '/usr/local/scripts/copyRPMStoHost.sh'
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
