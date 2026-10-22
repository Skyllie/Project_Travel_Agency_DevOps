# Jenkins for the TravelAgency pipeline, configured as code (no setup wizard, no clicking).
FROM jenkins/jenkins:lts-jdk21

USER root

# Docker CLI + buildx: Jenkins builds images on the host Docker through the mounted socket.
# jq: ci/nexus.sh reads the answers of the Nexus REST API
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg jq unzip \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

# Terraform, checked against the official SHA256 sums
ARG TERRAFORM_VERSION=1.16.6
RUN arch="$(dpkg --print-architecture)" \
 && cd /tmp \
 && curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" \
 && curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
 && grep "terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c - \
 && unzip -o "terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" terraform -d /usr/local/bin \
 && rm -f terraform_* \
 && terraform -version

# Security scanners and Maven, each checked against a pinned checksum (amd64, like the Ubuntu VM):
#   Trivy and Grype scan the built image, Snyk scans the Maven dependencies (it runs Maven to read them)
ARG MAVEN_VERSION=3.9.16
ARG MAVEN_SHA512=831a8591fe20c8243b1dbe7d71e3244f31d1665b0804b2e825e38cbbe5ce0cafb8338851f90780735568773e0a6cd07bbec107cda0b896b008b861075358b6f6
ARG TRIVY_VERSION=0.75.0
ARG TRIVY_SHA256=c6e65abddb348e25f10549df887045629cf28cc72453cd1c63acb717316b3f3f
ARG GRYPE_VERSION=0.120.1
ARG GRYPE_SHA256=0a9ee97ef5ae2ee953b0a80098105052e846cdbe319a57d808b519c33cd1343d
ARG SNYK_VERSION=1.1307.4
ARG SNYK_SHA256=b0baee4fa4d7d11b7df927a1046cf8137a8a89fafac8101a45c3c0e0777ddc35
RUN cd /tmp \
 && curl -fsSLo maven.tar.gz "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
 && echo "${MAVEN_SHA512}  maven.tar.gz" | sha512sum -c - \
 && tar -xzf maven.tar.gz -C /opt \
 && ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn \
 && curl -fsSLo trivy.tar.gz "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
 && echo "${TRIVY_SHA256}  trivy.tar.gz" | sha256sum -c - \
 && tar -xzf trivy.tar.gz -C /usr/local/bin trivy \
 && curl -fsSLo grype.tar.gz "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_amd64.tar.gz" \
 && echo "${GRYPE_SHA256}  grype.tar.gz" | sha256sum -c - \
 && tar -xzf grype.tar.gz -C /usr/local/bin grype \
 && curl -fsSLo /usr/local/bin/snyk "https://github.com/snyk/cli/releases/download/v${SNYK_VERSION}/snyk-linux" \
 && echo "${SNYK_SHA256}  /usr/local/bin/snyk" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/snyk \
 && rm -f /tmp/*.tar.gz \
 && mvn -v && trivy --version && grype version && snyk --version

USER jenkins

# Plugins are installed at build time, so Jenkins starts ready to use
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Configuration as code: admin user, credentials and the pipeline job
COPY casc.yaml /var/jenkins_conf/casc.yaml
ENV CASC_JENKINS_CONFIG=/var/jenkins_conf/casc.yaml \
    JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Xmx768m"
