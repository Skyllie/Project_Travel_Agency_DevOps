#!/usr/bin/env python3
"""Configure Nexus for TravelAgency through its REST API.

Safe to run again: every step reads the current state first and changes only what differs.
  1. wait until Nexus answers
  2. replace the generated admin password with NEXUS_ADMIN_PASSWORD
  3. accept the Community Edition EULA (only with NEXUS_ACCEPT_EULA=yes)
  4. switch anonymous access off, enable the Docker Bearer Token realm
  5. repositories travelagency-maven (WARs) and travelagency-docker (images, Docker connector on port 8082)
  6. role travelagency-ci and the user Jenkins publishes with
  7. log in as that user to check the repository and the Docker registry

Usage, in the nexus folder after "docker compose up -d":
  python3 setup.py
Settings come from .env next to this file; environment variables with the same names override them.
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Published by docker-compose.yml: the UI and REST API, and the Docker connector of travelagency-docker
NEXUS_URL = os.environ.get("NEXUS_URL", "http://localhost:8091")
REGISTRY_URL = os.environ.get("NEXUS_REGISTRY_URL", "http://localhost:8092")

MAVEN_REPO = "travelagency-maven"
DOCKER_REPO = "travelagency-docker"
DOCKER_CONNECTOR_PORT = 8082  # inside the container; docker-compose.yml maps it to 127.0.0.1:8092
CI_ROLE = "travelagency-ci"

REPOSITORIES = [
    # (format in the API path, format in the repository list, settings)
    ("maven", "maven2", {
        "name": MAVEN_REPO,
        "online": True,
        # ALLOW_ONCE: a released version is never overwritten
        "storage": {"blobStoreName": "default", "strictContentTypeValidation": True, "writePolicy": "ALLOW_ONCE"},
        "maven": {"versionPolicy": "RELEASE", "layoutPolicy": "STRICT", "contentDisposition": "ATTACHMENT"},
    }),
    ("docker", "docker", {
        "name": DOCKER_REPO,
        "online": True,
        # ALLOW_ONCE: an image tag (the commit id) always points to the same image
        "storage": {"blobStoreName": "default", "strictContentTypeValidation": True,
                    "writePolicy": "ALLOW_ONCE", "latestPolicy": False},
        # forceBasicAuth: every pull and push needs a login
        "docker": {"v1Enabled": False, "forceBasicAuth": True, "httpPort": DOCKER_CONNECTOR_PORT},
    }),
]

# Only the two TravelAgency repositories: read, upload, delete (for the retention step)
CI_PRIVILEGES = [
    f"nx-repository-view-maven2-{MAVEN_REPO}-*",
    f"nx-repository-view-docker-{DOCKER_REPO}-*",
    "nx-component-upload",
]

# Nexus is on this machine: never send its passwords through a proxy from the environment
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class NexusDown(Exception):
    pass


def die(message):
    print(f"\nERROR: {message}", file=sys.stderr)
    sys.exit(1)


class Nexus:
    def __init__(self, base_url, user=None, password=None):
        self.base_url = base_url.rstrip("/")
        self.user = user
        self.password = password

    def request(self, method, path, body=None):
        """Return (HTTP status, parsed JSON or text). Raise NexusDown when nothing answers."""
        headers = {"Accept": "application/json"}
        data = None
        if isinstance(body, str):
            data, headers["Content-Type"] = body.encode("utf-8"), "text/plain"
        elif body is not None:
            data, headers["Content-Type"] = json.dumps(body).encode("utf-8"), "application/json"
        if self.user is not None:
            token = base64.b64encode(f"{self.user}:{self.password}".encode("utf-8")).decode("ascii")
            headers["Authorization"] = f"Basic {token}"
        req = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with OPENER.open(req, timeout=60) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as err:
            status, raw = err.code, err.read()
        except (urllib.error.URLError, OSError) as err:
            raise NexusDown(str(getattr(err, "reason", err))) from err
        text = raw.decode("utf-8", "replace")
        try:
            return status, json.loads(text) if text.strip() else None
        except ValueError:
            return status, text

    def call(self, method, path, body=None, what=None):
        """A request that must succeed (2xx); stop with Nexus' answer otherwise."""
        try:
            status, answer = self.request(method, path, body)
        except NexusDown as err:
            die(f"Nexus at {self.base_url} does not answer: {err}")
        if not 200 <= status < 300:
            detail = answer if isinstance(answer, str) else json.dumps(answer)
            die(f"{what or method + ' ' + path}: HTTP {status} {(detail or '')[:600]}")
        return answer

    def can_log_in(self):
        status, _ = self.request("GET", "/service/rest/v1/security/users?userId=admin")
        if status in (401, 403):
            return False
        if status != 200:
            die(f"unexpected answer while checking the admin login: HTTP {status}")
        return True


def load_settings():
    settings = {}
    env_file = HERE / ".env"
    if not env_file.exists():
        die(f"{env_file} not found: cp .env.example .env && nano .env")
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        settings[key] = value
    for key in ("NEXUS_ADMIN_PASSWORD", "NEXUS_CI_USER", "NEXUS_CI_PASSWORD", "NEXUS_ACCEPT_EULA"):
        if os.environ.get(key):
            settings[key] = os.environ[key]

    for key in ("NEXUS_ADMIN_PASSWORD", "NEXUS_CI_USER", "NEXUS_CI_PASSWORD"):
        if not settings.get(key):
            die(f"{key} is empty in .env")
    for key in ("NEXUS_ADMIN_PASSWORD", "NEXUS_CI_PASSWORD"):
        value = settings[key]
        if value.startswith("change-me") or len(value) < 8:
            die(f"{key} in .env is the example value or shorter than 8 characters: set your own password")
    if settings["NEXUS_CI_USER"] in ("admin", "anonymous"):
        die("NEXUS_CI_USER must be a separate user, not admin or anonymous")
    if settings["NEXUS_ADMIN_PASSWORD"] == settings["NEXUS_CI_PASSWORD"]:
        die("NEXUS_ADMIN_PASSWORD and NEXUS_CI_PASSWORD must differ")
    return settings


def wait_until_up():
    print(f"Waiting for Nexus at {NEXUS_URL} ", end="", flush=True)
    anonymous = Nexus(NEXUS_URL)
    deadline = time.time() + 600
    while True:
        try:
            status, _ = anonymous.request("GET", "/service/rest/v1/status/writable")
            if status == 200:
                print(" up")
                return
        except NexusDown:
            pass
        if time.time() > deadline:
            die("Nexus did not start in 10 minutes. Look at: docker compose logs nexus")
        print(".", end="", flush=True)
        time.sleep(5)


def generated_admin_password():
    """The password Nexus writes to /nexus-data/admin.password on the first start (None if it is gone)."""
    try:
        result = subprocess.run(
            ["docker", "compose", "exec", "-T", "nexus", "cat", "/nexus-data/admin.password"],
            cwd=HERE, capture_output=True, text=True, timeout=120, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    password = result.stdout.strip()
    return password if result.returncode == 0 and password else None


def ensure_admin_password(settings):
    wanted = settings["NEXUS_ADMIN_PASSWORD"]
    admin = Nexus(NEXUS_URL, "admin", wanted)
    if admin.can_log_in():
        print("admin password: already set")
        return admin
    first = generated_admin_password()
    if not first:
        die("Nexus does not accept NEXUS_ADMIN_PASSWORD for admin, and the generated password "
            "(/nexus-data/admin.password) is gone because the password was changed before. "
            "Put the current admin password into .env")
    bootstrap = Nexus(NEXUS_URL, "admin", first)
    if not bootstrap.can_log_in():
        die("Nexus accepts neither NEXUS_ADMIN_PASSWORD nor the generated admin password")
    bootstrap.call("PUT", "/service/rest/v1/security/users/admin/change-password", wanted,
                   what="change the admin password")
    print("admin password: set from .env (Nexus deleted the generated one)")
    return admin


def ensure_eula(admin, settings):
    status, eula = admin.request("GET", "/service/rest/v1/system/eula")
    if status == 404:
        print("EULA: this edition does not ask for it")
        return
    if status != 200 or not isinstance(eula, dict):
        die(f"cannot read the EULA status: HTTP {status}")
    if eula.get("accepted"):
        print("EULA: accepted")
        return
    if settings.get("NEXUS_ACCEPT_EULA", "").strip().lower() != "yes":
        die("Nexus Community Edition asks to accept its End User License Agreement:\n  "
            f"{eula.get('disclaimer', '')}\n"
            "Read it, write NEXUS_ACCEPT_EULA=yes into .env and run setup.py again.")
    admin.call("POST", "/service/rest/v1/system/eula",
               {"accepted": True, "disclaimer": eula.get("disclaimer", "")}, what="accept the EULA")
    print("EULA: accepted (NEXUS_ACCEPT_EULA=yes)")


def ensure_security(admin):
    realms = admin.call("GET", "/service/rest/v1/security/realms/active") or []
    if "DockerToken" in realms:
        print("realm Docker Bearer Token: active")
    else:
        admin.call("PUT", "/service/rest/v1/security/realms/active", realms + ["DockerToken"],
                   what="enable the Docker Bearer Token realm")
        print("realm Docker Bearer Token: enabled")

    anonymous = admin.call("GET", "/service/rest/v1/security/anonymous")
    if anonymous.get("enabled"):
        anonymous["enabled"] = False
        admin.call("PUT", "/service/rest/v1/security/anonymous", anonymous, what="switch anonymous access off")
        print("anonymous access: switched off")
    else:
        print("anonymous access: off")


def ensure_repositories(admin):
    existing = {repo["name"]: repo for repo in admin.call("GET", "/service/rest/v1/repositories") or []}
    for api_format, list_format, settings in REPOSITORIES:
        name = settings["name"]
        found = existing.get(name)
        if found is None:
            admin.call("POST", f"/service/rest/v1/repositories/{api_format}/hosted", settings,
                       what=f"create the repository {name}")
            print(f"repository {name}: created")
            continue
        if found.get("format") != list_format or found.get("type") != "hosted":
            die(f"a repository {name} already exists as {found.get('format')}/{found.get('type')}, "
                f"expected {list_format}/hosted. Delete or rename it in the Nexus UI")
        admin.call("PUT", f"/service/rest/v1/repositories/{api_format}/hosted/{name}", settings,
                   what=f"update the repository {name}")
        print(f"repository {name}: settings checked")


def ensure_ci_role(admin):
    role = {
        "id": CI_ROLE,
        "name": CI_ROLE,
        "description": "Jenkins: publish, read and delete TravelAgency WARs and images",
        "privileges": CI_PRIVILEGES,
        "roles": [],
    }
    path = f"/service/rest/v1/security/roles/{CI_ROLE}"
    status, _ = admin.request("GET", path)
    if status == 200:
        admin.call("PUT", path, role, what=f"update the role {CI_ROLE}")
        print(f"role {CI_ROLE}: privileges checked")
    elif status == 404:
        admin.call("POST", "/service/rest/v1/security/roles", role, what=f"create the role {CI_ROLE}")
        print(f"role {CI_ROLE}: created")
    else:
        die(f"cannot read the role {CI_ROLE}: HTTP {status}")


def ensure_ci_user(admin, user_id, password):
    query = urllib.parse.urlencode({"userId": user_id, "source": "default"})
    users = admin.call("GET", f"/service/rest/v1/security/users?{query}") or []
    found = next((user for user in users if user.get("userId") == user_id), None)
    quoted = urllib.parse.quote(user_id, safe="")
    if found is None:
        admin.call("POST", "/service/rest/v1/security/users", {
            "userId": user_id,
            "firstName": "Jenkins",
            "lastName": "CI",
            "emailAddress": f"{user_id}@example.com",
            "password": password,
            "status": "active",
            "roles": [CI_ROLE],
        }, what=f"create the user {user_id}")
        print(f"user {user_id}: created with the role {CI_ROLE}")
        return
    found["roles"] = [CI_ROLE]
    found["status"] = "active"
    admin.call("PUT", f"/service/rest/v1/security/users/{quoted}", found, what=f"update the user {user_id}")
    admin.call("PUT", f"/service/rest/v1/security/users/{quoted}/change-password", password,
               what=f"set the password of {user_id}")
    print(f"user {user_id}: role and password checked")


def verify(user_id, password):
    ci = Nexus(NEXUS_URL, user_id, password)
    for repo in (MAVEN_REPO, DOCKER_REPO):
        ci.call("GET", f"/service/rest/v1/components?repository={repo}",
                what=f"read the repository {repo} as {user_id}")
    print(f"check: {user_id} can read {MAVEN_REPO} and {DOCKER_REPO}")

    # The Docker connector starts listening a few seconds after the repository is saved
    registry = Nexus(REGISTRY_URL, user_id, password)
    for attempt in range(12):
        try:
            status, _ = registry.request("GET", "/v2/")
            break
        except NexusDown as err:
            if attempt == 11:
                die(f"the Docker registry at {REGISTRY_URL} does not answer ({err}). "
                    "Is port 8092 published (docker compose ps)?")
            time.sleep(5)
    if status != 200:
        die(f"the Docker registry at {REGISTRY_URL} refused {user_id}: HTTP {status}")
    print(f"check: Docker registry {REGISTRY_URL} accepts {user_id}")


def main():
    settings = load_settings()
    wait_until_up()
    admin = ensure_admin_password(settings)
    ensure_eula(admin, settings)
    ensure_security(admin)
    ensure_repositories(admin)
    ensure_ci_role(admin)
    ensure_ci_user(admin, settings["NEXUS_CI_USER"], settings["NEXUS_CI_PASSWORD"])
    verify(settings["NEXUS_CI_USER"], settings["NEXUS_CI_PASSWORD"])

    print(f"""
Nexus is ready.
  UI:               {NEXUS_URL}/  (from Windows: http://<Ubuntu IP>:8091/), user admin
  Maven repository: {NEXUS_URL}/repository/{MAVEN_REPO}/
  Docker registry:  {REGISTRY_URL.split('://', 1)[-1]}  (repository {DOCKER_REPO}, only on this machine)
Jenkins publishes as {settings['NEXUS_CI_USER']}: put NEXUS_CI_USER and NEXUS_CI_PASSWORD into jenkins/.env""")


if __name__ == "__main__":
    main()
