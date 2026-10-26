# TravelAgency — DevOps Project

TravelAgency is a web application for a travel agency: users find and book hotels in different countries, and a manager role adds hotels and rooms and sees all users and their bookings. It is built with Java, Spring MVC, Spring Security, Hibernate, JSP and MySQL, and is packaged as a WAR file for Tomcat 9.

This repository is a DevOps project built around the application. Each deployment approach lives in its own branch with its own README. Weekly reports are in [`REPORTS/`](REPORTS).

## Branches

| Branch | What it shows |
| --- | --- |
| `manual-setup` | Manual deployment on one Ubuntu machine: Java 17, Maven, MySQL, Tomcat 9 as a systemd service |
| `ansible` | Two Oracle Linux 9 VMs — the application and the database on separate machines — created with Vagrant and configured with Ansible |
| `docker` | The application and MySQL in containers with Docker Compose; multi-stage Dockerfile |
| `docker-load-balancer` | Three application servers behind an Nginx load balancer; switchable algorithms, sticky sessions, failover |
| `terraform` | The load-balanced stack as code: Terraform with the Docker provider |
| `jenkins` | CI/CD: a Jenkins pipeline builds, tests and deploys every commit with Terraform |
| `artifact-management` | Nexus Repository: every build stores its WAR and image there, the servers run the image from Nexus, rollback to any stored version |
| `security-scanning` | Snyk scans the dependencies, Trivy and Grype the image; a security gate stops builds with fixable critical vulnerabilities; SBOM in Nexus |
| `code-inspection` | SonarQube analyses the code and the unit tests (JUnit 5, JaCoCo) on every build; the build waits for the quality gate |
| `monitoring` | Prometheus and Grafana: host, containers, Tomcat, MySQL, Nginx and the CI tools; alerts; load test and capacity estimate |

Each branch starts from the previous one: `main` → `docker` → `docker-load-balancer` → `terraform` → `jenkins` → `artifact-management` → `security-scanning` → `code-inspection` → `monitoring`.

## Application Settings

The application reads its settings from environment variables:

| Variable | Meaning |
| --- | --- |
| `DB_TRAVELAGENCY_URL` | JDBC URL, for example `jdbc:mysql://localhost:3306/travelagency?useSSL=false&allowPublicKeyRetrieval=true` |
| `DB_TRAVELAGENCY_USER` | Database user |
| `DB_TRAVELAGENCY_PASSWORD` | Database password |
| `HBM2DDL_AUTO` | Hibernate schema mode; default `update` (tables are created if missing, data is kept) |
| `DB_SEED` | `true` loads the demo data from `insert.sql` at startup — use it only once, on an empty database; default `false` |

Build with JDK 17 and Maven:

```bash
mvn -B clean package -DskipTests      # result: target/TravelAgency.war
```

Deploy it to **Tomcat 9** as **`ROOT.war`**. The code uses `javax.*`, so it does not run on Tomcat 10 or newer, and the forms use absolute paths, so the application has to live at `/`.

## Checking the Project

`scripts/check-project.sh` checks every branch and the whole Git history for secrets and hardcoded settings, runs the scanners (gitleaks, hadolint, shellcheck, trivy, `nginx -t`, `terraform validate`, `ansible-lint`) and, when the stack runs on this machine, checks the containers, the site and Jenkins. It changes nothing in the branches or in the running containers (`--help` lists the few things it downloads). Scanners that are not installed are downloaded once to `~/.cache/travelagency-check` and checked against pinned SHA-256 sums.

```bash
bash scripts/check-project.sh                  # everything
bash scripts/check-project.sh --skip runtime   # only the code, not the running stack
bash scripts/check-project.sh --help           # all options
```

Every result is PASS, WARN (worth fixing or an accepted risk), FAIL (must be fixed), SKIP (could not be checked here) or INFO. The report is also saved to `/tmp`. The exit code is 1 when there is at least one FAIL, so the script can run in a pipeline too.
