#!/usr/bin/env python3
"""Configure SonarQube for TravelAgency through its Web API.

Safe to run again: every step reads the current state first and changes only what differs.
  1. wait until SonarQube is up
  2. replace the default admin/admin password with SONAR_ADMIN_PASSWORD
  3. require a login for everything (no anonymous browsing)
  4. create the private project "travelagency"
  5. create the token Jenkins analyses with: it can only analyse this project.
     It is printed once; run with --new-token to replace it

Usage, in the sonarqube folder after "docker compose up -d":
  python3 setup.py
  python3 setup.py --new-token
Settings come from .env next to this file; an environment variable with the same name overrides it.
"""

import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Published by docker-compose.yml
SONAR_URL = os.environ.get("SONAR_URL", "http://localhost:9000")

PROJECT_KEY = "travelagency"
PROJECT_NAME = "TravelAgency"
TOKEN_NAME = "jenkins-travelagency"

# SonarQube's own password rule (ChangePasswordAction)
PASSWORD_RULE = "at least 12 characters with an uppercase letter, a lowercase letter, a digit and a special character"

# SonarQube is on this machine: never send its passwords through a proxy from the environment
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class SonarDown(Exception):
    pass


def die(message):
    print(f"\nERROR: {message}", file=sys.stderr)
    sys.exit(1)


class Sonar:
    def __init__(self, user=None, password=""):
        self.user = user
        self.password = password

    def request(self, method, path, params=None):
        """Return (HTTP status, parsed JSON or text). Parameters go as a form for POST, as a query for GET."""
        url = SONAR_URL.rstrip("/") + path
        data = None
        headers = {"Accept": "application/json"}
        if params and method == "GET":
            url += "?" + urllib.parse.urlencode(params)
        elif params:
            data = urllib.parse.urlencode(params).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        if self.user is not None:
            token = base64.b64encode(f"{self.user}:{self.password}".encode("utf-8")).decode("ascii")
            headers["Authorization"] = f"Basic {token}"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with OPENER.open(req, timeout=60) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as err:
            status, raw = err.code, err.read()
        except (urllib.error.URLError, OSError) as err:
            raise SonarDown(str(getattr(err, "reason", err))) from err
        text = raw.decode("utf-8", "replace")
        try:
            return status, json.loads(text) if text.strip() else None
        except ValueError:
            return status, text

    def call(self, method, path, params=None, what=None):
        """A request that must succeed (2xx); stop with SonarQube's answer otherwise."""
        try:
            status, answer = self.request(method, path, params)
        except SonarDown as err:
            die(f"SonarQube at {SONAR_URL} does not answer: {err}")
        if not 200 <= status < 300:
            if isinstance(answer, dict) and answer.get("errors"):
                detail = "; ".join(e.get("msg", "") for e in answer["errors"])
            else:
                detail = answer if isinstance(answer, str) else json.dumps(answer)
            die(f"{what or method + ' ' + path}: HTTP {status} {(detail or '')[:600]}")
        return answer

    def valid(self):
        """True when SonarQube accepts this login (api/authentication/validate always answers 200)."""
        answer = self.call("GET", "/api/authentication/validate", what="check a login")
        return bool(isinstance(answer, dict) and answer.get("valid"))


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
    if os.environ.get("SONAR_ADMIN_PASSWORD"):
        settings["SONAR_ADMIN_PASSWORD"] = os.environ["SONAR_ADMIN_PASSWORD"]

    password = settings.get("SONAR_ADMIN_PASSWORD", "")
    if not password or password.startswith("change-me"):
        die("SONAR_ADMIN_PASSWORD in .env is empty or the example value: set your own password")
    strong = (len(password) >= 12 and re.search(r"[A-Z]", password) and re.search(r"[a-z]", password)
              and re.search(r"[0-9]", password) and re.search(r"[^A-Za-z0-9]", password))
    if not strong:
        die(f"SONAR_ADMIN_PASSWORD must have {PASSWORD_RULE}")
    if password == "admin":
        die("SONAR_ADMIN_PASSWORD must not be the default password")
    return settings


def wait_until_up():
    print(f"Waiting for SonarQube at {SONAR_URL} ", end="", flush=True)
    anonymous = Sonar()
    deadline = time.time() + 600
    state = "no answer"
    while True:
        try:
            status, answer = anonymous.request("GET", "/api/system/status")
            if status == 200 and isinstance(answer, dict):
                state = answer.get("status", state)
                if state == "UP":
                    print(" up")
                    return
                if state == "DB_MIGRATION_NEEDED":
                    die(f"SonarQube needs a database upgrade: open {SONAR_URL}/setup")
        except SonarDown:
            pass
        if time.time() > deadline:
            die(f"SonarQube is not up after 10 minutes (last state: {state}). Look at: docker compose logs sonarqube")
        print(".", end="", flush=True)
        time.sleep(5)


def ensure_admin_password(wanted):
    admin = Sonar("admin", wanted)
    if admin.valid():
        print("admin password: already set")
        return admin
    first = Sonar("admin", "admin")
    if not first.valid():
        die("SonarQube accepts neither SONAR_ADMIN_PASSWORD nor the default admin/admin. "
            "If the password was changed in the UI, write it into .env")
    first.call("POST", "/api/users/change_password",
               {"login": "admin", "previousPassword": "admin", "password": wanted},
               what="change the admin password")
    print("admin password: set from .env (the default admin/admin no longer works)")
    return admin


def ensure_force_authentication(admin):
    answer = admin.call("GET", "/api/settings/values", {"keys": "sonar.forceAuthentication"})
    current = next((s.get("value") for s in answer.get("settings", []) if s.get("key") == "sonar.forceAuthentication"),
                   None)
    if current == "true":
        print("login required: yes")
        return
    admin.call("POST", "/api/settings/set", {"key": "sonar.forceAuthentication", "value": "true"},
               what="require a login")
    print("login required: switched on")


def ensure_project(admin):
    answer = admin.call("GET", "/api/projects/search", {"projects": PROJECT_KEY})
    found = [c for c in answer.get("components", []) if c.get("key") == PROJECT_KEY]
    if not found:
        admin.call("POST", "/api/projects/create",
                   {"project": PROJECT_KEY, "name": PROJECT_NAME, "visibility": "private", "mainBranch": "main"},
                   what=f"create the project {PROJECT_KEY}")
        print(f"project {PROJECT_KEY}: created (private)")
    elif found[0].get("visibility") != "private":
        admin.call("POST", "/api/projects/update_visibility", {"project": PROJECT_KEY, "visibility": "private"},
                   what=f"make the project {PROJECT_KEY} private")
        print(f"project {PROJECT_KEY}: made private")
    else:
        print(f"project {PROJECT_KEY}: exists (private)")
    gate = admin.call("GET", "/api/qualitygates/get_by_project", {"project": PROJECT_KEY})
    print(f"quality gate of {PROJECT_KEY}: {gate.get('qualityGate', {}).get('name', '?')}")


def ensure_token(admin, replace):
    answer = admin.call("GET", "/api/user_tokens/search")
    exists = any(t.get("name") == TOKEN_NAME for t in answer.get("userTokens", []))
    if exists and not replace:
        print(f"token {TOKEN_NAME}: exists. SonarQube shows a token only once; "
              "to make a new one: python3 setup.py --new-token")
        return None
    if exists:
        admin.call("POST", "/api/user_tokens/revoke", {"name": TOKEN_NAME}, what="revoke the old token")
        print(f"token {TOKEN_NAME}: old one revoked")
    answer = admin.call("POST", "/api/user_tokens/generate",
                        {"name": TOKEN_NAME, "type": "PROJECT_ANALYSIS_TOKEN", "projectKey": PROJECT_KEY},
                        what="create the token for Jenkins")
    token = answer.get("token", "")
    if not token or not Sonar(token, "").valid():
        die("SonarQube made a token but does not accept it")
    print(f"token {TOKEN_NAME}: created; it can only analyse {PROJECT_KEY}")
    return token


def main():
    replace = "--new-token" in sys.argv[1:]
    unknown = [arg for arg in sys.argv[1:] if arg != "--new-token"]
    if unknown:
        die(f"unknown argument {unknown[0]}. Usage: python3 setup.py [--new-token]")
    settings = load_settings()
    wait_until_up()
    admin = ensure_admin_password(settings["SONAR_ADMIN_PASSWORD"])
    ensure_force_authentication(admin)
    ensure_project(admin)
    token = ensure_token(admin, replace)

    print(f"""
SonarQube is ready.
  UI:       {SONAR_URL}/  (from Windows: http://<Ubuntu IP>:9000/), user admin
  Project:  {SONAR_URL}/dashboard?id={PROJECT_KEY}""")
    if token:
        print(f"""
Put this line into jenkins/.env (it is shown only now), then "docker compose up -d" in jenkins/:
SONAR_TOKEN={token}""")


if __name__ == "__main__":
    main()
