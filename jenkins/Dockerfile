# Jenkins for the TravelAgency pipeline, configured as code (no setup wizard, no clicking).
FROM jenkins/jenkins:lts-jdk21

USER root

# Docker CLI + buildx: Jenkins builds images on the host Docker through the mounted socket
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg unzip \
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

USER jenkins

# Plugins are installed at build time, so Jenkins starts ready to use
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Configuration as code: admin user, credentials and the pipeline job
COPY casc.yaml /var/jenkins_conf/casc.yaml
ENV CASC_JENKINS_CONFIG=/var/jenkins_conf/casc.yaml \
    JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Xmx768m"
