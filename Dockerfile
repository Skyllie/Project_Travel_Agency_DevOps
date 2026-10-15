# TravelAgency image: the WAR is built inside Docker, so the host needs no Java or Maven.

# ---- Stage 1: build target/TravelAgency.war with Maven and JDK 17
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
COPY src ./src
# The cache mount keeps downloaded dependencies between builds
RUN --mount=type=cache,target=/root/.m2 mvn -B -q package

# ---- Stage 2: run it on Tomcat 9 (the code uses javax.*, so Tomcat 10+ will not work)
FROM tomcat:9.0-jdk17-temurin-noble

# mysql-client: the entrypoint checks whether the database is empty; curl: health check
RUN apt-get update \
 && apt-get install -y --no-install-recommends mysql-client curl \
 && rm -rf /var/lib/apt/lists/* \
 && rm -rf /usr/local/tomcat/webapps/* \
 && useradd --system --no-create-home --shell /usr/sbin/nologin tomcat \
 && cd /usr/local/tomcat \
 && mkdir -p conf logs temp work webapps \
 && chown -R tomcat:tomcat conf logs temp work webapps

# ROOT.war: the JSP forms use absolute paths, so the application must live at "/"
COPY --from=build --chown=tomcat:tomcat /src/target/TravelAgency.war /usr/local/tomcat/webapps/ROOT.war
COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV HBM2DDL_AUTO=update \
    DB_SEED=auto \
    JAVA_OPTS="-Xmx384m"

USER tomcat
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=5s --start-period=120s --retries=5 \
  CMD curl -fsS -o /dev/null http://localhost:8080/form-login || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["catalina.sh", "run"]
