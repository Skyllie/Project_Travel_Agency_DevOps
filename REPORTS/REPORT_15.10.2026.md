# DevOps Report

## General Information

**Period:** 09.10.2026 – 15.10.2026
**Report date:** 15.10.2026
**Author:** Rostyslav
**Project:** TravelAgency

**Goal:** Run TravelAgency in containers, put several application servers behind a load balancer, describe this infrastructure as code with Terraform, and build a CI/CD pipeline in Jenkins that builds, tests and deploys every commit.

**Summary:** This week covered four cards. I packed the application into a Docker image and ran it with MySQL in Docker Compose. Then I put three copies of the application behind an Nginx load balancer and tried seven balancing algorithms, sticky sessions and failover. Next I described the same stack in Terraform, so it is created, scaled and repaired with one command. Finally I set up Jenkins as code: it checks GitHub every 5 minutes, builds the image, deploys it with Terraform and runs a smoke test. Everything was run for real on the Ubuntu VM in VMware Workstation (192.168.58.128), and all four Jenkins builds finished with `SUCCESS`.

## Goals

**Main goal:** Complete the four cards:

- "Deploying a Containerized Web Application"
- "Setup Load Balancing for Webapp": deploy a couple of servers, set up Apache or Nginx as a load balancer, try different load-balancing algorithms and options
- "Implement Infrastructure as Code"
- "Implement a Continuous Integration/Continuous Delivery"

**Other goals:**

- Keep the repository structure of the reference project: one branch per approach. Each new branch starts from the previous one: `main` → `docker` → `docker-load-balancer` → `terraform` → `jenkins`.
- Keep passwords out of Git: `.env` files for Docker Compose, sensitive variables for Terraform, credentials in Jenkins.
- Check every result on a real machine, not only write the code.

## Tasks Completed

| # | Task | Status | Owner | Finished | Notes |
| --- | --- | --- | --- | --- | --- |
| 1 | Multi-stage Dockerfile: Maven 3.9 + JDK 17 build stage, Tomcat 9 + JDK 17 runtime stage. The application runs as a non-root user `tomcat`; `HEALTHCHECK` on `/form-login` | Done | Rostyslav | 15.10.2026 | Maven downloads are cached between builds; a build without code changes takes about 2 s |
| 2 | Container start script: builds the JDBC URL from `DB_HOST`, `DB_PORT`, `DB_NAME`, waits up to 3 minutes for MySQL, loads the demo data only into an empty database (`DB_SEED=auto`) | Done | Rostyslav | 15.10.2026 | |
| 3 | Docker Compose (branch `docker`): application + MySQL 8.4 with health checks, database data in a named volume, passwords in `.env` | Done | Rostyslav | 15.10.2026 | First start: the empty database was found and filled with demo data, the container became healthy, the login page returned HTTP 200 |
| 4 | Load-balanced stack (branch `docker-load-balancer`): three application containers and Nginx 1.28 with fixed IPs in 172.30.0.0/24. Only `app1` loads the demo data; `app2` and `app3` start after `app1` is healthy | Done | Rostyslav | 15.10.2026 | Healthy after 24 s (`app1`) and 51 s (`app2`, `app3`) |
| 5 | Seven load-balancing algorithms, switched with `LB_ALGORITHM`: round robin, weighted, least connections, IP hash, URL hash, random (two choices), backup server | Done | Rostyslav | 15.10.2026 | Results in the table below |
| 6 | Sticky sessions: Tomcat adds its name to the session cookie (`JSESSIONID=...app2`), Nginx sends the user back to the same server. Switched with `LB_STICKY` | Done | Rostyslav | 15.10.2026 | |
| 7 | Failover: a server is marked down after 3 failed requests for 10 s, and a failed request is retried on another server | Done | Rostyslav | 15.10.2026 | |
| 8 | Script `lb/demo.sh`: sends 15 requests and counts which server answered (header `X-Served-By`) | Done | Rostyslav | 15.10.2026 | |
| 9 | Terraform (branch `terraform`), provider `kreuzwerker/docker` 4.6: network, volume, MySQL, 1–5 application containers (`app_replicas`), Nginx with a config generated from a template. Variables are validated, passwords are sensitive | Done | Rostyslav | 15.10.2026 | |
| 10 | Checked Terraform: first `apply`, algorithm change, scaling 3 → 2 → 3, a container deleted by hand, `plan` after `apply` | Done | Rostyslav | 15.10.2026 | Results below |
| 11 | Jenkins as code (branch `jenkins`): image `jenkins/jenkins:lts-jdk21` with Docker CLI and Terraform 1.16.6 (checksum checked); plugins installed at build time; admin user, credentials and the pipeline job described in `casc.yaml` | Done | Rostyslav | 15.10.2026 | No setup wizard, no manual clicking; UI at `http://192.168.58.128:8081/` |
| 12 | `Jenkinsfile`: Version → Build and test → Terraform check (`fmt`, `init`, `validate`) → Deploy (`plan` + `apply`) → Smoke test. Parameters: algorithm, number of servers, sticky sessions. Keeps the last 3 images | Done | Rostyslav | 15.10.2026 | Polls GitHub every 5 minutes |
| 13 | Ran the pipeline: three builds started by commits, one build with parameters | Done | Rostyslav | 15.10.2026 | All four `SUCCESS` |
| 14 | README for each new branch, branch list in `main` | Done | Rostyslav | 15.10.2026 | |

## Results

**What I did:**

- Packed the application into a Docker image and ran it with MySQL in Docker Compose.
- Ran three application servers behind Nginx and checked seven algorithms, sticky sessions and failover.
- Described the same stack in Terraform and checked how it is created, changed, scaled and repaired.
- Set up Jenkins from code and built a pipeline that deploys every commit to the Ubuntu VM.

**What I achieved:**

- The application runs in containers. A clean machine needs only Docker and one `docker compose up -d --build` command.
- Every algorithm works as expected. 15 requests from `lb/demo.sh` for each one:

| Algorithm | app1 | app2 | app3 | What it shows |
| --- | --- | --- | --- | --- |
| `round_robin` | 5 | 5 | 5 | Servers in turn |
| `weighted` (3 : 1 : 1) | 9 | 3 | 3 | Exactly the set weights |
| `least_conn` | 5 | 5 | 5 | Requests come one by one, so no server is busier — same as round robin |
| `ip_hash` | 15 | 0 | 0 | All requests come from one IP, so they go to one server |
| `hash $request_uri consistent` | 0 | 0 | 15 | The same URL always goes to the same server |
| `random two least_conn` | 4 | 7 | 4 | Random choice |
| `backup` (app3 is the backup) | 8 | 7 | 0 | `app3` gets traffic only when `app1` and `app2` are both down |
| Sticky sessions on, with the session cookie | 15 | 0 | 0 | The user stays on his server |
| Sticky sessions off, with the session cookie | 5 | 5 | 5 | The cookie is ignored |
| `app2` stopped | 7 | 0 | 8 | All 15 requests answered; the Nginx log shows the timeout to `app2` and the retry |

- The stack is described in Terraform and checked:

| Check | Result |
| --- | --- |
| First `terraform apply` | 9 resources created, all containers healthy, requests 5 / 5 / 5 |
| `plan` right after `apply` | "No changes" (after the fix in Problem 6) |
| `lb_algorithm = weighted` | Only the Nginx container is recreated |
| `app_replicas = 2` | `app3` is deleted, Nginx gets the new config; requests alternate `app1` / `app2` |
| `app2` deleted by hand, `app_replicas = 3` | Terraform found the missing container and created `app2` and `app3` again |

- Every commit to the `jenkins` branch is deployed automatically:

| Build | Started by | What changed | Settings | Terraform | Smoke test |
| --- | --- | --- | --- | --- | --- |
| #1 | Commit (polling) | Pipeline and the network gateway fix | round robin, 3 servers | First deployment | Passed |
| #2 | Commit (polling) | Terraform waits until Nginx is healthy | round robin, 3 servers | 3 added, 1 changed, 3 destroyed | 5 / 5 / 5 |
| #3 | Commit (polling) | `docker build --provenance=false` | round robin, 3 servers | 3 added, 0 changed, 3 destroyed | 5 / 5 / 5 |
| #4 | Admin, with parameters | Same code as #3 | weighted, 2 servers | 1 added, 0 changed, 2 destroyed; `app1` and `app2` not touched | `app1` 11, `app2` 4 (3 : 1) |

Build #4 used the same image ID as build #3 (`c388dcc8`), so Terraform changed only what the new parameters needed. Before the fix in Problem 13, every build recreated all application containers.

## Problems and Solutions

| # | Problem | Solution | Status |
| --- | --- | --- | --- |
| 1 | The Ubuntu VM had only 670 MB of free disk space, not enough for the images. The first `growpart` changed nothing (`NOCHANGE`), because the virtual disk had not been expanded yet | Expanded the virtual disk in VMware first, then grew the partition and the file system | Done |
| 2 | Nginx would not start: `failed to bind host port 0.0.0.0:80/tcp: address already in use`. Port 80 was taken by Apache left from an earlier exercise | `sudo systemctl disable --now apache2`. A plain `docker compose up -d` left the container without the published port, so it was recreated with `--force-recreate` | Done |
| 3 | `lb/demo.sh` stopped silently when Nginx refused a connection: the script stops on any error, and `curl` returned one | The request is allowed to fail; the script prints `no-answer` for it | Done |
| 4 | Round robin was uneven. Each Nginx worker process kept its own counter | `zone` in every upstream: all workers share one counter and one list of failed servers. After that, 5 / 5 / 5 | Done |
| 5 | The `mysql` client in the start script failed when the database password contained a `"` | The password is passed in the `MYSQL_PWD` environment variable instead of an option file | Done |
| 6 | `terraform plan` right after `apply` wanted to replace the network. Docker reports the gateway 172.31.0.1, which was not in the configuration | Set the gateway explicitly: `gateway = cidrhost(var.subnet, 1)`. Now `plan` shows "No changes" | Done |
| 7 | After `apply`, the first 1–3 requests got no answer: Terraform finished as soon as the Nginx container was created, before Nginx was ready | `wait = true` and `wait_timeout = 60` on the Nginx container: `apply` returns only when Nginx is healthy | Done |
| 8 | Adding the HashiCorp apt key stopped at a `gpg` question, because the key file already existed | `gpg --dearmor --yes` | Done |
| 9 | Jenkins LTS images with JDK 17 are no longer released | Jenkins image `jenkins/jenkins:lts-jdk21`. The application itself is still built and run on JDK 17 inside its own image | Done |
| 10 | Jenkins runs in a container but must build images and run Terraform on the host Docker | Mounted `/var/run/docker.sock` and added the container to the host `docker` group by its ID (`DOCKER_GID`). The smoke test reaches the load balancer on the host as `host.docker.internal` | Done |
| 11 | Configuration as code recreates the job on every Jenkins restart, so polling and parameters set in the UI would be lost | Polling and parameters are written in `casc.yaml` together with the job | Done |
| 12 | The Jenkins admin password stayed the default from `.env.example` | Set a strong password in `.env` and recreated the container | Done |
| 13 | Every build recreated all application containers, even when the code had not changed. BuildKit adds build information with the build time to every image (provenance attestation), so the image ID is new each time and Terraform replaces the containers | `docker build --provenance=false`. The image ID now stays the same when the code does not change (builds #3 and #4: `c388dcc8`) | Done |
| 14 | A change of the algorithm or of the number of servers recreates the Nginx container, and the site does not answer for about 12 s (build #4) | — | Open |

## Next Steps

- Reload the Nginx config without recreating the container, so a change of the algorithm does not stop the site (Problem 14).
- Start builds by a GitHub webhook instead of polling every 5 minutes. Jenkins must be reachable from the internet for that.
- Add unit tests. The project has none yet; the "Build and test" stage runs them automatically once they are in `src/test`.

## Tools and Technologies Used

- **Docker Engine 29, Docker Compose, BuildKit:** image build with a cache, containers, health checks.
- **Nginx 1.28:** load balancer, `upstream` algorithms, sticky sessions, failover.
- **Apache Tomcat 9, OpenJDK 17, Maven 3.9:** build and run the application.
- **MySQL 8.4:** database.
- **Terraform 1.16, provider `kreuzwerker/docker` 4.6:** the whole stack as code.
- **Jenkins LTS (JDK 21), Configuration as Code, Job DSL, Pipeline:** CI/CD, set up from files.
- **Git, GitHub:** one branch per approach, reports in `main`.

## Comments and Conclusions

Each card built on the previous one: the Docker image was reused by the load balancer, the load-balanced stack was described in Terraform, and Jenkins runs that Terraform code. Most problems showed up only on the real machine — a busy port, a full disk, a network gateway that Docker adds by itself, a load balancer that answers a few seconds after Terraform finishes. The most useful lesson came from the CI/CD card: an image built from the same code got a new ID every time, and that silently restarted the whole application on every commit. It was visible only by reading the Terraform plan in the build log.

## Appendix and Resources

- Instructions: README of the branches `docker`, `docker-load-balancer`, `terraform`, `jenkins`
- Code: `Dockerfile`, `docker/`, `docker-compose.yml`, `lb/` (branch `docker-load-balancer`), `terraform/`, `Jenkinsfile`, `jenkins/` (branch `jenkins`)
- Reference project: <https://github.com/TroyanVova/GreenCity_Full>
- Nginx upstream module: <https://nginx.org/en/docs/http/ngx_http_upstream_module.html>
- Terraform Docker provider: <https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs>
- Jenkins Configuration as Code: <https://www.jenkins.io/projects/jcasc/>
- Docker build attestations: <https://docs.docker.com/build/metadata/attestations/>
