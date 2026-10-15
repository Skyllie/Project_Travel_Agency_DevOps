// CI/CD for TravelAgency:
//   build the image (Maven + tests inside the Docker build) -> check the Terraform code ->
//   deploy with Terraform (MySQL, N Tomcats, Nginx) -> smoke-test through the load balancer.
// The job is created by jenkins/casc.yaml. Jenkins checks the branch for new commits every 5 minutes.

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
        timeout(time: 30, unit: 'MINUTES')
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
    }

    stages {
        stage('Version') {
            steps {
                script {
                    env.IMAGE_TAG = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    env.IMAGE = "travelagency:${env.IMAGE_TAG}"
                    currentBuild.description = "${env.IMAGE}, ${params.LB_ALGORITHM}, ${params.APP_REPLICAS} servers"
                }
                echo "Image: ${env.IMAGE}"
            }
        }

        stage('Build and test') {
            steps {
                // The first stage of the Dockerfile runs "mvn package": compile, unit tests
                // (the project has none yet; new ones in src/test run here), WAR
                // --provenance=false: an unchanged app keeps the same image ID, so Terraform does not restart it
                sh 'docker build --provenance=false -t "$IMAGE" -t travelagency:latest .'
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
                        "TF_VAR_app_image=${env.IMAGE}",
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
    }

    post {
        success {
            echo "Deployed ${env.IMAGE}: http://<Ubuntu IP>:${env.LB_PORT}/"
        }
        always {
            // Keep the three newest application images (an image in use cannot be removed anyway)
            sh '''
                docker images travelagency --format '{{.Tag}}' | grep -vxE 'latest|local' | tail -n +4 \
                  | xargs -r -I{} docker rmi "travelagency:{}" || true
            '''
        }
    }
}
