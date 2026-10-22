// CI/CD for TravelAgency with code inspection, security scans and artifact management in Nexus:
//   build the image (Maven + unit tests inside the Docker build) -> code inspection in SonarQube with its
//   quality gate -> scan the dependencies (Snyk) and the image
//   (Trivy, Grype) -> security gate -> publish the WAR, its SBOM and the image to Nexus ->
//   pull the image back from Nexus -> check the Terraform code -> deploy with Terraform (MySQL, N Tomcats,
//   Nginx) -> smoke-test through the load balancer -> keep the newest versions in Nexus.
// ROLLBACK_TO=<commit id> skips the build and deploys a version that is already in Nexus.
// The job is created by jenkins/casc.yaml. Jenkins checks the branch for new commits every 5 minutes.

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
        // The first build with scans downloads the vulnerability databases (about 1 GB)
        timeout(time: 45, unit: 'MINUTES')
    }

    triggers {
        pollSCM('H/5 * * * *')
    }

    parameters {
        choice(name: 'LB_ALGORITHM',
               choices: ['round_robin', 'weighted', 'least_conn', 'ip_hash', 'hash', 'random', 'backup'],
               description: 'Nginx load-balancing algorithm')
        choice(name: 'APP_REPLICAS', choices: ['3', '2', '1', '4', '5'],
               description: 'Number of application servers')
        booleanParam(name: 'LB_STICKY', defaultValue: true,
                     description: 'Sticky sessions by the Tomcat jvmRoute in JSESSIONID')
        string(name: 'ROLLBACK_TO', defaultValue: '', trim: true,
               description: 'Deploy a version already in Nexus (7-character commit id, e.g. 3f2a9c1) instead of building. Empty: build this commit')
    }

    environment {
        LB_PORT             = '80'
        // The load balancer is published on the host; this name points to the host
        APP_URL             = 'http://host.docker.internal:80'
        TF_IN_AUTOMATION    = '1'
        TF_INPUT            = '0'
        // State and provider cache live in jenkins_home, so they survive between builds
        TF_STATE            = '/var/jenkins_home/tfstate/travelagency.tfstate'
        TF_PLUGIN_CACHE_DIR = '/var/jenkins_home/.terraform.d/plugin-cache'
        // Nexus (nexus/docker-compose.yml): UI and REST API, published on the host
        NEXUS_URL           = 'http://host.docker.internal:8091'
        NEXUS_MAVEN_REPO    = 'travelagency-maven'
        NEXUS_DOCKER_REPO   = 'travelagency-docker'
        // Registry of travelagency-docker. The host Docker daemon pushes and pulls, so for it this is localhost
        REGISTRY            = 'localhost:8092'
        // How many versions stay in each Nexus repository
        NEXUS_KEEP          = '5'
        // The security gate stops the build on a vulnerability of this severity or higher that has a fix
        SCAN_FAIL_ON        = 'CRITICAL'
        // SonarQube (sonarqube/docker-compose.yml), published on the host
        SONAR_HOST_URL      = 'http://host.docker.internal:9000'
        SONAR_MAVEN_PLUGIN  = 'org.sonarsource.scanner.maven:sonar-maven-plugin:5.8.0.7211'
    }

    stages {
        stage('Version') {
            steps {
                // Reports of the previous build must not reach the security gate
                sh 'rm -rf reports'
                script {
                    def rollback = (params.ROLLBACK_TO ?: '').trim()
                    env.ROLLBACK = rollback ? 'true' : 'false'
                    if (rollback) {
                        env.IMAGE_TAG = rollback
                        sh '''
                            echo "$IMAGE_TAG" | grep -qxE '[0-9a-f]{7}' \
                              || { echo "ROLLBACK_TO must be a 7-character commit id of a version in Nexus, e.g. 3f2a9c1, not: $IMAGE_TAG"; exit 1; }
                        '''
                    } else {
                        env.IMAGE_TAG = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    }
                    env.IMAGE = "travelagency:${env.IMAGE_TAG}"
                    env.REGISTRY_IMAGE = "${env.REGISTRY}/${env.IMAGE}"
                    currentBuild.description = (rollback ? 'rollback to ' : '') +
                        "${env.IMAGE_TAG}, ${params.LB_ALGORITHM}, ${params.APP_REPLICAS} servers"
                }
                echo "Image: ${env.REGISTRY_IMAGE}"
            }
        }

        stage('Build and test') {
            when { environment name: 'ROLLBACK', value: 'false' }
            steps {
                // The first stage of the Dockerfile runs "mvn package": compile, unit tests
                // (the project has none yet; new ones in src/test run here), WAR
                // --provenance=false: an unchanged app keeps the same image ID, so Terraform does not restart it
                sh 'docker build --provenance=false -t "$IMAGE" -t travelagency:latest .'
            }
        }

        stage('Code inspection: SonarQube') {
            when { environment name: 'ROLLBACK', value: 'false' }
            steps {
                // mvn clean verify: compile, unit tests, JaCoCo coverage; then the analysis. qualitygate.wait makes
                // Maven wait for the quality gate of SonarQube and fail the build when the gate fails
                withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                    sh '''
                        mvn -B -ntp clean verify "$SONAR_MAVEN_PLUGIN:sonar" \
                            -Dsonar.host.url="$SONAR_HOST_URL" \
                            -Dsonar.qualitygate.wait=true -Dsonar.qualitygate.timeout=300
                    '''
                }
            }
            post {
                always {
                    junit testResults: 'target/surefire-reports/*.xml', allowEmptyResults: true
                }
            }
        }

        // The three scans only collect reports; the security gate decides
        stage('Dependencies: Snyk') {
            when { environment name: 'ROLLBACK', value: 'false' }
            steps {
                // SCA: the libraries of pom.xml and their dependencies against the Snyk database
                withCredentials([string(credentialsId: 'snyk-token', variable: 'SNYK_TOKEN')]) {
                    sh 'bash ci/scan.sh snyk'
                }
            }
        }

        stage('Image: Trivy') {
            when { environment name: 'ROLLBACK', value: 'false' }
            steps {
                // OS packages of the base image and the jars in the WAR; also writes the SBOM
                sh 'bash ci/scan.sh trivy'
            }
        }

        stage('Image: Grype') {
            when { environment name: 'ROLLBACK', value: 'false' }
            steps {
                // The same image against a second vulnerability database
                sh 'bash ci/scan.sh grype'
            }
        }

        stage('Security gate') {
            when { environment name: 'ROLLBACK', value: 'false' }
            steps {
                // Nothing is published or deployed if a scanner found a SCAN_FAIL_ON vulnerability with a fix
                sh 'bash ci/scan.sh gate'
            }
        }

        stage('Publish to Nexus') {
            when { environment name: 'ROLLBACK', value: 'false' }
            steps {
                // WAR and SBOM -> travelagency-maven as org.project:TravelAgency:1.0-<commit>,
                // image -> travelagency-docker as travelagency:<commit>. Both are write-once
                withCredentials([usernamePassword(credentialsId: 'nexus-ci',
                                                  usernameVariable: 'NEXUS_USER', passwordVariable: 'NEXUS_PASSWORD')]) {
                    sh 'bash ci/nexus.sh publish'
                }
            }
        }

        stage('Pull from Nexus') {
            steps {
                // The deploy uses the image stored in Nexus, not the one left over from the build
                withCredentials([usernamePassword(credentialsId: 'nexus-ci',
                                                  usernameVariable: 'NEXUS_USER', passwordVariable: 'NEXUS_PASSWORD')]) {
                    sh 'bash ci/nexus.sh pull'
                }
            }
        }

        stage('Terraform check') {
            steps {
                dir('terraform') {
                    sh '''
                        mkdir -p "$(dirname "$TF_STATE")" "$TF_PLUGIN_CACHE_DIR"
                        terraform fmt -check -recursive -diff
                        terraform init -backend-config="path=$TF_STATE"
                        terraform validate
                    '''
                }
            }
        }

        stage('Deploy') {
            steps {
                withCredentials([
                    string(credentialsId: 'travel-db-password', variable: 'TF_VAR_db_password'),
                    string(credentialsId: 'travel-db-root-password', variable: 'TF_VAR_mysql_root_password')
                ]) {
                    withEnv([
                        "TF_VAR_app_image=${env.REGISTRY_IMAGE}",
                        "TF_VAR_app_replicas=${params.APP_REPLICAS}",
                        "TF_VAR_lb_algorithm=${params.LB_ALGORITHM}",
                        "TF_VAR_lb_sticky=${params.LB_STICKY}",
                        "TF_VAR_lb_port=${env.LB_PORT}"
                    ]) {
                        dir('terraform') {
                            sh '''
                                terraform plan -out=tfplan
                                terraform apply tfplan
                                rm -f tfplan
                                terraform output
                            '''
                        }
                    }
                }
            }
        }

        stage('Smoke test') {
            steps {
                withEnv(["ALGORITHM=${params.LB_ALGORITHM}", "REPLICAS=${params.APP_REPLICAS}"]) {
                    sh '''
                        url="$APP_URL/form-login"
                        code=000
                        for i in $(seq 1 30); do
                            code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
                            [ "$code" = 200 ] && break
                            sleep 5
                        done
                        if [ "$code" != 200 ]; then
                            echo "The site does not answer through the load balancer: HTTP $code"
                            exit 1
                        fi
                        echo "HTTP 200 from $url"

                        echo "15 new visitors, algorithm $ALGORITHM:"
                        for i in $(seq 1 15); do
                            curl -s -o /dev/null -D - "$url" | tr -d '\\r' | awk 'tolower($1) == "x-served-by:" { print $2 }'
                        done | sort | uniq -c | tee servers.txt
                        servers=$(wc -l < servers.txt)

                        if [ "$ALGORITHM" = round_robin ] && [ "$servers" -ne "$REPLICAS" ]; then
                            echo "Round robin must use all $REPLICAS servers, but $servers answered"
                            exit 1
                        fi
                    '''
                }
            }
        }

        stage('Nexus retention') {
            when { environment name: 'ROLLBACK', value: 'false' }
            steps {
                // Old versions are deleted only after the new one works. A failure here does not fail the build
                catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                    withCredentials([usernamePassword(credentialsId: 'nexus-ci',
                                                      usernameVariable: 'NEXUS_USER', passwordVariable: 'NEXUS_PASSWORD')]) {
                        sh 'bash ci/nexus.sh retention'
                    }
                }
            }
        }
    }

    post {
        success {
            echo "Deployed ${env.REGISTRY_IMAGE}: http://<Ubuntu IP>:${env.LB_PORT}/"
        }
        always {
            // Scanner reports: files of the build, and the pages Trivy, Grype and Snyk on the build page
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
            recordIssues(enabledForFailure: true, skipBlames: true, skipPublishingChecks: true,
                         tools: [sarif(id: 'snyk', name: 'Snyk', pattern: 'reports/snyk.sarif'),
                                 trivy(pattern: 'reports/trivy.json'),
                                 grype(pattern: 'reports/grype.json')])
            // Keep the three newest local tags of both names, and the current one. Nexus keeps the history
            sh '''
                for repo in travelagency "$REGISTRY/travelagency"; do
                    docker images "$repo" --format '{{.Tag}}' | grep -vxE "latest|local|${IMAGE_TAG:-none}" | tail -n +4 \
                      | xargs -r -I{} docker rmi "$repo:{}" || true
                done
            '''
        }
    }
}
