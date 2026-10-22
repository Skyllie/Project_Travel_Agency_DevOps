#!/usr/bin/env python3
"""Start the monitoring of TravelAgency and check that it sees everything.

Safe to run again.
  1. checks that the Terraform stack is deployed (network travelagency-tf-net, container travelagency-tf-db)
  2. creates or updates the MySQL user "exporter": read-only statistics, no access to the application data
  3. docker compose up -d
  4. waits for Prometheus and Grafana and prints the state of every scrape target

Usage, in the monitoring folder:
  python3 setup.py
Settings come from .env next to this file.
"""

import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
NETWORK = "travelagency-tf-net"
DB_CONTAINER = "travelagency-tf-db"
PROMETHEUS = "http://127.0.0.1:9090"
GRAFANA = "http://127.0.0.1:3000"

# Local services: never through a proxy from the environment
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def die(message):
    print(f"\nERROR: {message}", file=sys.stderr)
    sys.exit(1)


def run(args, stdin=None, check=True):
    result = subprocess.run(args, input=stdin, capture_output=True, text=True, cwd=HERE, check=False)
    if check and result.returncode != 0:
        die(f"{' '.join(args[:4])} …: {(result.stderr or result.stdout).strip()[:500]}")
    return result


def load_settings():
    env_file = HERE / ".env"
    if not env_file.exists():
        die(f"{env_file} not found: cp .env.example .env && nano .env")
    settings = {}
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = (part.strip() for part in line.split("=", 1))
            settings[key] = value.strip("'\"")
    for key in ("GRAFANA_ADMIN_PASSWORD", "MYSQL_EXPORTER_PASSWORD"):
        value = settings.get(key, "")
        if not value or value.startswith("change-me") or len(value) < 8:
            die(f"{key} in .env is empty, the example value or shorter than 8 characters")
    # The password goes into an SQL statement: only characters that need no quoting
    if not re.fullmatch(r"[A-Za-z0-9_-]+", settings["MYSQL_EXPORTER_PASSWORD"]):
        die("MYSQL_EXPORTER_PASSWORD: use only letters, digits, '-' and '_'")
    prefix = settings.get("TF_NET_PREFIX", "172.31.0")
    if not re.fullmatch(r"\d{1,3}\.\d{1,3}\.\d{1,3}", prefix):
        die(f"TF_NET_PREFIX must look like 172.31.0, not '{prefix}'")
    settings["TF_NET_PREFIX"] = prefix
    return settings


def check_stack(prefix):
    result = run(["docker", "network", "inspect", NETWORK], check=False)
    if result.returncode != 0:
        die(f"the network {NETWORK} does not exist: deploy the stack first (a Jenkins build of the pipeline)")
    subnets = [c.get("Subnet", "") for net in json.loads(result.stdout) for c in (net.get("IPAM", {}).get("Config") or [])]
    if not any(s.startswith(prefix + ".") for s in subnets):
        die(f"{NETWORK} has the subnet {', '.join(subnets)}; set TF_NET_PREFIX in .env to its first three parts")
    state = run(["docker", "inspect", "-f", "{{.State.Running}}", DB_CONTAINER], check=False).stdout.strip()
    if state != "true":
        die(f"the container {DB_CONTAINER} is not running: deploy the stack first")
    print(f"stack: network {NETWORK} ({', '.join(subnets)}), {DB_CONTAINER} running")


def ensure_mysql_user(password, prefix):
    # Only statistics: PROCESS and REPLICATION CLIENT for the status and InnoDB metrics,
    # performance_schema for the query statistics. No SELECT on the application tables.
    host = f"{prefix}.%"
    sql = f"""
CREATE USER IF NOT EXISTS 'exporter'@'{host}' IDENTIFIED BY '{password}' WITH MAX_USER_CONNECTIONS 3;
ALTER USER 'exporter'@'{host}' IDENTIFIED BY '{password}' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'exporter'@'{host}';
GRANT SELECT ON performance_schema.* TO 'exporter'@'{host}';
"""
    # The root password is already in the environment of the MySQL container (Terraform sets it):
    # it is read there, so it never appears on a command line
    run(["docker", "exec", "-i", DB_CONTAINER, "sh", "-c", 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --batch'],
        stdin=sql)
    print(f"MySQL user exporter@{host}: created or updated (statistics only)")


def get_json(url):
    try:
        with OPENER.open(url, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8") or "null")
    except urllib.error.HTTPError as err:
        return err.code, None
    except (urllib.error.URLError, OSError, ValueError):
        return 0, None


def wait_for(name, url, seconds=180):
    print(f"Waiting for {name} ", end="", flush=True)
    deadline = time.time() + seconds
    while time.time() < deadline:
        status, _ = get_json(url)
        if status == 200:
            print(" up")
            return
        print(".", end="", flush=True)
        time.sleep(3)
    die(f"{name} does not answer at {url}: docker compose logs {name.lower()}")


def report_targets():
    # The first scrapes happen within 15 s of the start; give them time
    time.sleep(20)
    status, answer = get_json(f"{PROMETHEUS}/api/v1/targets?state=active")
    if status != 200 or not answer:
        die("cannot read the targets of Prometheus")
    targets = sorted(answer["data"]["activeTargets"], key=lambda t: (t["labels"]["job"], t["labels"].get("instance", "")))
    print("\nTargets of Prometheus:")
    down = 0
    for t in targets:
        health = t.get("health", "?")
        down += health != "up"
        line = f"  {health:8} {t['labels']['job']:15} {t['labels'].get('instance', '')}"
        if health != "up" and t.get("lastError"):
            line += f"   ({t['lastError'][:100]})"
        print(line)
    if down:
        print(f"\n{down} target(s) not up yet. Wait a minute and look again: http://localhost:9090/targets")
    else:
        print("\nAll targets are up.")


def main():
    settings = load_settings()
    check_stack(settings["TF_NET_PREFIX"])
    ensure_mysql_user(settings["MYSQL_EXPORTER_PASSWORD"], settings["TF_NET_PREFIX"])
    print("docker compose up -d …")
    run(["docker", "compose", "up", "-d"])
    wait_for("Prometheus", f"{PROMETHEUS}/-/ready")
    wait_for("Grafana", f"{GRAFANA}/api/health")
    report_targets()
    print("""
Grafana:    http://<Ubuntu IP>:3000/   user admin, password GRAFANA_ADMIN_PASSWORD
            Dashboards → TravelAgency → Infrastructure / Application
Prometheus: http://localhost:9090/     on Ubuntu (alerts: /alerts, targets: /targets)""")


if __name__ == "__main__":
    main()
