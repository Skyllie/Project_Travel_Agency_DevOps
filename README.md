# TravelAgency — Scanning Images and Dependencies in CI/CD

This branch adds security scans to the Jenkins pipeline: **Snyk** checks the Maven dependencies (SCA), **Trivy** and **Grype** check the Docker image.
A security gate stops the build before anything vulnerable is published to Nexus or deployed.
It covers the card "Scanning images and dependencies in CI/CD".
It builds on the `artifact-management` branch: the same pipeline (Nexus, rollback, retention), with four new stages.

```
git push (branch security-scanning)
   │  Jenkins checks the branch every 5 minutes (pollSCM)
   ▼
Jenkins  (http://<Ubuntu IP>:8081)
    1. Version              tag = short commit id
    2. Build and test       docker build: Maven, tests, WAR, image
    3. Dependencies: Snyk   SCA: every library of pom.xml with its dependencies; snapshot to app.snyk.io
    4. Image: Trivy         Ubuntu packages of the image, the jars in the WAR; SBOM of the image
    5. Image: Grype         the same image against a second vulnerability database
    6. Security gate        stop on a CRITICAL vulnerability that has a fix (accepted risks excepted)
    7. Publish to Nexus     WAR + SBOM → travelagency-maven, image → travelagency-docker
    8. Pull from Nexus
    9. Terraform check
   10. Deploy
   11. Smoke test
   12. Nexus retention
```

| File | What it is |
| --- | --- |
| `ci/scan.sh` | The scans and the gate: `snyk`, `trivy`, `grype`, `gate` |
| `ci/accepted-risks.txt` | Vulnerabilities the gate lets pass, each with a reason and an end date |
| `Jenkinsfile` | 12 stages; `SCAN_FAIL_ON = 'CRITICAL'`; reports on the build page |
| `jenkins/Dockerfile` | Adds Trivy, Grype, Snyk CLI and Maven, each checked against a pinned checksum |
| `jenkins/plugins.txt` | Adds Warnings (`warnings-ng`): the scanner results as pages of the build |
| `jenkins/casc.yaml` | New credential `snyk-token` |
| `ci/nexus.sh` | Uploads the SBOM next to the WAR |

| Scanner | What it scans | Database |
| --- | --- | --- |
| Snyk Open Source | `pom.xml`: Snyk runs Maven and checks the whole dependency tree, direct and transitive | Snyk Vulnerability Database |
| Trivy | The built image: Ubuntu packages, the JDK, the jars inside `ROOT.war` | Trivy DB (NVD, GitHub advisories, Ubuntu) + Trivy Java DB |
| Grype | The same image | Anchore Grype DB |

Two image scanners on purpose: their databases and matching differ, so each finds things the other misses.

## 1. Before You Start

- The `artifact-management` branch works: Nexus is set up, Jenkins publishes and deploys (README of that branch).
- **Snyk token.** Sign up at <https://app.snyk.io> (the free plan is enough; signing in with GitHub works). Then Account settings → General → Auth Token → click to show, and copy it.
- Disk: about 2 GB more. The Jenkins image grows by about 300 MB (scanners, Maven), and the vulnerability databases are cached in `jenkins_home` (about 1 GB, downloaded by the first build).

## 2. Switch Jenkins to This Branch

```bash
cd ~/travel-jenkins
git fetch origin
git switch security-scanning
cd jenkins
nano .env
#   REPO_BRANCH=security-scanning
#   SNYK_TOKEN=<the token from app.snyk.io>
docker compose up -d --build    # 5–10 minutes: Maven, Trivy, Grype, Snyk CLI, the Warnings plugin
docker compose exec jenkins sh -c 'mvn -v | head -1; trivy --version | head -1; grype version | head -2; snyk --version'
```

## 3. Run and Read the Results

**travelagency → Build with Parameters → Build.** The first build takes longer: Snyk lets Maven download the dependencies once, Trivy and Grype download their databases.

Where the results are:
- **Console Output**, stage Security gate: the decision. Its form (the lines are an illustration):
  ```
  Security gate: no CRITICAL or higher vulnerability that already has a fix
    snyk     0
    trivy    1
             CRITICAL CVE-2022-22965 org.springframework:spring-beans 5.3.9 -> 5.2.20.RELEASE, 5.3.18
    grype    1
             ...
  ERROR: 2 findings above: upgrade the packages to the versions after '->' (pom.xml or the base image)
  ```
- **Build page → Snyk / Trivy / Grype** (left menu, Warnings plugin): every finding of every severity, with filters by severity and package, and the trend over builds.
- **Build page → Build Artifacts → reports/**: `snyk.txt`, `trivy.txt`, `grype.txt` (tables of what was found), the full JSON reports, `snyk.sarif` and `sbom.cdx.json`.
- **app.snyk.io → Projects → travelagency**: the dependency tree from the last build (`snyk monitor`); Snyk e-mails when a new vulnerability appears in it.

The gate counts only vulnerabilities of `SCAN_FAIL_ON` (CRITICAL) or higher that already have a fixed version: those can be fixed now, so they block. Everything else is in the reports.

## 4. When the Gate Stops the Build

The gate prints each blocking finding as `severity id package installed-version -> fixed-version`. Fix it, commit, push; the next build checks again.

| Where the package is | How to fix |
| --- | --- |
| A library in `pom.xml` (Snyk; Trivy and Grype show the jar in `ROOT.war`) | Raise its version to the one after `->`. For a transitive library, raise the library that brings it (Snyk shows the path), or pin it in `<dependencyManagement>` |
| An Ubuntu package or the JDK of the base image (Trivy, Grype) | Get the newest base image: `docker pull tomcat:9.0-jdk17-temurin-noble` on Ubuntu, then build again |
| No fixed version you can use | Add it to `ci/accepted-risks.txt` with the reason and an end date (section 5) |

The original libraries of the project have known critical vulnerabilities, for example Spring Framework 5.3.9 (CVE-2022-22965, "Spring4Shell", remote code execution in exactly this setup: Spring MVC as a WAR on Tomcat with JDK 9+) and Spring Security 5.6.0 (CVE-2022-22978, authorization bypass). So the first commit of this branch, which adds only the scans, stops at the gate.

## 5. Accepted Risks

`ci/accepted-risks.txt`, one vulnerability per line:

```
<ID> <until YYYY-MM-DD> <why it is accepted and what will remove it>
```

- The ID can be a CVE, a GitHub advisory (GHSA) or a Snyk id; the gate matches it against all ids each scanner gives, so one line covers all three scanners.
- The scanners still report it; only the gate lets it pass, and prints `(accepted: ci/accepted-risks.txt)` next to it.
- After the date the gate blocks it again, so an accepted risk is looked at again instead of being forgotten.
- Every line is a decision in Git: who accepted what, when and why.

## 6. How It Is Built

- **Scan before publish.** The scans run after the build and before Publish to Nexus. A build that fails the gate leaves nothing in Nexus and changes nothing on the servers.
- **Scans collect, the gate decides.** The three scan stages only write reports, so a build always shows all three results; the stage Security gate then decides once, with one rule for all scanners.
- **Fail closed.** If a scanner cannot run (no network, bad token), its stage fails and so does the build: a scan that did not happen never counts as clean.
- **Tools as code.** Trivy, Grype, Snyk CLI and Maven are installed in the Jenkins image at fixed versions and checked against pinned SHA-256/SHA-512 sums. Their databases are cached in `jenkins_home` and refreshed by the scanners themselves.
- **Secrets.** The Snyk token is the Jenkins credential `snyk-token`, from `jenkins/.env` through JCasC; Jenkins masks it in the log.
- **SBOM.** Trivy writes a CycloneDX list of every package in the image (`reports/sbom.cdx.json`). It is archived with the build and uploaded to Nexus next to the WAR as `TravelAgency-<version>-cyclonedx.json`, so for any stored version it is known what is inside.
- **Old reports never count.** The stage Version deletes `reports/` first, so the gate reads only the reports of this build.
- **Rollback** (`ROLLBACK_TO`) skips the scans: the version in Nexus passed the gate when it was built.

## 7. Check

| What | How | Expected |
| --- | --- | --- |
| Scanners in Jenkins | the `docker compose exec` line of section 2 | Maven 3.9.16, Trivy 0.75.0, Grype 0.120.1, Snyk 1.1307.4 |
| The gate stops a vulnerable build | the build of the first commit of this branch (old libraries) | red at Security gate; Publish, Deploy not run; Nexus unchanged |
| The gate passes | a build after the upgrade | green; `Passed` in the Security gate log |
| Reports | build page | Snyk, Trivy, Grype pages; `reports/` in Build Artifacts |
| SBOM in Nexus | Browse → `travelagency-maven` → `…/1.0-<commit>/` | `TravelAgency-1.0-<commit>-cyclonedx.json` |
| Snyk project | app.snyk.io → Projects | `travelagency`, tested at the time of the build |

## 8. If Something Goes Wrong

| Problem | What to do |
| --- | --- |
| `SNYK_TOKEN is not set` / `Authentication error` | Put the token into `jenkins/.env` (`SNYK_TOKEN=`), `docker compose up -d` in `jenkins/` |
| `snyk test could not run (exit code 2)` | Look above it in the log: usually Maven could not resolve `pom.xml` or Snyk is unreachable |
| Trivy or Grype: database download fails | Network or rate limit: build again later; the databases are cached after the first success |
| `reports/… is missing: the … scan did not run` | A scan stage failed or was skipped; the gate never passes without all three reports |
| The gate blocks a package with no fixed version you can use | Section 5: accept it with a reason and an end date |
| `ci/accepted-risks.txt: '…' must be: <ID> <YYYY-MM-DD> <reason>` | Fix that line: three fields, a date like `2027-04-30` |
| Build timeout on the first run | The databases are large; build again: they are already partly cached |
