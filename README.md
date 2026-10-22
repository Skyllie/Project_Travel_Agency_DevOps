# TravelAgency — Monitoring and Capacity Planning

This branch adds **monitoring** of the application and of the infrastructure with **Prometheus** and **Grafana**, alert rules, a **load test** with k6 and a script that turns the measurements into a **capacity plan**.
It covers two cards: "Set up monitoring tools for application performance and infrastructure health" and "Monitor resource usage and plan for scalability".
It builds on the `code-inspection` branch: the same pipeline; the application image now exports its metrics.

```
 Windows browser ──► Grafana  http://<Ubuntu IP>:3000   (login; dashboards from Git)
                        │
                        ▼
                     Prometheus  127.0.0.1:9090   scrapes every 15 s, keeps 15 days, evaluates the alert rules
                        │
   ┌──────────────┬─────┴──────────┬───────────────────┬──────────────────┬──────────────────────────────┐
 node-exporter   cAdvisor        JMX exporter          nginx-exporter     mysqld-exporter    blackbox-exporter
 the Ubuntu host every container  inside app1…appN     travelagency-tf-lb travelagency-tf-db  HTTP checks: the site, each
 CPU, RAM, disk  CPU, RAM, net    Tomcat requests,      /nginx-status      connections,       server, Jenkins, Nexus,
                                  errors, threads, JVM                     queries, InnoDB    SonarQube
```

| File | What it is |
| --- | --- |
| `monitoring/docker-compose.yml` | Prometheus 3.15, Grafana 12.4, node-exporter, cAdvisor, mysqld-, nginx-, blackbox-exporter |
| `monitoring/setup.py` | Creates the MySQL user of the exporter, starts the stack, prints the state of every target |
| `monitoring/prometheus/prometheus.yml` | What is scraped; the application servers are found by DNS (alias `app`) |
| `monitoring/prometheus/alerts.yml` | 15 alert rules: availability, application, host |
| `monitoring/prometheus/capacity.yml` | Recording rules: requests per second, response time, CPU per request, … |
| `monitoring/prometheus/tests.yml` | Unit tests of the rules (`promtool test rules`) |
| `monitoring/grafana/` | Data source and two dashboards, provisioned from files |
| `monitoring/loadtest.py`, `monitoring/loadtest/loadtest.js` | Load test with k6 and the capacity report |
| `Dockerfile`, `docker/jmx-exporter.yml` | The Prometheus JMX exporter as a Java agent in Tomcat (port 9404) |
| `terraform/main.tf`, `terraform/templates/nginx.conf.tftpl` | Alias `app` for the servers; `/nginx-status` only for the Docker network; `server_tokens off` |

## What Is Measured

| Layer | Source | Examples |
| --- | --- | --- |
| What users get | blackbox-exporter | site up/down, response time through Nginx, each server past Nginx |
| Application | JMX exporter in every Tomcat | requests and errors per second, processing time, busy threads, sessions, heap, GC, CPU |
| Load balancer | nginx-exporter | requests per second, active/reading/writing/waiting connections |
| Database | mysqld-exporter | connections vs `max_connections`, queries and slow queries per second, InnoDB buffer pool hit ratio |
| Containers | cAdvisor | CPU, memory, network of every container (application, Jenkins, Nexus, SonarQube, …) |
| Host | node-exporter | CPU, memory, swap, load, root disk and its 24-hour forecast, disk I/O |
| CI/CD tools | blackbox-exporter | Jenkins, Nexus, SonarQube answer or not |

## 1. Before You Start

- The `code-inspection` branch works (README of that branch).
- Memory: the monitoring needs about 0.7 GB more. With 8 GB of RAM, keep the swap of the `code-inspection` README and deploy with `APP_REPLICAS=2`; 12 GB is comfortable.
- The first build of this branch recreates the application servers once: the image has the JMX exporter now, and the servers get the network alias `app`.

## 2. Deploy This Branch

```bash
cd ~/travel-jenkins
git fetch origin
git switch monitoring
cd jenkins
nano .env                       # REPO_BRANCH=monitoring
docker compose up -d            # Jenkins re-reads the branch from its configuration
```

**travelagency → Build with Parameters → Build.** After the build, every application server answers with its metrics on port 9404 inside the Docker network:

```bash
docker exec travelagency-tf-lb wget -qO- http://travelagency-tf-app1:9404/metrics | grep tomcat_requestcount
```

## 3. Start the Monitoring

```bash
cd ~/travel-jenkins/monitoring
cp .env.example .env
nano .env                       # GRAFANA_ADMIN_PASSWORD, MYSQL_EXPORTER_PASSWORD
python3 setup.py
```

What `setup.py` prints at the end:

```
Targets of Prometheus:
  up       blackbox-app    app1
  up       blackbox-app    app2
  up       blackbox-site   http://travelagency-tf-lb/form-login
  up       blackbox-tools  http://host.docker.internal:8081/login
  ...
  up       tomcat          app1
  up       tomcat          app2
All targets are up.
```

Open Grafana at `http://<Ubuntu IP>:3000/`, sign in as `admin` with `GRAFANA_ADMIN_PASSWORD`, then **Dashboards → TravelAgency**.

Prometheus has no login, so it listens only on Ubuntu itself: `http://localhost:9090/` in the Ubuntu browser, or from Windows through SSH: `ssh -L 9090:localhost:9090 <user>@<Ubuntu IP>`, then `http://localhost:9090/`.

## 4. Dashboards

**TravelAgency — Infrastructure**
- Health: the site, how many application servers answer, MySQL, Jenkins/Nexus/SonarQube, and the alerts that fire now.
- Ubuntu host: CPU, memory and swap, load average against the number of cores, root disk with a 24-hour forecast, disk I/O.
- Containers: CPU, memory and network of every container, and "Memory now, by container": where the RAM of the VM goes.

**TravelAgency — Application**
- What users get: site up, response time, requests per second, error share, number of servers, and the alerts that fire now.
- Application servers: requests per second by server (how Nginx spreads them; compare the LB algorithms), errors, heap, CPU, busy threads, sessions, GC time.
- Load balancer and database: Nginx connections; MySQL connections, queries, slow queries, buffer pool hit ratio.
- Capacity: CPU per request, host CPU and memory, busy threads, and "load and CPU" for the load test.

The dashboards are files in Git (`monitoring/grafana/dashboards`): Grafana loads them at start and does not let the UI change them, so every installation shows the same.

## 5. Alerts

| Alert | When | Severity |
| --- | --- | --- |
| SiteDown | the site does not answer through Nginx for 1 min | critical |
| MySQLDown | the exporter cannot reach MySQL for 1 min | critical |
| AppServerDown | one application server runs but does not answer for 2 min | warning |
| AppServerGone | a server seen in the last 30 min is not found any more for 2 min (stopped, deleted, or scaled down on purpose) | warning |
| CiToolDown | Jenkins, Nexus or SonarQube does not answer for 5 min | warning |
| ScrapeTargetDown | Prometheus gets no metrics from a target for 3 min | warning |
| HighErrorRate | more than 5 % of the requests fail for 5 min | warning |
| SlowResponses | average processing time above 1 s for 5 min | warning |
| JvmHeapAlmostFull | heap of a server above 90 % for 5 min | warning |
| TomcatThreadsBusy | more than 80 % of the request threads busy for 5 min | warning |
| MySQLTooManyConnections | more than 80 % of `max_connections` in use for 5 min | warning |
| HostHighCpu, HostLowMemory, HostDiskAlmostFull | host CPU > 85 %, free memory < 10 %, disk > 85 % | warning |
| HostDiskFullIn24h | at the current rate the root disk is full within 24 h | warning |

Firing alerts are in the table "Firing alerts" on both dashboards and at `http://localhost:9090/alerts`.
The rules have unit tests with made-up series:

```bash
cd ~/travel-jenkins/monitoring
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool prom/prometheus:v3.15.0 test rules /etc/prometheus/tests.yml
```

Try one for real: `docker stop travelagency-tf-app2` → after about 2 minutes **AppServerGone** for app2 fires (a stopped container leaves the DNS name `app`, so its checks disappear rather than fail), Nginx sends everyone to the other servers, and the site stays up. `docker start travelagency-tf-app2` brings it back and the alert clears.

## 6. Load Test and Capacity Plan

`loadtest.py` runs k6 against the load balancer with several numbers of virtual users (VUs), two minutes each, and after each run asks Prometheus what the servers used. The service level it checks: **95 % of requests under 1 s and under 1 % errors**.

```bash
cd ~/travel-jenkins/monitoring
python3 loadtest.py                                   # 10, 25, 50 VUs: login page only
python3 loadtest.py --vus 10,50,100 --duration 3m     # heavier
python3 loadtest.py --user <login>                    # also signs in (the start page reads the database)
```

For `--user`, create a user on the sign-up page (`http://<Ubuntu IP>/create`, the link "Create account" on the login page); the script asks for the password.

The script prints a table and saves it, with an estimate, to `monitoring/results/capacity-<date>.md`:

| Column | Meaning |
| --- | --- |
| Req/s, p95, Avg, Errors | what k6 measured |
| CPU of servers | CPU cores all Tomcats used during the run |
| CPU per request | CPU of the servers / requests: the cost of one request |
| Host CPU, Host memory | the whole VM, at most during the run |
| Memory of one server | the largest Tomcat container |
| Busy threads, DB connections | the largest values during the run |
| Meets SLO | p95 < 1 s and errors < 1 % |

The estimate under the table:
- **CPU:** requests per second the VM can serve with the servers at 70 % of the CPU that the other services leave free. All servers share the same VM, so more servers do not add CPU here.
- **Load:** the highest measured load that still met the service level.
- **Memory:** how many more servers fit into the free memory.

**Scaling experiment.**
1. Deploy with `APP_REPLICAS` = 1, run `python3 loadtest.py`.
2. Do the same with 2 and 3 servers.
3. Compare the tables: requests per second at the same p95, CPU per request, memory per server.

Prometheus finds the new servers by themselves (DNS alias `app`), so the dashboards show them without any change. The results go into the weekly report as the capacity plan.

## 7. How It Is Built

- **Discovery instead of a list.** Terraform gives every application server the network alias `app`; Prometheus asks the Docker DNS for `app` every 15 s. Scaling with `APP_REPLICAS` needs no change in the monitoring. The address `.1N` is turned into the name `appN` for the dashboards.
- **Metrics from inside the JVM.** The Prometheus JMX exporter runs as a Java agent in every Tomcat (`CATALINA_OPTS`, because Terraform sets `JAVA_OPTS` per server) and reads Tomcat's own MBeans: requests, errors, processing time, threads, sessions, and the JVM. The agent jar is checked against its SHA-256 in the Dockerfile.
- **Two views of the application.** From inside (JMX: what Tomcat did) and from outside (blackbox: what a user gets, through Nginx and to each server directly).
- **Least privilege.** The MySQL user `exporter` gets `PROCESS`, `REPLICATION CLIENT` and `performance_schema`, only from the Docker network, at most 3 connections: statistics, no application data. `setup.py` creates it with the root password that is already in the MySQL container, so it is never typed or put on a command line.
- **Closed doors.** Prometheus listens on `127.0.0.1` only; Grafana needs a login, no sign-up, no anonymous access. `/nginx-status` now answers only Nginx itself and the Docker network (it was open to everyone), and Nginx no longer shows its version (`server_tokens off`).
- **Host access is read-only.** node-exporter and cAdvisor see the host through read-only mounts and run unprivileged. cAdvisor still reaches the Docker socket through `/var/run`: it needs the container names, and that access is the same as root on the host, a known trade-off of container monitoring.
- **Fixed addresses.** The monitoring containers on the Terraform network take `.40`–`.44`, away from the addresses Terraform gives (`.10`–`.20`), so a later `terraform apply` never finds its address taken.
- **Recording rules.** Requests per second, response time, CPU per request and the host ratios are computed by Prometheus every 15 s (`capacity.yml`); the dashboards, the alerts and `loadtest.py` use the same numbers.
- **Configuration as code, tested.** Everything is in files; the rules have unit tests; Grafana dashboards are provisioned and read-only.
- **Bounded storage.** Prometheus keeps 15 days and at most 2 GB.

## 8. Check

| What | How | Expected |
| --- | --- | --- |
| Metrics of the application | the `docker exec … wget` line of section 2 | `tomcat_requestcount_total{…}` |
| All targets up | `python3 setup.py` again, or `http://localhost:9090/targets` | every target `up` |
| Dashboards | Grafana → Dashboards → TravelAgency | two dashboards with data |
| Discovery | deploy with `APP_REPLICAS=3`, then 2 | the dashboards show 3, then 2 servers |
| An alert | `docker stop travelagency-tf-app2`, wait 2–3 min | AppServerGone for app2 on the dashboards; the site stays up |
| Rule tests | the `promtool test rules` line of section 5 | `SUCCESS` |
| `/nginx-status` closed | `curl -s -o /dev/null -w '%{http_code}\n' http://<Ubuntu IP>/nginx-status` from Windows (Git Bash) | `403` |
| Load test | `python3 loadtest.py` | table and `results/capacity-<date>.md` |

## 9. If Something Goes Wrong

| Problem | What to do |
| --- | --- |
| `setup.py`: `the network travelagency-tf-net does not exist` | Deploy the stack first: a Jenkins build of this branch |
| `docker compose up`: `Address already in use` | Another container took `.40`–`.44` on `travelagency-tf-net`: `docker network inspect travelagency-tf-net`, free the address |
| Target `tomcat` missing or `down` | The servers run an image without the agent: build this branch in Jenkins; `docker exec travelagency-tf-app1 sh -c 'echo $CATALINA_OPTS'` must show `-javaagent` |
| Target `mysql` `down`, `Access denied` | `MYSQL_EXPORTER_PASSWORD` changed: `python3 setup.py` updates the user; then `docker compose up -d mysqld-exporter` |
| cAdvisor shows no container names | `docker compose logs cadvisor`; it needs `/var/run` (Docker and containerd sockets) |
| Grafana does not take the new admin password | `GRAFANA_ADMIN_PASSWORD` is used only on the first start; change it in Grafana (profile) or `docker compose down -v` to start over |
| `terraform apply` in Jenkins: `network … has active endpoints` | Only when Terraform has to recreate the network: `docker compose down` in `monitoring/`, build again, then `python3 setup.py` |
| `loadtest.py`: many failed checks with `--user` | Wrong user name or password, or the user cannot sign in |
