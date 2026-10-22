#!/usr/bin/env python3
"""Load test + measurements for the capacity plan.

For each number of virtual users (VUs) it runs k6 (loadtest/loadtest.js) against the load balancer,
then asks Prometheus what the servers used during that run. At the end it prints a table and writes it,
with an estimate of the capacity, to results/capacity-<date>.md.

Usage, in the monitoring folder, with the monitoring running (setup.py):
  python3 loadtest.py                                 # 10, 25, 50 VUs, 2 minutes each, login page only
  python3 loadtest.py --vus 10,50,100 --duration 3m
  LOADTEST_PASSWORD=... python3 loadtest.py --user some.user   # also signs in (reads the database)
"""

import argparse
import getpass
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"
PROMETHEUS = "http://127.0.0.1:9090"
K6_IMAGE = "grafana/k6:1.8.1"
NETWORK = "travelagency-tf-net"
TARGET = "http://travelagency-tf-lb"
# Service level of the plan (also the thresholds in loadtest.js)
SLO_P95_MS = 1000
SLO_ERRORS = 0.01
# Plan the servers to run at no more than this share of the CPU, to keep room for peaks
TARGET_CPU = 0.7

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def die(message):
    print(f"\nERROR: {message}", file=sys.stderr)
    sys.exit(1)


def seconds(duration):
    units = {"s": 1, "m": 60, "h": 3600}
    if not duration or duration[-1] not in units or not duration[:-1].isdigit():
        die(f"--duration like 90s, 2m or 1h, not '{duration}'")
    return int(duration[:-1]) * units[duration[-1]]


def prom(query, at):
    url = f"{PROMETHEUS}/api/v1/query?" + urllib.parse.urlencode({"query": query, "time": at})
    try:
        with OPENER.open(url, timeout=20) as resp:
            result = json.loads(resp.read())["data"]["result"]
    except (urllib.error.URLError, OSError, ValueError, KeyError) as err:
        die(f"Prometheus does not answer at {PROMETHEUS} ({err}): run setup.py first")
    if not result:
        return None
    value = float(result[0]["value"][1])
    return None if value != value else value  # NaN -> None


def run_k6(vus, duration, user, prefix):
    summary_name = f"k6-{vus}vus.json"
    (RESULTS / summary_name).unlink(missing_ok=True)
    cmd = [
        "docker", "run", "--rm", "--network", NETWORK, "--ip", f"{prefix}.44",
        "--user", f"{os.getuid()}:{os.getgid()}",
        "-v", f"{HERE / 'loadtest' / 'loadtest.js'}:/scripts/loadtest.js:ro",
        "-v", f"{RESULTS}:/results",
        "-e", f"VUS={vus}", "-e", f"DURATION={duration}", "-e", f"BASE_URL={TARGET}",
        "-e", f"SUMMARY_FILE=/results/{summary_name}",
        # Name only: docker takes the value from this process, so it is not on the command line
        "-e", "LOGIN_USER", "-e", "LOGIN_PASSWORD",
        K6_IMAGE, "run", "--quiet", "/scripts/loadtest.js",
    ]
    env = dict(os.environ, LOGIN_USER=user or "", LOGIN_PASSWORD=os.environ.get("LOADTEST_PASSWORD", ""))
    started = time.time()
    result = subprocess.run(cmd, env=env, check=False)
    finished = time.time()
    # 99: a threshold of loadtest.js was crossed. That is a result, not an error
    if result.returncode not in (0, 99):
        die(f"k6 ended with exit code {result.returncode}")
    try:
        summary = json.loads((RESULTS / summary_name).read_text())["metrics"]
    except (OSError, ValueError, KeyError) as err:
        die(f"no k6 summary in {RESULTS / summary_name}: {err}")
    return started, finished, summary


def measure(vus, started, finished, summary):
    window = max(30, int(finished - started) - 10)  # the run without its first seconds
    at = finished
    rng = f"{window}s"
    row = {
        "vus": vus,
        "rps": summary["http_reqs"]["values"]["rate"],
        "p95_ms": summary["http_req_duration"]["values"]["p(95)"],
        "avg_ms": summary["http_req_duration"]["values"]["avg"],
        "errors": summary["http_req_failed"]["values"]["rate"],
        # Checks of loadtest.js that failed, e.g. a sign-in that did not work
        "failed_checks": 1 - summary.get("checks", {}).get("values", {}).get("rate", 1),
        "servers": prom('count(up{job="tomcat"} == 1)', at),
        "app_cpu": prom(f'sum(rate(process_cpu_seconds_total{{job="tomcat"}}[{rng}]))', at),
        "host_cpu": prom(f'1 - avg(rate(node_cpu_seconds_total{{job="node", mode="idle"}}[{rng}]))', at),
        "host_mem": prom(f"max_over_time(travelagency:host_memory_used:ratio[{rng}])", at),
        "app_mem_max": prom(f'max(max_over_time(container_memory_working_set_bytes{{job="cadvisor", name=~"travelagency-tf-app.*"}}[{rng}]))', at),
        "threads_busy_max": prom(f'max(max_over_time(tomcat_threadpool_currentthreadsbusy{{job="tomcat"}}[{rng}]))', at),
        "db_conn_max": prom(f"max_over_time(mysql_global_status_threads_connected[{rng}])", at),
    }
    tomcat_rps = prom(f'sum(rate(tomcat_requestcount_total{{job="tomcat"}}[{rng}]))', at)
    row["cpu_per_request"] = (row["app_cpu"] / tomcat_rps) if row["app_cpu"] and tomcat_rps else None
    row["meets_slo"] = row["p95_ms"] < SLO_P95_MS and row["errors"] < SLO_ERRORS
    return row


def fmt(value, kind):
    if value is None:
        return "n/a"
    return {
        "int": f"{value:.0f}", "rps": f"{value:.1f}", "ms": f"{value:.0f}", "pct": f"{value * 100:.1f} %",
        "cores": f"{value:.2f}", "mb": f"{value / 2**20:.0f} MB", "cpu_s": f"{value * 1000:.1f} ms",
    }[kind]


def table(rows):
    head = ("| VUs | Req/s | p95 | Avg | Errors | Failed checks | Servers | CPU of servers (cores) | Host CPU "
            "| Host memory (max) | Memory of one server (max) | Busy threads (max) | DB connections (max) "
            "| CPU per request | Meets SLO |")
    sep = "|" + "---|" * 15
    lines = [head, sep]
    for r in rows:
        lines.append("| " + " | ".join([
            str(r["vus"]), fmt(r["rps"], "rps"), fmt(r["p95_ms"], "ms") + " ms", fmt(r["avg_ms"], "ms") + " ms",
            fmt(r["errors"], "pct"), fmt(r["failed_checks"], "pct"), fmt(r["servers"], "int"), fmt(r["app_cpu"], "cores"), fmt(r["host_cpu"], "pct"),
            fmt(r["host_mem"], "pct"), fmt(r["app_mem_max"], "mb"), fmt(r["threads_busy_max"], "int"),
            fmt(r["db_conn_max"], "int"), fmt(r["cpu_per_request"], "cpu_s"), "yes" if r["meets_slo"] else "no",
        ]) + " |")
    return "\n".join(lines)


def estimate(rows, at):
    cores = prom('count(count by (cpu) (node_cpu_seconds_total{job="node"}))', at)
    mem_total = prom('node_memory_MemTotal_bytes{job="node"}', at)
    mem_avail_min = prom('min_over_time(node_memory_MemAvailable_bytes{job="node"}[30m])', at)
    per_request = sorted(r["cpu_per_request"] for r in rows if r["cpu_per_request"])
    good = [r for r in rows if r["meets_slo"]]
    lines = ["## Estimate", ""]
    if per_request and cores:
        cpu_req = per_request[len(per_request) // 2]
        # CPU the rest of the VM (Jenkins, Nexus, SonarQube, MySQL, monitoring) used in the heaviest run
        heavy = max(rows, key=lambda r: r["rps"])
        others = max(0.0, (heavy["host_cpu"] or 0) * cores - (heavy["app_cpu"] or 0))
        free_cores = max(0.0, cores * TARGET_CPU - others)
        lines += [
            f"- CPU per request (median of the runs): {cpu_req * 1000:.1f} ms",
            f"- Host: {cores:.0f} CPU cores; the other services used {others:.2f} cores in the heaviest run",
            f"- At {TARGET_CPU:.0%} of the host CPU, the application servers can use {free_cores:.2f} cores: "
            f"about **{free_cores / cpu_req:.0f} requests per second** on this VM, whatever the number of servers",
        ]
    if good:
        best = max(good, key=lambda r: r["rps"])
        lines.append(f"- Highest measured load that met the SLO (p95 < {SLO_P95_MS} ms, errors < {SLO_ERRORS:.0%}): "
                     f"**{best['rps']:.1f} requests per second** with {fmt(best['servers'], 'int')} server(s), "
                     f"{best['vus']} VUs")
    bad = [r for r in rows if not r["meets_slo"]]
    if bad:
        first = min(bad, key=lambda r: r["vus"])
        lines.append(f"- The SLO was missed from {first['vus']} VUs on (p95 {first['p95_ms']:.0f} ms, "
                     f"errors {first['errors']:.1%})")
    mem_server = max((r["app_mem_max"] or 0) for r in rows)
    if mem_total and mem_avail_min and mem_server:
        lines += [
            f"- Memory: one application server needs up to {mem_server / 2**20:.0f} MB; the VM had at least "
            f"{mem_avail_min / 2**20:.0f} MB of {mem_total / 2**30:.1f} GB free in the last 30 minutes, "
            f"room for about **{int(mem_avail_min * 0.8 // mem_server)} more server(s)** (keeping 20 % free)",
        ]
    lines += ["", "Scaling: Jenkins → Build with Parameters → APP_REPLICAS. Prometheus finds new servers by "
              "the alias app, the dashboards show them at once."]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--vus", default="10,25,50", help="numbers of virtual users, one run each (default 10,25,50)")
    parser.add_argument("--duration", default="2m", help="length of each run (default 2m)")
    parser.add_argument("--user", default="", help="sign in as this user (password: LOADTEST_PASSWORD or asked)")
    parser.add_argument("--pause", type=int, default=30, help="seconds between the runs (default 30)")
    args = parser.parse_args()
    try:
        levels = [int(v) for v in args.vus.split(",") if v.strip()]
    except ValueError:
        die("--vus: numbers separated by commas, e.g. 10,25,50")
    if not levels or min(levels) < 1:
        die("--vus: at least one number from 1")
    seconds(args.duration)
    if args.user and not os.environ.get("LOADTEST_PASSWORD"):
        os.environ["LOADTEST_PASSWORD"] = getpass.getpass(f"Password of {args.user}: ")

    prefix = "172.31.0"
    env_file = HERE / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if line.startswith("TF_NET_PREFIX="):
                prefix = line.split("=", 1)[1].strip()
    if prom("up", time.time()) is None:
        die("Prometheus has no data: run setup.py first")

    RESULTS.mkdir(exist_ok=True)
    rows = []
    for i, vus in enumerate(levels):
        if i:
            print(f"Pause {args.pause} s …")
            time.sleep(args.pause)
        print(f"\n=== {vus} virtual users, {args.duration} " + ("(sign in as " + args.user + ")" if args.user else "(login page)"))
        started, finished, summary = run_k6(vus, args.duration, args.user, prefix)
        # Let Prometheus scrape the end of the run
        time.sleep(20)
        row = measure(vus, started, finished, summary)
        rows.append(row)
        print(f"    {row['rps']:.1f} req/s, p95 {row['p95_ms']:.0f} ms, errors {row['errors']:.2%}, "
              f"servers' CPU {fmt(row['app_cpu'], 'cores')} cores")
        if row["failed_checks"] > 0.01:
            print(f"    WARNING: {row['failed_checks']:.0%} of the checks failed"
                  + (" (is the user name and password right?)" if args.user else ""))

    report = "\n".join([
        f"# Load test {datetime.now():%d.%m.%Y %H:%M}",
        "",
        f"Target: {TARGET} (Nginx and the application servers). Each run: {args.duration}, "
        f"k6 {K6_IMAGE.split(':')[1]}, " + (f"login page and sign-in as {args.user}" if args.user else "login page") + ".",
        f"SLO: 95 % of requests under {SLO_P95_MS} ms, less than {SLO_ERRORS:.0%} errors.",
        "",
        table(rows),
        "",
        estimate(rows, time.time()),
        "",
    ])
    out = RESULTS / f"capacity-{datetime.now():%Y%m%d-%H%M}.md"
    out.write_text(report, encoding="utf-8")
    print("\n" + report)
    print(f"Saved: {out}")


if __name__ == "__main__":
    main()
