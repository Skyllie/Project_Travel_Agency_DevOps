# TravelAgency — CI/CD with Jenkins

This branch adds a **Jenkins** pipeline that builds, tests and deploys TravelAgency on every new commit.
It covers the card "Implement a Continuous Integration/Continuous Delivery".
It builds on the `terraform` branch: Jenkins builds the image and deploys it with the same Terraform code.

```
git push (branch jenkins)
   │  Jenkins checks the branch every 5 minutes (pollSCM)
   ▼
Jenkins  (container, http://<Ubuntu IP>:8081, configured as code)
   1. Version          image tag = short commit id, e.g. travelagency:3f2a9c1
   2. Build and test   docker build: Maven compiles, runs unit tests (none yet), packs the WAR
   3. Terraform check  terraform fmt -check, init, validate
   4. Deploy           terraform plan + apply with the new tag → MySQL, N Tomcats, Nginx
   5. Smoke test       HTTP 200 through the load balancer, which servers answered
   │
   ▼  through /var/run/docker.sock
Docker on Ubuntu:  travelagency-tf-db, -app1…N, -lb  →  http://<Ubuntu IP>/
```

| File | What it is |
| --- | --- |
| `Jenkinsfile` | The pipeline: 5 stages, parameters, poll trigger, image cleanup |
| `jenkins/Dockerfile` | Jenkins LTS (JDK 21) + Docker CLI + Terraform + plugins |
| `jenkins/plugins.txt` | Plugins installed at build time |
| `jenkins/casc.yaml` | Configuration as code: admin user, credentials, the `travelagency` job |
| `jenkins/docker-compose.yml` | Runs Jenkins on port 8081 with access to the host Docker |
| `jenkins/.env.example` | Admin password, database passwords, repository, Docker group id |

Nothing is configured by hand in the Jenkins UI: after `docker compose up` the job, the credentials and the admin user already exist.

## 1. Before You Start

- Docker on Ubuntu (README of the `docker` branch). Terraform on Ubuntu is not needed: it is inside the Jenkins image.
- Stop the earlier stacks, they use the same ports and names:
  - `docker compose down` in the folders of the `docker` and `docker-load-balancer` branches;
  - `terraform destroy` in the folder of the `terraform` branch, if you created the stack by hand. From now on Jenkins owns it.
- RAM: Jenkins needs about 1 GB on top of the three Tomcats and MySQL. Give the Ubuntu VM 6 GB (shut down `ol-app` and `ol-db` with `vagrant halt`).

## 2. Start Jenkins

```bash
git clone -b jenkins https://github.com/Skyllie/Project_Travel_Agency_DevOps.git ~/travel-jenkins
cd ~/travel-jenkins/jenkins
cp .env.example .env
nano .env                                                  # JENKINS_ADMIN_PASSWORD and the two DB passwords
echo "DOCKER_GID=$(getent group docker | cut -d: -f3)" >> .env
docker compose up -d --build                               # 5–10 minutes the first time: plugins download
docker compose logs -f jenkins                             # wait for "Jenkins is fully up and running", Ctrl+C
```

Open `http://<Ubuntu IP>:8081/` on Windows and log in as `admin` with `JENKINS_ADMIN_PASSWORD`.
The job **travelagency** is already there.

## 3. First Run

1. **travelagency → Build with Parameters → Build** (the defaults: `round_robin`, 3 servers, sticky sessions on).
2. Watch the stages in **Pipeline Overview** or in **Console Output**. The first run takes 5–10 minutes (Maven dependencies, base images, Terraform provider).
3. At the end of the log: the Terraform outputs and the smoke test, for example:
   ```
   HTTP 200 from http://host.docker.internal:80/form-login
   15 new visitors, algorithm round_robin:
         5 app1
         5 app2
         5 app3
   ```
4. Open `http://<Ubuntu IP>/` — the site, deployed by Jenkins.

## 4. Continuous Delivery

Every commit to the `jenkins` branch is deployed automatically:

```bash
# in a clone of the jenkins branch
git commit --allow-empty -m "Trigger the pipeline"     # or any real change
git push
```

Within 5 minutes Jenkins notices the commit (**Polling Log** of the job), builds the image `travelagency:<new commit id>`, and Terraform recreates the application servers with it.

**Rollback** goes the same way: `git revert <bad commit>` and `git push` — the pipeline builds and deploys the previous code. Do not run `terraform apply` by hand for this stack: Jenkins keeps its own state in `/var/jenkins_home/tfstate/`.

GitHub cannot call Jenkins on a home PC (no public address), so Jenkins asks GitHub instead (polling). With a public Jenkins, a GitHub webhook would start the build at once.

## 5. Parameters

**Build with Parameters** changes the deployment without changing code:

| Parameter | Values | What changes |
| --- | --- | --- |
| `LB_ALGORITHM` | `round_robin`, `weighted`, `least_conn`, `ip_hash`, `hash`, `random`, `backup` | Nginx config; only the `lb` container is recreated |
| `APP_REPLICAS` | 1–5 | Number of Tomcats; Terraform adds or removes servers |
| `LB_STICKY` | checkbox (on by default) | Sticky sessions by `jvmRoute` |

The smoke test prints how 15 new visitors were spread; with `round_robin` it fails if not all servers answered.

## 6. How It Is Built

- **Jenkins as code.** `jenkins/casc.yaml` (Configuration as Code plugin) creates the admin user, two secret-text credentials and the pipeline job (Job DSL). Secrets come from `jenkins/.env` through environment variables, so the Git repository has none.
- **Docker from Jenkins.** The host socket `/var/run/docker.sock` is mounted into the container, and the `jenkins` user is added to the host `docker` group (`DOCKER_GID`). `docker build` and Terraform inside Jenkins work with the host Docker directly. This gives Jenkins full control of the host Docker, so the Jenkins UI must stay protected by a password.
- **Tests in the build.** The Dockerfile build stage runs `mvn package`. The project has no unit tests yet; as soon as tests are added to `src/test`, they run there, and a failing test stops the image build, so nothing is deployed. Until then the smoke test after the deploy is the check.
- **Image tag = commit.** Each build has its own tag (`git rev-parse --short=7 HEAD`), so the running version is always known (`terraform output app_image`, build description).
- **Terraform state** is in the `jenkins_home` volume (`/var/jenkins_home/tfstate/`), so each build changes only what is different.
- **Secrets in the log.** The DB passwords are passed with `withCredentials` as `TF_VAR_…` variables: Jenkins masks them as `****`, and Terraform shows them as `(sensitive value)`.
- **One build at a time** (`disableConcurrentBuilds`), 30-minute timeout, the last 15 builds kept.

## 7. Check

| What | Where | Expected |
| --- | --- | --- |
| Jenkins is up | `docker compose ps` in `jenkins/` | `Up` |
| Configured as code | Manage Jenkins → Configuration as Code | `casc.yaml` loaded, no errors |
| The job and credentials exist | Dashboard; Manage Jenkins → Credentials | `travelagency`; `travel-db-password`, `travel-db-root-password` |
| A build passes | travelagency → Build Now | all five stages green |
| The stack is running | `docker ps --filter name=travelagency-tf` | db, app1–3, lb: healthy |
| CD works | push a commit to `jenkins` | a new build starts within 5 minutes, a new image tag in `docker ps` |
| Docker works from Jenkins | `docker compose exec jenkins docker ps` | the host containers |

## 8. If Something Goes Wrong

| Problem | What to do |
| --- | --- |
| `permission denied ... /var/run/docker.sock` in the build | `DOCKER_GID` in `jenkins/.env` is wrong or missing: `getent group docker`, fix it, `docker compose up -d` |
| `Conflict. The container name "/travelagency-tf-db" is already in use` | The stack was created by hand: `terraform destroy` in the `terraform` branch folder (or `docker rm -f` the `travelagency-tf-*` containers), then build again |
| `terraform fmt -check` fails | Run `terraform fmt` in `terraform/`, commit the change |
| Smoke test: `HTTP 000` | Port 80 is used by something else, or the `lb` container failed: `docker logs travelagency-tf-lb` |
| `Bind for 0.0.0.0:80 failed: port is already allocated` | Another stack is running: `docker compose down` in the Compose branches |
| The job is missing | `docker compose logs jenkins \| grep -i casc` — an error in `casc.yaml` or a missing variable in `.env` |
| New commits do not start builds | **Polling Log** of the job: Jenkins must be able to reach GitHub; the trigger is set in `casc.yaml` and in the Jenkinsfile |
