# TravelAgency — Artifact Management with Nexus

This branch keeps every build of TravelAgency in a **Nexus Repository**: the WAR in a Maven repository and the Docker image in a Docker registry.
Jenkins deploys only what is stored in Nexus, and any stored version can be deployed again (rollback).
It covers the card "Artifact Management".
It builds on the `jenkins` branch: the same pipeline, with three new stages.

```
git push (branch artifact-management)
   │  Jenkins checks the branch every 5 minutes (pollSCM)
   ▼
Jenkins  (http://<Ubuntu IP>:8081)
   1. Version            tag = short commit id, e.g. 3f2a9c1
   2. Build and test     docker build: Maven compiles, runs unit tests, packs the WAR into the image
   3. Publish to Nexus   WAR   → travelagency-maven   org.project:TravelAgency:1.0-3f2a9c1
                         image → travelagency-docker  localhost:8092/travelagency:3f2a9c1
   4. Pull from Nexus    docker pull of that image: the deploy uses the copy stored in Nexus
   5. Terraform check    terraform fmt -check, init, validate
   6. Deploy             terraform apply: MySQL, N Tomcats with the image from Nexus, Nginx
   7. Smoke test         HTTP 200 through the load balancer
   8. Nexus retention    keep the 5 newest versions in each repository
   │
   ▼
Nexus Repository Community Edition  (container, http://<Ubuntu IP>:8091)
   travelagency-maven    WARs, one release per commit, never overwritten
   travelagency-docker   images, one tag per commit, never overwritten; registry on 127.0.0.1:8092
```

| File | What it is |
| --- | --- |
| `nexus/docker-compose.yml` | Nexus 3.96.4: UI and REST API on port 8091, the Docker registry on `127.0.0.1:8092` |
| `nexus/.env.example` | The admin password, the user Jenkins publishes with, accepting the EULA |
| `nexus/setup.py` | Configures Nexus through its REST API: repositories, role, user, security. Safe to run again |
| `ci/nexus.sh` | The Nexus steps of the pipeline: `publish`, `pull`, `retention` |
| `Jenkinsfile` | 8 stages; new parameter `ROLLBACK_TO` |
| `jenkins/casc.yaml` | New credential `nexus-ci` and the parameter `ROLLBACK_TO` |
| `jenkins/Dockerfile` | Adds `jq` for reading the Nexus API answers |

| Repository | Format | Stores | Version | Write policy |
| --- | --- | --- | --- | --- |
| `travelagency-maven` | Maven 2, hosted, release | WAR + generated POM + checksums | `1.0-<commit>` | Allow once: a version cannot be overwritten |
| `travelagency-docker` | Docker, hosted | Application image | `<commit>` | Allow once: a tag always points to the same image |

## 1. Before You Start

- Jenkins from the `jenkins` branch is running (`~/travel-jenkins`, README of that branch). Section 3 switches it to this branch.
- **RAM: give the Ubuntu VM 8 GB.** Shut Ubuntu down, then in VMware: VM → Settings → Memory → 8192 MB, and start it again. Roughly: Nexus 1.5 GB, Jenkins 1 GB, three Tomcats 1.5 GB, MySQL 0.5 GB, Ubuntu itself 1 GB.
- Disk: about 2 GB free for Nexus. A new version adds only the changed image layer with the WAR; the base layers are stored once.
- Python 3 is already on Ubuntu (`python3 --version`); `setup.py` uses only its standard library.

## 2. Start Nexus

```bash
cd ~/travel-jenkins
git fetch origin
git switch artifact-management
cd nexus
cp .env.example .env
nano .env                       # NEXUS_ADMIN_PASSWORD, NEXUS_CI_PASSWORD, NEXUS_ACCEPT_EULA (see below)
docker compose up -d
docker compose ps               # wait for (healthy): 2–3 minutes the first time
python3 setup.py
```

Nexus Community Edition is free, under the Sonatype End User License Agreement (<https://links.sonatype.com/products/nxrm/ce-eula>).
Read it and write `NEXUS_ACCEPT_EULA=yes` into `.env` to accept it. Without that, `setup.py` sets the admin password and stops with the text of the agreement.

What `setup.py` prints:

```
Waiting for Nexus at http://localhost:8091  up
admin password: set from .env (Nexus deleted the generated one)
EULA: accepted (NEXUS_ACCEPT_EULA=yes)
realm Docker Bearer Token: enabled
anonymous access: switched off
repository travelagency-maven: created
repository travelagency-docker: created
role travelagency-ci: created
user jenkins: created with the role travelagency-ci
check: jenkins can read travelagency-maven and travelagency-docker
check: Docker registry http://localhost:8092 accepts jenkins
```

Open `http://<Ubuntu IP>:8091/` on Windows and sign in as `admin` with `NEXUS_ADMIN_PASSWORD`.
If Nexus shows its welcome wizard, click through it: `setup.py` has already done its steps.

## 3. Switch Jenkins to This Branch

```bash
cd ~/travel-jenkins/jenkins
nano .env
#   REPO_BRANCH=artifact-management
#   NEXUS_CI_USER=jenkins
#   NEXUS_CI_PASSWORD=<the same as in nexus/.env>
docker compose up -d --build    # the image gets jq; JCasC adds the credential nexus-ci and ROLLBACK_TO
```

The Terraform state stays in the `jenkins_home` volume, so Jenkins takes over the running stack and recreates nothing that has not changed.

Installing Jenkins for the first time: follow sections 1–2 of the `jenkins` branch README with `git clone -b artifact-management …` and fill in the `NEXUS_CI_*` lines of `jenkins/.env` as well.

## 4. First Build

**travelagency → Build with Parameters → Build.** In the log:

```
WAR uploaded: http://host.docker.internal:8091/repository/travelagency-maven/org/project/TravelAgency/1.0-3f2a9c1/TravelAgency-1.0-3f2a9c1.war
Image pushed: localhost:8092/travelagency:3f2a9c1
...
Deploying the image from Nexus: localhost:8092/travelagency@sha256:…
...
travelagency-maven: kept the 5 newest versions of TravelAgency and the deployed one
travelagency-docker: kept the 5 newest versions of travelagency and the deployed one
```

In Nexus, **Browse**:
- `travelagency-maven` → `org/project/TravelAgency/1.0-3f2a9c1/`: the `.war`, the `.pom`, and their `.md5`, `.sha1`, `.sha256`, `.sha512`;
- `travelagency-docker` → `travelagency` → `3f2a9c1`.

Run the build once more without a new commit: the log says `… is already in travelagency-maven: a release is never overwritten`, and the same for the image. One commit gives exactly one WAR and one image.

## 5. Rollback from Nexus

1. Find an older version: Nexus → Browse → `travelagency-docker` → `travelagency`, or the build descriptions in Jenkins (`3f2a9c1, round_robin, 3 servers`).
2. **Build with Parameters**, `ROLLBACK_TO` = that 7-character commit id → **Build**.
3. Build and test, Publish and Retention are skipped (grey). Pull from Nexus downloads that image, Terraform puts it on the application servers, the smoke test checks the site. The build description starts with `rollback to`.

Back to the newest version: **Build with Parameters** with an empty `ROLLBACK_TO`, or push a commit.
A rollback changes only the application image; the infrastructure comes from the Terraform code of the current commit.

## 6. Artifacts Outside Jenkins

Download a WAR on Ubuntu (curl asks for the password of `jenkins`):

```bash
curl -u jenkins -fO http://localhost:8091/repository/travelagency-maven/org/project/TravelAgency/1.0-3f2a9c1/TravelAgency-1.0-3f2a9c1.war
```

Pull an image on Ubuntu:

```bash
docker login localhost:8092 -u jenkins
docker pull localhost:8092/travelagency:3f2a9c1
docker logout localhost:8092
```

The registry listens only on `127.0.0.1` of Ubuntu, because it speaks plain HTTP. The web UI and the Maven repository are on port 8091 for the whole network.

## 7. How It Is Built

- **Nexus as code.** `setup.py` configures Nexus through the REST API from `nexus/.env`; nothing is set up by hand. Each step reads the current state first, so a second run only reports `already set` / `checked`.
- **Write once.** Both repositories use the write policy "Allow once": a version, once stored, never changes. `ci/nexus.sh publish` checks first and skips what is already there. The Maven repository has the release policy, so it does not accept `-SNAPSHOT` versions.
- **Version = commit.** The WAR is `1.0-<commit>` (the release part of the version in `pom.xml` plus the commit id), the image tag is `<commit>`. The same id is in the build description and in `terraform output app_image`, so the running version leads straight to its commit.
- **One build, two artifacts.** The WAR uploaded to Nexus is copied out of the built image (`docker create` + `docker cp`), so it is the same file Tomcat runs.
- **Deploy from the repository.** The stage Pull from Nexus pulls `localhost:8092/travelagency:<commit>`, and Terraform runs that image. A version missing from Nexus cannot be deployed.
- **Least privilege.** Jenkins signs in as `jenkins` with the role `travelagency-ci`: the two TravelAgency repositories and the upload API, nothing else. The admin password is only in `nexus/.env`. Anonymous access is off, and the registry asks for a login on every pull and push.
- **Secrets.** The Jenkins credential `nexus-ci` comes from `jenkins/.env` through JCasC. `ci/nexus.sh` gives the password to curl in a temporary file and to `docker login` on stdin, with a temporary `DOCKER_CONFIG` deleted after the step: the password is not in the process list, not in the log (Jenkins masks it) and not left in `~/.docker` of Jenkins.
- **Registry without TLS on localhost.** Docker trusts a registry on `localhost` over plain HTTP without any `insecure-registries` setting, so the registry is published only on `127.0.0.1`.
- **Retention.** After a successful smoke test, `ci/nexus.sh retention` keeps the `NEXUS_KEEP` (5) newest versions in each repository and always the deployed one. If it fails, the stage turns yellow (UNSTABLE) and the build stays green. Deleted components free disk space after two Nexus tasks run: gear icon (administration) → System → Tasks → Create task → "Docker - Delete unused manifests and images", then "Admin - Compact blob store" (for example, weekly).
- **Memory.** The Nexus JVM is limited to 1 GB of heap (`INSTALL4J_ADD_VM_PARAMS`); by default it would take a quarter of the VM memory.
- **Community Edition.** Free to use; Sonatype sets usage limits for it (number of components, requests per day) far above what this project needs.

## 8. Check

| What | How | Expected |
| --- | --- | --- |
| Nexus is up | `docker compose ps` in `nexus/` | `(healthy)` |
| Configuration is code | `python3 setup.py` again | only `already set` / `checked`, nothing created |
| No anonymous access | `curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:8091/service/rest/v1/components?repository=travelagency-maven"` | `401` or `403`, not `200` |
| The registry needs a login | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8092/v2/` | `401` |
| A build publishes | Console Output of a build after a new commit | `WAR uploaded`, `Image pushed` |
| Write once | Build again without a new commit | `already in …: … never overwritten` |
| Deploy from Nexus | Stage Pull from Nexus | `Deploying the image from Nexus: localhost:8092/travelagency@sha256:…` |
| Rollback | `ROLLBACK_TO` = an older commit | the site works; `app_image = "localhost:8092/travelagency:<older commit>"` in the Terraform output |
| Retention | 6 or more builds of new commits | 5 versions in each repository (plus the deployed one, if it is older) |

## 9. If Something Goes Wrong

| Problem | What to do |
| --- | --- |
| `setup.py`: `Nexus did not start in 10 minutes` | `docker compose logs nexus` in `nexus/`; often not enough memory: `free -h`, see section 1 |
| `setup.py` stops with the EULA text | Read it, write `NEXUS_ACCEPT_EULA=yes` into `nexus/.env`, run `setup.py` again |
| `setup.py`: `the generated password … is gone` | The admin password was changed in the UI: write the current one into `NEXUS_ADMIN_PASSWORD` |
| Publish: `Nexus refused jenkins (HTTP 401)` | `NEXUS_CI_PASSWORD` differs between `jenkins/.env` and `nexus/.env`: make them equal, run `python3 setup.py` and `docker compose up -d` in `jenkins/` |
| Publish: `Nexus answered HTTP 000` | Nexus is down or unreachable from Jenkins: `docker compose ps` in `nexus/`, `curl -I http://localhost:8091/` on Ubuntu |
| `docker push`: `server gave HTTP response to HTTPS client` | The registry name must be `localhost:8092` (`REGISTRY` in the Jenkinsfile): Docker allows plain HTTP only for localhost |
| `docker push`: `denied` or `unauthorized` | The role of `jenkins` is wrong: `python3 setup.py` puts it back |
| Rollback: `manifest unknown` | That version is not in Nexus (deleted by retention or never built): Browse → `travelagency-docker` |
| The disk fills up | Create the two cleanup tasks from section 7 and run them |
