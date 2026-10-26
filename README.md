# TravelAgency — Continuous Code Inspection with SonarQube

This branch adds **continuous code inspection**: every commit is analysed by **SonarQube**, and its quality gate decides whether the build goes on.
The project gets its first unit tests (JUnit 5, Mockito) and test coverage (JaCoCo), which SonarQube shows next to bugs, vulnerabilities, security hotspots, code smells and duplications.
It covers the card "Implement CCI (Continuous Code Inspection)".
It builds on the `security-scanning` branch: the same pipeline (scans, Nexus, rollback), with one new stage.

```
git push (branch code-inspection)
   │  Jenkins checks the branch every 5 minutes (pollSCM)
   ▼
Jenkins  (http://<Ubuntu IP>:8081)
    1. Version
    2. Build and test                 docker build: Maven compiles and runs the unit tests, WAR, image
    3. Code inspection: SonarQube     mvn verify (tests + JaCoCo coverage) → analysis → wait for the quality gate
    4. Dependencies: Snyk
    5. Image: Trivy
    6. Image: Grype
    7. Security gate
    8. Publish to Nexus … 13. Nexus retention   (as before)
   │
   ▼
SonarQube Community Build + PostgreSQL  (containers, http://<Ubuntu IP>:9000)
   project travelagency: issues, coverage, duplications, history of every analysis
```

| File | What it is |
| --- | --- |
| `sonarqube/docker-compose.yml` | SonarQube Community Build 26.9 and PostgreSQL 17, UI on port 9000 |
| `sonarqube/.env.example` | Database password and the admin password |
| `sonarqube/setup.py` | Configures SonarQube through its Web API: admin password, login required, private project, token for Jenkins. Safe to run again |
| `Jenkinsfile` | New stage Code inspection: SonarQube; test results on the build page |
| `pom.xml` | JUnit 5, Mockito, Surefire, JaCoCo; SonarQube project key |
| `src/test/java/…` | First unit tests: `CountryServiceImpl`, `BookingServiceImpl`, `StringToLocalDateConverter` |
| `src/test/resources/mockito-extensions/…` | Mockito makes mocks as subclasses, without attaching an agent to the JVM |
| `jenkins/casc.yaml`, `jenkins/plugins.txt` | Credential `sonar-token`; plugin JUnit |

## What SonarQube Checks

SonarQube reads the Java code, the compiled classes and the coverage report, and finds:

| Kind | Example |
| --- | --- |
| Bugs (reliability) | code that is wrong or will break at run time |
| Vulnerabilities (security) | code an attacker can use |
| Security hotspots | security-sensitive code a person has to review, e.g. CSRF protection turned off |
| Code smells (maintainability) | code that is hard to change: duplication, complexity, unused code |
| Coverage | which lines the unit tests run (JaCoCo) |
| Duplications | copied blocks of code |

**Quality gate.** The project uses SonarQube's built-in gate "Sonar way". It looks only at **new code** ("Clean as You Code"): the old code is reported, but it does not block. A build fails when the new code has:
- any new issue,
- test coverage below 80 %,
- more than 3 % duplicated lines,
- a security hotspot nobody has reviewed.

The first analysis has no new code, so it sets the baseline; every later commit is measured against it.

## 1. Before You Start

- The `security-scanning` branch works (README of that branch).
- **Memory.** SonarQube runs three Java processes (web, compute engine, Elasticsearch): about 2 GB. Together with Jenkins, Nexus, MySQL and three Tomcats, 8 GB of RAM is tight. Better: give the VM 10–12 GB. With 8 GB: check that Ubuntu has swap (`swapon --show`; if empty, the commands below add 4 GB) and deploy with `APP_REPLICAS=2`.
  ```bash
  sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  ```
- **Kernel setting for Elasticsearch** (once; without it SonarQube stops at start):
  ```bash
  echo "vm.max_map_count=524288" | sudo tee /etc/sysctl.d/99-sonarqube.conf
  sudo sysctl --system
  ```

## 2. Start SonarQube

```bash
cd ~/travel-jenkins
git fetch origin
git switch code-inspection
cd sonarqube
cp .env.example .env
nano .env                     # SONAR_DB_PASSWORD, SONAR_ADMIN_PASSWORD (12+ characters, A-z, digit, special)
docker compose up -d
docker compose ps             # wait for sonarqube (healthy): 2–3 minutes
python3 setup.py
```

What `setup.py` prints:

```
Waiting for SonarQube at http://localhost:9000 .... up
admin password: set from .env (the default admin/admin no longer works)
login required: switched on
project travelagency: created (private)
quality gate of travelagency: Sonar way
token jenkins-travelagency: created; it can only analyse travelagency
...
Put this line into jenkins/.env (it is shown only now), then "docker compose up -d" in jenkins/:
SONAR_TOKEN=<the token>
```

The token is shown once. If it is lost: `python3 setup.py --new-token` revokes it and makes a new one.

## 3. Switch Jenkins to This Branch

```bash
cd ~/travel-jenkins/jenkins
nano .env
#   REPO_BRANCH=code-inspection
#   SONAR_TOKEN=<the token>   (the line from setup.py)
docker compose up -d --build   # adds the JUnit plugin and the credential sonar-token
```

## 4. Run and Read the Results

**travelagency → Build with Parameters → Build** (with 8 GB of RAM: `APP_REPLICAS` = 2).

- **Console Output**, stage Code inspection: the tests (`Tests run: 9, Failures: 0`), then the analysis and `QUALITY GATE STATUS: PASSED` (or `FAILED` with a link).
- **Build page → Test Result**: the unit tests of this build and their trend.
- **SonarQube** `http://<Ubuntu IP>:9000/dashboard?id=travelagency` (sign in as admin):
  - Overview: the quality gate, new and overall issues, coverage, duplications;
  - Issues: every finding with the line of code and why it is a problem;
  - Security Hotspots: findings to review, e.g. the disabled CSRF protection in `WebSecurityConfig`;
  - Activity: how the numbers change from commit to commit.

## 5. When the Quality Gate Fails

The build stops at Code inspection; nothing is scanned, published or deployed. The log ends with the link to the project page, which shows the failed conditions.

| Failed condition | What to do |
| --- | --- |
| New issues | Open Issues → New code, fix them, commit. A false positive can be marked "Accept" or "False positive" in SonarQube (with a comment) |
| Coverage on new code < 80 % | Add unit tests for the new code in `src/test/java` |
| Duplicated lines on new code > 3 % | Move the copied code into one method or class |
| Security hotspots not reviewed | Security Hotspots → review each: "Safe" (with a reason) or "Fixed" after changing the code |

## 6. How It Is Built

- **Analysis in the pipeline, gate in the pipeline.** Maven runs `verify` (tests and coverage) and the SonarQube scanner in one call; `sonar.qualitygate.wait=true` makes the scanner wait until SonarQube has processed the analysis and fail when the gate fails. No webhook or extra Jenkins plugin is needed.
- **Order of the stages.** Code inspection comes right after the build: code that does not pass the gate is not scanned, published or deployed.
- **Tests run twice, for two reasons.** Inside the Docker build (a failing test stops the image) and in Code inspection (coverage for SonarQube). The Docker build stays independent of Jenkins.
- **Mocks without an agent.** Mockito makes the mocks as subclasses (`src/test/resources/mockito-extensions/org.mockito.plugins.MockMaker`). Its default inline mock maker has to attach an agent to the running JVM, and in the Docker build it could not start (`Could not initialize plugin: interface org.mockito.plugins.MockMaker`, build #11). The mocked DAOs are interfaces, so subclasses are enough.
- **SonarQube as code.** `docker-compose.yml` fixes the versions; `setup.py` sets the admin password, requires a login for everything, creates the project as private and makes a token of type "project analysis": it can only send analyses of `travelagency`, nothing else.
- **Secrets.** The token is the Jenkins credential `sonar-token`, passed to the scanner as the environment variable `SONAR_TOKEN` (not on the command line), masked in the log. The database and admin passwords stay in `sonarqube/.env`.
- **Memory.** The heaps of the three SonarQube processes are limited in `docker-compose.yml` (512 MB each).
- **Community Build.** Free; it analyses one branch per project (the main one), which is what this pipeline sends.

## 7. Check

| What | How | Expected |
| --- | --- | --- |
| SonarQube is up | `docker compose ps` in `sonarqube/` | sonarqube and db `(healthy)` |
| Configuration is code | `python3 setup.py` again | only `already set` / `exists`, nothing created |
| No anonymous access | open `http://<Ubuntu IP>:9000/` in a private window | the login page |
| Tests run in the build | Console Output, Build and test / Code inspection | `Tests run: 9, Failures: 0` |
| Analysis | SonarQube → travelagency | issues, coverage above 0 % |
| Quality gate in Jenkins | Console Output | `QUALITY GATE STATUS: PASSED` |
| The gate stops a bad commit | commit new code without tests, push | red at Code inspection, `FAILED`; later stages not run |

## 8. If Something Goes Wrong

| Problem | What to do |
| --- | --- |
| SonarQube restarts, log: `max virtual memory areas vm.max_map_count [65530] is too low` | Section 1, the kernel setting |
| SonarQube or other containers get killed, `dmesg` shows "Out of memory" | Section 1: more RAM, swap, `APP_REPLICAS=2` |
| `setup.py`: `accepts neither SONAR_ADMIN_PASSWORD nor the default admin/admin` | The password was changed in the UI: write the current one into `.env` |
| `setup.py`: `must have at least 12 characters…` | SonarQube's password rule: make the password stronger |
| Code inspection: `Not authorized` / `401` | `SONAR_TOKEN` in `jenkins/.env` is wrong or revoked: `python3 setup.py --new-token`, update `.env`, `docker compose up -d` in `jenkins/` |
| Code inspection: `Connection refused` to `host.docker.internal:9000` | SonarQube is down: `docker compose ps` in `sonarqube/` |
| Tests: `Could not initialize plugin: interface org.mockito.plugins.MockMaker` | The file `src/test/resources/mockito-extensions/org.mockito.plugins.MockMaker` (`mock-maker-subclass`) is missing |
| `QUALITY GATE STATUS: FAILED` | Section 5 |
| `Timeout` waiting for the quality gate | SonarQube is slow (memory); run the build again |
