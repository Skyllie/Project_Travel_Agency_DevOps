#!/usr/bin/env bash
# Checks the whole TravelAgency DevOps project for security problems and hardcoded settings.
#
#   bash scripts/check-project.sh [options]
#
# Parts of the check
#   history   every commit of every branch: secrets (gitleaks), files that must never be
#             committed (.env, Terraform state, keys), commit authors, co-author lines
#   files     every branch: passwords, keys and settings written into the code, .gitignore,
#             Dockerfiles (hadolint), Compose files, shell scripts (shellcheck), Nginx
#             configs (nginx -t), Terraform (fmt, validate), Ansible (vault, ansible-lint)
#   app       the Java code, its settings, demo data and Maven dependencies (trivy)
#   image     the application image: user, secrets in ENV, health check, vulnerabilities (trivy)
#   runtime   containers on this machine, the site, Jenkins and the local .env files
#
# Options
#   --branch NAME   check only this branch (can be repeated); default: all branches on origin
#   --skip LIST     parts to skip, comma-separated: history,files,app,image,runtime
#   --build         build the application image first and check it (takes a few minutes)
#   --offline       no downloads: no vulnerability scans, no terraform validate,
#                   only scanners that are already installed
#   --no-fetch      do not run "git fetch" first
#   --repo DIR      the clone to check (default: the clone this script is in, else the
#                   current directory)
#   --report FILE   where to save the report (default: /tmp/travelagency-check-<time>.txt)
#   -h, --help      show this help
#
# Result: PASS - fine, WARN - worth fixing or a known risk, FAIL - must be fixed,
#         SKIP - could not be checked here, INFO - for reference.
# Exit code: 0 - no FAIL, 1 - at least one FAIL, 2 - the check could not run.
#
# Committed files are checked: a branch's latest commit on origin, or your local commit
# when it is newer. Files that are not committed yet are not checked.
# Secrets that are found are never printed: only the file, the line and the kind of secret.
#
# The script changes nothing in your branches, files or running containers. It does run
# "git fetch" (updates origin/* in this clone), may pull nginx:1.28-alpine for nginx -t,
# --build adds the image travelagency:check, and ansible-lint may install the Ansible
# collections from requirements.yml. Scanners that are not installed are downloaded once
# to ~/.cache/travelagency-check/bin (about 250 MB) and checked against the SHA-256 sums
# below; trivy keeps its vulnerability database in ~/.cache/trivy (1 GB or more).

set -uo pipefail
umask 077

EXPECTED_BRANCHES=(main manual-setup ansible docker docker-load-balancer terraform jenkins)
PARTS=(history files app image runtime)
APP_IMAGES=(travelagency:latest travelagency:local)   # Jenkins tags :latest, Compose and Terraform build :local
NGINX_IMAGE="nginx:1.28-alpine"

# name|version|download URL (Linux x86_64)|SHA-256 of the download|file inside the archive
TOOL_SPECS=(
  "gitleaks|8.30.0|https://github.com/gitleaks/gitleaks/releases/download/v8.30.0/gitleaks_8.30.0_linux_x64.tar.gz|79a3ab579b53f71efd634f3aaf7e04a0fa0cf206b7ed434638d1547a2470a66e|gitleaks"
  "trivy|0.75.0|https://github.com/aquasecurity/trivy/releases/download/v0.75.0/trivy_0.75.0_Linux-64bit.tar.gz|c6e65abddb348e25f10549df887045629cf28cc72453cd1c63acb717316b3f3f|trivy"
  "hadolint|2.15.0|https://github.com/hadolint/hadolint/releases/download/v2.15.0/hadolint-linux-x86_64|eb8eb4dd06a068cce65cb84743fba69f09ed12a36ff13d58f9af090d6d696970|"
  "shellcheck|0.11.0|https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz|8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198|shellcheck-v0.11.0/shellcheck"
)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
TOOLS_DIR="$CACHE/travelagency-check/bin"

# ---------------------------------------------------------------- options

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; }
need_arg() { [[ $2 -ge 2 ]] || { echo "$1 needs a value (see --help)" >&2; exit 2; }; }

ONLY_BRANCHES=()
SKIP_LIST=","
BUILD=0
OFFLINE=0
FETCH=1
REPO=""
REPORT="/tmp/travelagency-check-$(date +%Y%m%d-%H%M%S).txt"

while (($#)); do
  case $1 in
    --branch)   need_arg "$1" $#; ONLY_BRANCHES+=("$2"); shift ;;
    --skip)     need_arg "$1" $#; SKIP_LIST+="$2,"; shift ;;
    --build)    BUILD=1 ;;
    --offline)  OFFLINE=1 ;;
    --no-fetch) FETCH=0 ;;
    --repo)     need_arg "$1" $#; REPO=$2; shift ;;
    --report)   need_arg "$1" $#; REPORT=$2; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

for p in ${SKIP_LIST//,/ }; do
  [[ " ${PARTS[*]} " == *" $p "* ]] || { echo "Unknown part in --skip: $p (parts: ${PARTS[*]})" >&2; exit 2; }
done
wanted() { [[ $SKIP_LIST != *",$1,"* ]]; }

for cmd in git python3 tar curl sha256sum timeout; do
  command -v "$cmd" >/dev/null || { echo "Needs $cmd" >&2; exit 2; }
done
if [[ -n $REPO ]]; then
  REPO=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || { echo "--repo: not a git clone" >&2; exit 2; }
else
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  REPO=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) \
    || REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "Run the script inside a clone of the repository, or use --repo DIR" >&2; exit 2; }
fi
: > "$REPORT" || { echo "Cannot write the report to $REPORT" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/travelagency-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- output

if [[ -t 1 ]]; then
  C_PASS=$'\e[32m' C_WARN=$'\e[33m' C_FAIL=$'\e[31m' C_SKIP=$'\e[90m' C_INFO=$'\e[36m' C_HEAD=$'\e[1m' C_OFF=$'\e[0m'
else
  C_PASS="" C_WARN="" C_FAIL="" C_SKIP="" C_INFO="" C_HEAD="" C_OFF=""
fi
N_PASS=0 N_WARN=0 N_FAIL=0 N_SKIP=0
SUMMARY_FAIL=() SUMMARY_WARN=()
CONTEXT="" TOPIC=""

head1() {
  CONTEXT=$1 TOPIC=""
  printf '\n%s== %s ==%s\n' "$C_HEAD" "$1" "$C_OFF"
  printf '\n== %s ==\n' "$1" >> "$REPORT"
}

say() { # LEVEL message
  local level=$1 color
  shift
  case $level in
    PASS) N_PASS=$((N_PASS + 1)); color=$C_PASS ;;
    WARN) N_WARN=$((N_WARN + 1)); color=$C_WARN; SUMMARY_WARN+=("[${TOPIC:-$CONTEXT}] $*") ;;
    FAIL) N_FAIL=$((N_FAIL + 1)); color=$C_FAIL; SUMMARY_FAIL+=("[${TOPIC:-$CONTEXT}] $*") ;;
    SKIP) N_SKIP=$((N_SKIP + 1)); color=$C_SKIP ;;
    *)    level=INFO; color=$C_INFO ;;
  esac
  printf '  %s%-4s%s %s\n' "$color" "$level" "$C_OFF" "$*"
  printf '  %-4s %s\n' "$level" "$*" >> "$REPORT"
}

detail() { # extra lines under a result, indented
  local line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    printf '         %s\n' "$line"
    printf '         %s\n' "$line" >> "$REPORT"
  done
}

# Lines "LEVEL<TAB>topic<TAB>message" from the Python helper; a new topic starts a sub-heading.
# Runs in this shell (not in a pipe), so the counts in say() are kept.
relay() {
  local level topic msg last=""
  while IFS=$'\t' read -r level topic msg; do
    [[ -n $level ]] || continue
    if [[ $level == DETAIL ]]; then printf '%s\n' "$msg" | detail; continue; fi
    if [[ $topic != "$last" && $topic != "-" ]]; then
      printf '  %s%s%s\n' "$C_HEAD" "$topic" "$C_OFF"
      printf '  %s\n' "$topic" >> "$REPORT"
      last=$topic TOPIC=$topic
    fi
    say "$level" "$msg"
  done
  TOPIC=""
}

# Runs the Python helper and shows its results; a crash of the helper is a FAIL, not a silent pass
pyrelay() {
  local rc
  python3 "$WORK/helper.py" "$@" > "$WORK/helper.out" 2> "$WORK/helper.err" < /dev/null
  rc=$?
  relay < "$WORK/helper.out"
  if ((rc != 0)); then
    say FAIL "internal error in the check '$1', its results are incomplete: $(tail -1 "$WORK/helper.err")"
  fi
}

# ---------------------------------------------------------------- helpers

have_docker() { command -v docker >/dev/null && docker info >/dev/null 2>&1; }

declare -A REF
LOCAL_AHEAD=()
resolve_ref() { # branch -> REF[branch]: origin, or the local branch when it has commits origin does not
  local b=$1 o l
  o=$(git -C "$REPO" rev-parse -q --verify "refs/remotes/origin/$b^{commit}" 2>/dev/null)
  l=$(git -C "$REPO" rev-parse -q --verify "refs/heads/$b^{commit}" 2>/dev/null)
  if [[ -n $l && -n $o && $l != "$o" ]] && ! git -C "$REPO" merge-base --is-ancestor "$l" "$o" 2>/dev/null; then
    REF[$b]="refs/heads/$b"; LOCAL_AHEAD+=("$b")
  elif [[ -n $o ]]; then REF[$b]="refs/remotes/origin/$b"
  elif [[ -n $l ]]; then REF[$b]="refs/heads/$b"
  else return 1; fi
}
ref_of() { printf '%s\n' "${REF[$1]}"; }

# Branches that contain an identical file or folder are checked once: key = git object id
declare -A SEEN
first_time() { # check-name object-id -> true only the first time
  local key="$1:$2"
  [[ -z ${SEEN[$key]:-} ]] || return 1
  SEEN[$key]=1
}

branches_with() { # path object-id -> "docker, jenkins"
  local b list=() joined
  for b in "${BRANCHES[@]}"; do
    [[ $(git -C "$REPO" rev-parse -q --verify "$(ref_of "$b"):$1" 2>/dev/null) == "$2" ]] && list+=("$b")
  done
  if ((${#list[@]} == ${#BRANCHES[@]} && ${#BRANCHES[@]} > 1)); then
    echo "all branches"
  else
    joined=$(IFS=,; echo "${list[*]}")
    echo "${joined//,/, }"
  fi
}

free_mb() { df -Pk "$1" 2>/dev/null | awk 'NR == 2 {print int($4 / 1024)}'; }

# trivy keeps its vulnerability database in ~/.cache/trivy
trivy_ready() {
  local dir="$CACHE/trivy" free
  [[ -f $dir/db/trivy.db ]] && return 0
  mkdir -p "$dir" 2>/dev/null
  free=$(free_mb "$dir")
  if ((${free:-0} < 1500)); then
    say SKIP "the vulnerability database needs about 1 GB, only ${free:-?} MB free in $CACHE"
    return 1
  fi
}

download_tool() { # name url sha256 member
  local name=$1 url=$2 sum=$3 member=$4 tmp free
  mkdir -p "$TOOLS_DIR" || return 1
  free=$(free_mb "$TOOLS_DIR")
  if ((${free:-0} < 400)); then
    say SKIP "$name: only ${free:-?} MB free in $TOOLS_DIR, not downloading"
    return 1
  fi
  tmp=$(mktemp -d "$WORK/download.XXXX")
  curl -fsSL --retry 2 --connect-timeout 15 -o "$tmp/asset" "$url" 2>/dev/null || return 1
  if ! printf '%s  %s\n' "$sum" "$tmp/asset" | sha256sum -c --quiet - >/dev/null 2>&1; then
    say FAIL "$name: the download does not match the pinned SHA-256 sum, it was not used"
    return 1
  fi
  if [[ -z $member ]]; then
    install -m 0755 "$tmp/asset" "$TOOLS_DIR/$name"
  else
    tar -xf "$tmp/asset" -C "$tmp" "$member" 2>/dev/null && install -m 0755 "$tmp/$member" "$TOOLS_DIR/$name"
  fi
}

find_tool() { # name -> sets TOOL_PATH; pinned copy first, then a download, then the system one
  local name=$1 spec n ver url sum member
  TOOL_PATH=""
  for spec in "${TOOL_SPECS[@]}"; do
    IFS='|' read -r n ver url sum member <<< "$spec"
    [[ $n == "$name" ]] || continue
    if [[ -x $TOOLS_DIR/$name ]]; then TOOL_PATH="$TOOLS_DIR/$name"; return 0; fi
    if ((OFFLINE == 0)) && [[ $(uname -s)-$(uname -m) == Linux-x86_64 ]] && download_tool "$name" "$url" "$sum" "$member"; then
      TOOL_PATH="$TOOLS_DIR/$name"
      say INFO "$name $ver downloaded to $TOOLS_DIR"
      return 0
    fi
  done
  TOOL_PATH=$(command -v "$name" 2>/dev/null) || TOOL_PATH=""
  [[ -n $TOOL_PATH ]]
}

# ---------------------------------------------------------------- Python helper

cat > "$WORK/helper.py" <<'PY'
"""Checks of file contents and of scanner reports for check-project.sh.
Prints lines "LEVEL<TAB>topic<TAB>message"; "DETAIL" lines go under the previous result.
Secrets are never printed: only the file, the line and the name of the setting."""
import csv, io, json, os, re, stat, subprocess, sys
import xml.etree.ElementTree as ET
from collections import OrderedDict, defaultdict

def clean_text(s):
    return re.sub(r"[\t\r\n]+", " ", str(s))

def out(level, topic, msg):
    print(f"{level}\t{clean_text(topic)}\t{clean_text(msg)}", flush=True)

def detail(lines, limit=12):
    lines = list(lines)
    for line in lines[:limit]:
        print(f"DETAIL\t-\t{clean_text(line)}")
    if len(lines) > limit:
        print(f"DETAIL\t-\t... and {len(lines) - limit} more")

PLACEHOLDER = re.compile(r"change[-_]?me|example|your[-_ ]|xxx|\*\*\*|<[^>]*>|redacted|placeholder|dummy|not-a-real", re.I)
REFERENCE = re.compile(r"^(\$|\{\{|%\{|<|@|/|\./|\*|&|var\.|local\.|env\.|params\.|credentials\(|lookup\(|!vault|vault_)")
HCL_REF = re.compile(r"^[A-Za-z_][\w-]*(\.[\w\-\[\]\"*]+)+$")     # random_password.db.result, data.x.y
IPV4 = re.compile(r"(?<![\d.])(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?![\d.])")
COMMENT = re.compile(r"^\s*(#|//|--|;|\*|/\*|<!--)\s*")
SECRET_WORD = r"password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key"

def fixed_ips(line):
    """IPv4 addresses that depend on the environment (not 127.0.0.1 or 0.0.0.0)."""
    return [ip for ip in IPV4.findall(line) if not ip.startswith(("127.", "0.0.0.0"))]

SECRET_PATTERNS = [
    ("private key", re.compile(r"-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY")),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})")),
    ("Slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("JSON web token", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
]
URL_CRED = re.compile(r"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/:@'\"<>]+:([^\s/@'\"<>]+)@")
ASSIGN = re.compile(rf"""(?<![\w.\-${{])(?P<key>[A-Za-z0-9_.\-]*(?:{SECRET_WORD})[A-Za-z0-9_.\-]*)["']?\s*(?::|=>|=)\s*(?P<val>.*)$""", re.I)
XML_SECRET = re.compile(rf"<(?P<key>[\w.\-]*(?:{SECRET_WORD})[\w.\-]*)>(?P<val>[^<]+)</", re.I)
IDENTIFIED = re.compile(r"identified\s+(?:with\s+\S+\s+)?by\s+'([^']*)'", re.I)
DEFAULT_SECRET = re.compile(rf"\$\{{(?P<var>[\w.\-]*(?:{SECRET_WORD})[\w.\-]*)(?P<op>:-|:=|-|=|:)(?P<val>[^}}?]+)\}}", re.I)
NOT_SECRET_KEYS = {"update_password", "credentials_non_expired", "existingsecret", "secretname", "secretref"}
NOT_SECRET_ENDINGS = ("_file", "file", "variable", "id", "path", "name", "ref", "_env", "length", "ttl", "lifetime",
                      "interval", "encryption", "plugin", "mode", "policy", "type", "format", "algorithm", "expired",
                      "url", "uri", "endpoint", "header", "count", "timeout", "expiry", "expires", "prompt", "hash")
ASSIGN_TYPES = (".yml", ".yaml", ".properties", ".env", ".conf", ".cnf", ".cfg", ".ini", ".toml", ".tf", ".tfvars",
                ".hcl", ".json", ".xml", ".sh", ".bash", ".groovy", ".j2", ".template", ".tftpl", ".md", ".txt", ".example")
ASSIGN_NAMES = ("dockerfile", "jenkinsfile", ".env", "vagrantfile")

FORBIDDEN = re.compile(r"\.env$|(^|/)\.env\.(local|prod|production|dev|development|staging|test)$|\.tfstate(\.backup)?$"
                       r"|(^|/)terraform\.tfvars$|\.auto\.tfvars$|(^|/)tfplan$|\.tfplan$"
                       r"|\.(pem|key|p12|pfx|jks|keystore|kdbx|ppk)$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$"
                       r"|(^|/)\.?vault[-_]?pass(word)?(\.txt)?$|(^|/)\.git-credentials$|(^|/)\.netrc$|(^|/)\.htpasswd$")

def kind(path):
    name = path.rsplit("/", 1)[-1].lower()
    if name.endswith((".md", ".txt")) or name.startswith("readme") or name == "license":
        return "doc"
    if ".example" in name or name.endswith(".sample"):
        return "example"
    return "code"

def first_value(raw):
    raw = raw.strip()
    if not raw:
        return "", ""
    if raw[0] in "\"'":
        end = raw.find(raw[0], 1)
        return (raw[1:end], raw[end + 1:]) if end > 0 else (raw[1:], "")
    parts = re.split(r"([\s#,;)}\]])", raw, maxsplit=1)
    return parts[0], "".join(parts[1:])

def config_like(key):
    """DB_PASSWORD or db.password, not a word in a sentence."""
    return bool(re.search(r"[_.]|^[A-Z0-9]+$", key))

def is_secret_value(val, key, path):
    if not val or REFERENCE.search(val) or "${" in val or "{{" in val or val[0] in "?-`(":
        return False
    if val.lower() in {"true", "false", "null", "none", "yes", "no", "on", "off", "required", "''", '""'}:
        return False
    if re.fullmatch(r"\d+", val):           # a number is a password only under a password-like name
        return bool(re.search(r"(password|passwd|pwd|pass|secret)$", key, re.I)) and len(val) >= 4
    if path.endswith((".tf", ".tfvars", ".hcl")) and HCL_REF.match(val):
        return False
    return True

def skip_key(key):
    k = key.lower()
    return k in NOT_SECRET_KEYS or k.endswith(NOT_SECRET_ENDINGS)

def read_blobs(repo, blobs):
    data = ("\n".join(blobs) + "\n").encode()
    raw = subprocess.run(["git", "-C", repo, "cat-file", "--batch"], input=data, capture_output=True, check=True).stdout
    result, pos = {}, 0
    for blob in blobs:
        nl = raw.index(b"\n", pos)
        header = raw[pos:nl].decode().split()
        if len(header) < 3 or header[1] == "missing":
            pos = nl + 1
            continue
        size = int(header[2])
        result[blob] = raw[nl + 1:nl + 1 + size]
        pos = nl + 1 + size + 1
    return result

class Findings:
    def __init__(self):
        self.found = defaultdict(list)       # topic -> [(level, text)]
        self.always = defaultdict(list)      # topic -> PASS messages about one aspect
        self.clean = {}                      # topic -> PASS message shown when the topic has no WARN/FAIL
        self.placeholders = 0

def scan_secrets(f, where, blob, path, text):
    k = kind(path)
    low = path.lower()
    name = low.rsplit("/", 1)[-1]
    assign_ok = low.endswith(ASSIGN_TYPES) or name in ASSIGN_NAMES or name.startswith(".env")
    encrypted = text.startswith("$ANSIBLE_VAULT;")
    scanner = name == "check-project.sh"          # this script: its patterns look like assignments
    level = "FAIL" if k == "code" else "WARN"
    note = "in documentation" if k == "doc" else ("in an example file" if k == "example" else "in code")
    for no, line in enumerate(text.splitlines(), 1):
        for label, rx in SECRET_PATTERNS:
            if rx.search(line):
                f.found["Keys and tokens"].append(("FAIL", f"{label}: {where(blob, path, no)}"))
        m = URL_CRED.search(line)
        if m and is_secret_value(m.group(1), "password", path) and not PLACEHOLDER.search(m.group(1)):
            f.found["Keys and tokens"].append((level, f"user:password in a URL {note}: {where(blob, path, no)}"))
        if encrypted or scanner or not assign_ok:
            continue
        for m in DEFAULT_SECRET.finditer(line):
            val = m.group("val").strip().strip("\"'")
            if not val or "${" in val:
                continue
            if PLACEHOLDER.search(val):
                f.found["Passwords written into files"].append(("WARN", f"{m.group('var')} falls back to the example value when it is not set: {where(blob, path, no)}"))
            else:
                f.found["Passwords written into files"].append((level, f"{m.group('var')} falls back to a password written {note} when it is not set: {where(blob, path, no)}"))
        if re.search(r"\bread\s+-[a-zA-Z]*p\b", line):  # read -rsp "Password: " VAR asks for it
            continue
        cm = COMMENT.match(line)
        body = line[cm.end():] if cm else line
        candidates = []
        m = ASSIGN.search(body)
        if m:
            key = m.group("key")
            val, rest = first_value(m.group("val"))
            if cm and (not config_like(key) or rest.strip()):
                pass                              # a comment in words, not a commented-out setting
            elif k == "doc" and not config_like(key):
                pass
            elif not skip_key(key):
                candidates.append((key, val))
        for m in XML_SECRET.finditer(body):
            if not skip_key(m.group("key")):
                candidates.append((m.group("key"), m.group("val").strip()))
        for m in IDENTIFIED.finditer(body):
            candidates.append(("IDENTIFIED BY", m.group(1)))
        for key, val in candidates:
            if not is_secret_value(val, key, path):
                continue
            if PLACEHOLDER.search(val):
                f.placeholders += 1
                continue
            what = "commented-out " if cm else ""
            f.found["Passwords written into files"].append((level, f"{what}{key} has a literal value {note}: {where(blob, path, no)}"))

def check_file(f, where, blob, path, text):
    name = path.rsplit("/", 1)[-1]
    lines = text.splitlines()

    # application settings come from the environment
    if name == "application.properties":
        topic = "Application settings"
        props = {}
        for line in lines:
            m = re.match(r"\s*([\w.\-]+)\s*[:=]\s*(.*)$", line)
            if m and not line.lstrip().startswith("#"):
                props[m.group(1)] = m.group(2).strip()
        keys = ("db.url", "db.username", "db.password")
        present = [k for k in keys if k in props]
        bad = [k for k in present if "${" not in props[k]]
        with_default = [k for k in present if re.search(r"\$\{[\w.\-]+:[^}]+\}", props[k])]
        if bad:
            f.found[topic].append(("FAIL", f"{', '.join(bad)} written into {where(blob, path)} instead of ${{...}} variables"))
        if with_default:
            f.found[topic].append(("WARN", f"{', '.join(with_default)} have a default value used when the variable is missing: {where(blob, path)}"))
        if not present:
            f.found[topic].append(("INFO", f"no db.url, db.username or db.password in {where(blob, path)}"))
        elif not bad and not with_default:
            f.always[topic].append(f"{', '.join(present)} come from environment variables: {where(blob, path)}")
        if props.get("hibernate.show_sql", "").lower() == "true":
            f.found["Application security"].append(("WARN", f"hibernate.show_sql: true writes every SQL statement to the log: {where(blob, path)}"))

    # Java code: addresses, passwords, unsafe security settings
    if path.endswith(".java") and "/src/main/java/" in "/" + path:
        f.clean["Java code"] = "no database address, host names or passwords written into the Java code"
        for no, line in enumerate(lines, 1):
            if COMMENT.match(line):
                continue
            if '"jdbc:' in line:
                f.found["Java code"].append(("FAIL", f"JDBC URL written into the code: {where(blob, path, no)}"))
            for lit in re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', line):
                if "localhost" in lit or "127.0.0.1" in lit:
                    f.found["Java code"].append(("WARN", f"host name in a string: {where(blob, path, no)}"))
                elif fixed_ips(lit):
                    f.found["Java code"].append(("WARN", f"IP address in a string: {where(blob, path, no)}"))
            if re.search(r'(?i)\b(?:password|passwd|pwd|secret)\w*\s*=\s*"[^"]+"', line) or re.search(r'setPassword\(\s*"', line):
                f.found["Java code"].append(("FAIL", f"password written into the code: {where(blob, path, no)}"))
            if re.search(r"csrf\(\)\s*\.disable\(\)|csrf\(\s*\w+\s*->\s*\w+\.disable\(\)\s*\)", line):
                f.found["Application security"].append(("WARN", f"CSRF protection is turned off, forms can be sent from other sites: {where(blob, path, no)}"))
            if re.search(r"NoOpPasswordEncoder|\{noop\}", line):
                f.found["Application security"].append(("FAIL", f"passwords are not hashed (NoOpPasswordEncoder): {where(blob, path, no)}"))
            if re.search(r'MessageDigest\.getInstance\(\s*"(?:MD5|SHA-?1)"', line):
                f.found["Application security"].append(("WARN", f"MD5/SHA-1 is too weak for passwords: {where(blob, path, no)}"))
        pos = 0
        for stmt in text.split(";"):              # queries built by joining strings with variables
            start, pos = pos, pos + len(stmt) + 1
            if not re.search(r"create(?:Native|SQL)?Query\s*\(|\b(?:hql|sql|query)\w*\s*=", stmt, re.I):
                continue
            for m in re.finditer(r'"\s*\+\s*([A-Za-z_][\w.]*)', stmt):
                token = m.group(1)
                if token.startswith(("get", "this.get")) or token.isupper():
                    continue
                no = text[:start + m.start()].count("\n") + 1
                f.found["Application security"].append(("WARN", f"query built by adding the variable {token} to the text (risk of injection): {where(blob, path, no)}"))
        if "BCryptPasswordEncoder" in text and "passwords are hashed with BCrypt" not in f.always["Application security"]:
            f.always["Application security"].append("passwords are hashed with BCrypt")
        n_trace = sum(1 for line in lines if "printStackTrace()" in line)
        if n_trace:
            f.found["Application security"].append(("INFO", f"printStackTrace() {n_trace} times: errors go to the console, not to a log: {where(blob, path)}"))

    # demo data with plain-text passwords
    if path.endswith(".sql"):
        for m in re.finditer(r"INSERT\s+INTO\s+`?(\w+)`?\s*\(([^)]*)\)\s*VALUES\s*(.*?);", text, re.I | re.S):
            cols = [c.strip().strip("`").lower() for c in m.group(2).split(",")]
            if "password" not in cols:
                continue
            idx, plain, rows = cols.index("password"), 0, 0
            for tup in re.findall(r"\(((?:[^()']|'[^']*'|\([^()]*\))*)\)", m.group(3)):
                parsed = list(csv.reader(io.StringIO(tup), quotechar="'", skipinitialspace=True))
                if not parsed or len(parsed[0]) <= idx:
                    continue                      # NOW() and other function calls
                rows += 1
                if not re.match(r"^(\$2[aby]\$|\{bcrypt\})", parsed[0][idx].strip()):
                    plain += 1
            if plain:
                f.found["Demo data"].append(("WARN", f"demo users with plain-text passwords in table {m.group(1)}: {plain} in {where(blob, path)}"))
            elif rows:
                f.always["Demo data"].append(f"demo users have BCrypt hashes, not plain passwords: {where(blob, path)}")

    # Maven: the same dependency declared several times
    if name == "pom.xml":
        try:
            root = ET.fromstring(text)
            ns = {"m": root.tag[1:root.tag.index("}")]} if root.tag.startswith("{") else {}
            pre = "m:" if ns else ""
            seen = defaultdict(list)
            for dep in root.findall(f"{pre}dependencies/{pre}dependency", ns):
                g = (dep.findtext(f"{pre}groupId", "", ns) or "").strip()
                a = (dep.findtext(f"{pre}artifactId", "", ns) or "").strip()
                v = (dep.findtext(f"{pre}version", "", ns) or "").strip()
                seen[f"{g}:{a}"].append(v or "?")
            dups = {k: v for k, v in seen.items() if len(v) > 1}
            if dups:
                f.found["Maven"].append(("WARN", f"{len(dups)} dependencies are declared more than once, Maven uses only one of them: {where(blob, path)}"))
                f.found["Maven"].append(("DETAILS", [f"{k}: {', '.join(v)}" for k, v in dups.items()]))
            else:
                f.clean["Maven"] = "every dependency is declared once (pom.xml)"
        except ET.ParseError as e:
            f.found["Maven"].append(("FAIL", f"pom.xml is not valid XML ({e}): {where(blob, path)}"))

    # Terraform: secret variables, fixed addresses
    if path.endswith(".tf"):
        for m in re.finditer(r'^variable\s+"(\w+)"\s*\{(.*?)^\}', text, re.M | re.S):
            vname, body = m.group(1), m.group(2)
            if re.search(r"password|secret|token", vname, re.I):
                if not re.search(r"^\s*sensitive\s*=\s*true", body, re.M):
                    f.found["Terraform variables"].append(("FAIL", f'variable "{vname}" is not marked sensitive: {where(blob, path)}'))
                elif re.search(r"^\s*default\s*=", body, re.M):
                    f.found["Terraform variables"].append(("FAIL", f'variable "{vname}" has a default password: {where(blob, path)}'))
                else:
                    f.always["Terraform variables"].append(f'variable "{vname}" is sensitive and has no default value: {where(blob, path)}')
        f.clean["Terraform addresses"] = "no fixed IPs in the Terraform code: addresses are computed from var.subnet"
        if name != "variables.tf":
            for no, line in enumerate(lines, 1):
                if not COMMENT.match(line) and fixed_ips(line):
                    f.found["Terraform addresses"].append(("WARN", f"fixed IP address instead of a variable: {where(blob, path, no)}"))

    # passwords on a command line
    if kind(path) == "code" and re.search(r"\.(ya?ml|tf|sh)$|(^|/)(Dockerfile|Jenkinsfile)$", path):
        f.clean["Passwords on a command line"] = "no passwords passed as command arguments"
        for no, line in enumerate(lines, 1):
            if re.search(r"""\s-p\\?["']?\$\$?\{?\w*(?:PASSWORD|PASS|PWD)|--password[= ]\\?["']?\$""", line):
                f.found["Passwords on a command line"].append(("WARN", f"password passed as a command argument, visible in 'ps' while it runs: {where(blob, path, no)}"))

    # Jenkins pipeline
    if name == "Jenkinsfile":
        for no, line in enumerate(lines, 1):
            if re.search(r"\becho\b.*\$\{?\w*(?:PASSWORD|SECRET|TOKEN)", line, re.I):
                f.found["Jenkins pipeline"].append(("FAIL", f"a secret is printed to the build log: {where(blob, path, no)}"))
            if not COMMENT.match(line) and fixed_ips(line):
                f.found["Jenkins pipeline"].append(("WARN", f"fixed IP address: {where(blob, path, no)}"))
        if re.search(r"(?i)password|secret", text):
            if "withCredentials" in text or "credentials(" in text:
                f.always["Jenkins pipeline"].append(f"passwords come from Jenkins credentials (withCredentials), not from the code: {where(blob, path)}")
            else:
                f.found["Jenkins pipeline"].append(("WARN", f"uses passwords without withCredentials: {where(blob, path)}"))

    # Ansible vault
    if re.search(r"(^|/)vault\.ya?ml$", path):
        if text.startswith("$ANSIBLE_VAULT;"):
            f.always["Ansible"].append(f"the vault file is encrypted with ansible-vault: {where(blob, path)}")
        else:
            f.found["Ansible"].append(("FAIL", f"vault file is not encrypted: {where(blob, path)}"))

    # Nginx: version in headers, open status page
    if re.search(r"\bserver\s*\{", text) and re.search(r"\.(conf|template|tftpl)$", path):
        if not re.search(r"^\s*server_tokens\s+off\s*;", text, re.M):
            f.found["Nginx"].append(("WARN", f"no 'server_tokens off': every answer shows the Nginx version: {where(blob, path)}"))
        for m in re.finditer(r"location\s*[=~^]*\s*(\S+)\s*\{([^}]*)\}", text):
            if "stub_status" in m.group(2) and not re.search(r"\b(allow|deny)\b", m.group(2)):
                f.found["Nginx"].append(("WARN", f"status page {m.group(1)} is open to everyone: {where(blob, path)}"))
        f.clean["Nginx"] = "Nginx hides its version and protects the status page"

    # Dockerfiles
    if re.search(r"(^|/)Dockerfile[^/]*$", path):
        stages = re.split(r"(?im)^\s*FROM\s+", text)[1:]
        last = stages[-1] if stages else ""
        users = re.findall(r"(?im)^\s*USER\s+(\S+)", last)
        if not users or users[-1].split(":")[0] in ("root", "0"):
            f.found["Dockerfiles"].append(("FAIL", f"the container runs as root (no USER in the last stage): {where(blob, path)}"))
        aliases = {a.lower() for a in re.findall(r"(?im)^\s*FROM\s+\S+\s+AS\s+(\S+)", text)}
        for img in re.findall(r"(?im)^\s*FROM\s+(?:--\S+\s+)*(\S+)", text):
            base = img.split("@")[0]
            if "$" in base or base.lower() in aliases or base.lower() == "scratch":
                continue
            if ":" not in base.rsplit("/", 1)[-1] or base.endswith(":latest"):
                f.found["Dockerfiles"].append(("WARN", f"base image {img} has no fixed version: {where(blob, path)}"))
        if not re.search(r"(?im)^\s*HEALTHCHECK\s", text):
            f.found["Dockerfiles"].append(("WARN", f"no HEALTHCHECK, Docker cannot tell when the service is broken: {where(blob, path)}"))
        if re.search(r"(?i)curl[^|\n]*\|\s*(?:ba|z)?sh\b|wget[^|\n]*\|\s*(?:ba|z)?sh\b", text):
            f.found["Dockerfiles"].append(("WARN", f"a downloaded script is run without a check (curl | sh): {where(blob, path)}"))
        if re.search(r"(?im)^\s*ENV\s+.*(PASSWORD|SECRET|TOKEN)\w*\s*=?\s*[^$\s]", text):
            f.found["Dockerfiles"].append(("FAIL", f"a password is set with ENV, it stays in the image for everyone who pulls it: {where(blob, path)}"))
        f.clean["Dockerfiles"] = "containers run as a non-root user, base images have fixed versions, health checks are set"

def text_checks(repo, manifest, n_branches):
    files = OrderedDict()                     # blob -> {path: [branches]}
    for line in open(manifest, encoding="utf-8", errors="replace"):
        blob, branch, path = line.rstrip("\n").split("\t", 2)
        files.setdefault(blob, OrderedDict()).setdefault(path, []).append(branch)
    contents = read_blobs(repo, list(files))

    def where(blob, path, lineno=None):
        branches = files[blob][path]
        b = "all branches" if len(branches) == n_branches and n_branches > 1 else ", ".join(branches)
        return f"{path}{':' + str(lineno) if lineno else ''} ({b})"

    f = Findings()
    texts = []
    for blob, paths in files.items():
        data = contents.get(blob)
        if data is None or len(data) > 2_000_000 or b"\0" in data[:8192]:
            continue
        text = data.decode("utf-8", errors="replace")
        for path in paths:
            texts.append((blob, path, text))

    for blob, path, text in texts:
        for check in (scan_secrets, check_file):
            try:
                check(f, where, blob, path, text)
            except Exception as e:            # one odd file must not stop the other checks
                f.found["Files that could not be checked"].append(("WARN", f"{where(blob, path)}: {type(e).__name__}: {e}"))
    f.clean["Keys and tokens"] = "no private keys, cloud or GitHub tokens, no passwords inside URLs"
    f.clean["Passwords written into files"] = (f"no passwords with real values; {f.placeholders} example values are placeholders"
                                               if f.placeholders else "no passwords with real values")

    ip_files = sorted({where(b, p) for b, p, t in texts
                       if kind(p) == "code" and re.search(r"\.(ya?ml|conf|tf|tftpl|template)$|Jenkinsfile|Vagrantfile", p)
                       and any(fixed_ips(l) for l in t.splitlines() if not COMMENT.match(l))})
    if ip_files:
        f.found["Fixed IP addresses"].append(("INFO", f"{len(ip_files)} config files use fixed IPs (container networks, VMs); they are listed so you can check each one"))
        f.found["Fixed IP addresses"].append(("DETAILS", ip_files))

    order = ["Keys and tokens", "Passwords written into files", "Application settings", "Java code", "Application security",
             "Demo data", "Maven", "Terraform variables", "Terraform addresses", "Passwords on a command line",
             "Jenkins pipeline", "Ansible", "Nginx", "Dockerfiles", "Fixed IP addresses", "Files that could not be checked"]
    for topic in order:
        items = f.found.get(topic, [])
        for msg in f.always.get(topic, []):
            out("PASS", topic, msg)
        if not any(i[0] in ("FAIL", "WARN") for i in items) and topic in f.clean:
            out("PASS", topic, f.clean[topic])
        for level, msg in items:
            if level == "DETAILS":
                detail(msg, limit=40)
            else:
                out(level, topic, msg)

def forbidden_files(path):
    topic = "-"
    hits = OrderedDict()
    for line in open(path, encoding="utf-8", errors="replace"):
        commit, _, fpath = line.rstrip("\n").partition("\t")
        if fpath and FORBIDDEN.search(fpath):
            hits.setdefault(fpath, []).append(commit)
    if hits:
        out("FAIL", topic, f"files with secrets were committed at some point ({len(hits)}); they stay in the history, so change those secrets")
        detail([f"{p} (commit {', '.join(c[:5])})" for p, c in hits.items()], limit=20)
    else:
        out("PASS", topic, "no .env, Terraform state, tfvars, keys or vault password files in any commit")

DB_PORTS = ("3306", "33060", "5432", "6379", "27017")
RISKY_MOUNTS = {"/": "FAIL", "/etc": "WARN", "/root": "WARN", "/home": "WARN", "/var/run": "WARN", "/run": "WARN",
                "/var/lib/docker": "WARN", "/proc": "WARN", "/sys": "WARN", "/dev": "WARN", "/boot": "WARN"}

def mount_findings(name, source):
    source = str(source).rstrip("/") or "/"
    if source.endswith("docker.sock"):
        return [("WARN", f"{name}: has the Docker socket, so it controls Docker on the host (same as root); acceptable for a lab Jenkins, not for production")]
    if source in RISKY_MOUNTS:
        return [(RISKY_MOUNTS[source], f"{name}: the host folder {source} is mounted into the container")]
    return []

def compose_checks(path, label):
    data = json.load(open(path))
    topic = f"Compose: {label}"
    issues = 0
    def report(level, msg):
        nonlocal issues
        out(level, topic, msg)
        issues += level in ("FAIL", "WARN")
    for name, svc in (data.get("services") or {}).items():
        if svc.get("privileged"):
            report("FAIL", f"{name}: privileged container (full access to the host)")
        for key in ("network_mode", "pid", "ipc"):
            if svc.get(key) == "host":
                report("WARN", f"{name}: {key}: host (shares it with the host)")
        if svc.get("cap_add"):
            report("WARN", f"{name}: extra capabilities {', '.join(svc['cap_add'])}")
        for opt in svc.get("security_opt") or []:
            if "unconfined" in str(opt):
                report("WARN", f"{name}: security_opt {opt} turns off a protection")
        for vol in svc.get("volumes") or []:
            if vol.get("type", "bind") == "bind":
                for level, msg in mount_findings(name, vol.get("source", "")):
                    report(level, msg)
        for p in svc.get("ports") or []:
            target, pub, ip = str(p.get("target")), str(p.get("published", "")), p.get("host_ip") or ""
            if not pub:
                continue
            if target in DB_PORTS and ip in ("", "0.0.0.0", "::"):
                report("FAIL", f"{name}: database port {target} is open on all interfaces of the host ({pub})")
            else:
                out("INFO", topic, f"{name}: port {pub} -> {target} on {ip or 'all interfaces'}")
        image = svc.get("image", "")
        if image and "build" not in svc and (":" not in image.rsplit("/", 1)[-1] or image.endswith(":latest")):
            report("WARN", f"{name}: image {image} has no fixed version")
        if "build" not in svc and ("healthcheck" not in svc or svc["healthcheck"].get("disable")):
            report("WARN", f"{name}: no health check")
        if str(svc.get("user", "")).split(":")[0] in ("root", "0"):
            report("WARN", f"{name}: runs as root")
    if not issues:
        out("PASS", topic, "no privileged containers or host folders, no open database port, versions fixed, health checks set")

def hadolint_report(path, label):
    topic = f"hadolint: {label}"
    items = json.load(open(path)) if os.path.getsize(path) else []
    by = defaultdict(list)
    for i in items:
        by[i.get("level", "info")].append(f"line {i.get('line')}: {i.get('code')} {i.get('message')}")
    if by.get("error"):
        out("FAIL", topic, f"{len(by['error'])} errors"); detail(by["error"])
    if by.get("warning"):
        out("WARN", topic, f"{len(by['warning'])} warnings"); detail(by["warning"])
    minor = by.get("info", []) + by.get("style", [])
    if minor:
        out("INFO", topic, f"{len(minor)} style notes"); detail(minor, limit=6)
    if not by.get("error") and not by.get("warning"):
        out("PASS", topic, "no errors or warnings")

def trivy_report(path, label, what):
    topic = f"Vulnerabilities: {label}"
    data = json.load(open(path))
    vulns = {}
    for res in data.get("Results") or []:
        for v in res.get("Vulnerabilities") or []:
            vulns[(v.get("VulnerabilityID"), v.get("PkgName"))] = v
    by = defaultdict(list)
    for v in vulns.values():
        by[v.get("Severity", "UNKNOWN")].append(v)
    crit, high = by.get("CRITICAL", []), by.get("HIGH", [])
    def lines(vs):
        vs = sorted(vs, key=lambda v: (v.get("PkgName", ""), v.get("VulnerabilityID", "")))
        return [f"{v.get('VulnerabilityID')} {v.get('PkgName')} {v.get('InstalledVersion')} -> fixed in {v.get('FixedVersion') or 'no fix yet'}"
                + (f" ({v.get('Title')[:70]})" if v.get("Title") else "") for v in vs]
    if crit:
        out("FAIL", topic, f"critical vulnerabilities with a fix available in {what}: {len(crit)}"); detail(lines(crit), limit=15)
    if high:
        out("WARN", topic, f"high vulnerabilities with a fix available in {what}: {len(high)}"); detail(lines(high), limit=15)
    if not crit and not high:
        out("PASS", topic, f"no critical or high vulnerabilities with a known fix in {what}")

def gitleaks_report(path, commits):
    topic = "Secrets in the history (gitleaks)"
    items = json.load(open(path)) if os.path.getsize(path) else []
    if not items:
        out("PASS", topic, f"no secrets in the history (commits scanned: {commits})")
        return
    seen = OrderedDict()
    for i in items:
        seen.setdefault((i.get("RuleID"), i.get("File"), i.get("StartLine"), i.get("Commit")), i)
    out("FAIL", topic, f"possible secrets: {len(seen)} (commits scanned: {commits}); a secret stays in the history after it is deleted, so change it")
    detail([f"{i.get('RuleID')}: {i.get('File')}:{i.get('StartLine')} commit {str(i.get('Commit'))[:7]} {str(i.get('Date', ''))[:10]}"
            for i in seen.values()], limit=25)

def container_checks(path, app_ids):
    topic = "-"
    app_ids = set(app_ids.split())
    for c in json.load(open(path)):
        name = c.get("Name", "").lstrip("/")
        cfg, host, state = c.get("Config") or {}, c.get("HostConfig") or {}, c.get("State") or {}
        user = cfg.get("User") or ""
        is_app = (cfg.get("Image", "").startswith("travelagency") or c.get("Image") in app_ids
                  or re.search(r"(^|[-_])app\d*(-\d+)?$", name))
        health = (state.get("Health") or {}).get("Status", "")
        problems = 0
        def report(level, msg):
            nonlocal problems
            out(level, topic, msg)
            problems += 1
        if host.get("Privileged"):
            report("FAIL", f"{name}: privileged (full access to the host)")
        for key, label in (("NetworkMode", "network"), ("PidMode", "pid"), ("IpcMode", "ipc")):
            if host.get(key) == "host":
                report("WARN", f"{name}: shares the host {label}")
        if host.get("CapAdd"):
            report("WARN", f"{name}: extra capabilities {', '.join(host['CapAdd'])}")
        for opt in host.get("SecurityOpt") or []:
            if "unconfined" in str(opt):
                report("WARN", f"{name}: {opt} turns off a protection")
        for port, binds in (host.get("PortBindings") or {}).items():
            if port.split("/")[0] in DB_PORTS and any((b.get("HostIp") or "") in ("", "0.0.0.0", "::") for b in binds or []):
                report("FAIL", f"{name}: database port {port} is open on all interfaces of the host")
        if health == "unhealthy":
            report("FAIL", f"{name}: unhealthy")
        if is_app and user.split(":")[0] in ("", "root", "0"):
            report("FAIL", f"{name}: the application runs as root")
        for m in c.get("Mounts") or []:
            if m.get("Type", "bind") == "bind":
                for level, msg in mount_findings(name, m.get("Source", "")):
                    report(level, msg)
        if not problems:
            out("PASS", topic, f"{name}: {health or state.get('Status', '?')}, user {user or 'image default'}, not privileged, no open database port")

def envfile_checks(paths):
    topic = "Secret files on this machine"
    for p in paths:
        try:
            st = os.stat(p)
            if st.st_mode & stat.S_IROTH:
                out("WARN", topic, f"{p} can be read by every user of this machine: chmod 600 {p}")
            if p.endswith((".tfstate", ".tfstate.backup")):
                out("INFO", topic, f"{p} holds the passwords in plain text: keep it out of Git and backups")
                continue
            weak, default, ok = [], [], 0
            for line in open(p, encoding="utf-8", errors="replace"):
                m = re.match(r'\s*(?:export\s+)?([A-Za-z_][\w.]*)\s*=\s*(.*)$', line)
                if not m or not re.search(r"password|secret|token", m.group(1), re.I) or skip_key(m.group(1)):
                    continue
                val = first_value(m.group(2))[0]
                if not val or re.search(r"change[-_]?me|example", val, re.I):
                    default.append(m.group(1))
                elif len(val) < 12:
                    weak.append(m.group(1))
                else:
                    ok += 1
            if default:
                out("FAIL", topic, f"{p}: still the example value or empty: {', '.join(default)}")
            if weak:
                out("WARN", topic, f"{p}: shorter than 12 characters: {', '.join(weak)}")
            if ok and not default and not weak:
                out("PASS", topic, f"{p}: {ok} passwords set, 12+ characters, not the example values")
        except OSError as e:
            out("SKIP", topic, f"{p}: cannot read it ({e.strerror}); run the check as the owner of the file")

if __name__ == "__main__":
    mode, args = sys.argv[1], sys.argv[2:]
    {"text": lambda: text_checks(args[0], args[1], int(args[2])),
     "forbidden": lambda: forbidden_files(args[0]),
     "compose": lambda: compose_checks(args[0], args[1]),
     "hadolint": lambda: hadolint_report(args[0], args[1]),
     "trivy": lambda: trivy_report(args[0], args[1], args[2]),
     "gitleaks": lambda: gitleaks_report(args[0], args[1]),
     "containers": lambda: container_checks(args[0], args[1]),
     "envfile": lambda: envfile_checks(args)}[mode]()
PY

# ---------------------------------------------------------------- start

printf '%sTravelAgency project check%s  %s\n' "$C_HEAD" "$C_OFF" "$(date '+%Y-%m-%d %H:%M')"
printf 'TravelAgency project check  %s\n' "$(date '+%Y-%m-%d %H:%M')" >> "$REPORT"

head1 "Repository"
origin_url=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
safe_url=$(sed -E 's#(://)[^/@]*@#\1#' <<< "$origin_url")
say INFO "clone: $REPO${safe_url:+ (origin $safe_url)}"
if [[ -n $origin_url && $origin_url != "$safe_url" ]]; then
  say WARN "the origin URL in .git/config contains a user name or token: use SSH or a credential helper instead"
fi
if ((FETCH)); then
  if git -C "$REPO" fetch --quiet --prune origin 2>/dev/null; then
    say INFO "fetched the latest branches from origin"
  else
    say SKIP "git fetch failed: checking the branches as they are in this clone"
  fi
fi
if [[ $(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null) == true ]]; then
  say WARN "this clone is shallow: the history checks see only the latest commits (run: git fetch --unshallow)"
fi

if ((${#ONLY_BRANCHES[@]})); then
  BRANCHES=("${ONLY_BRANCHES[@]}")
  for b in "${BRANCHES[@]}"; do
    resolve_ref "$b" || { echo "No branch '$b' on origin or in this clone" >&2; exit 2; }
  done
else
  mapfile -t BRANCHES < <(git -C "$REPO" for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin | grep -vx HEAD)
  ((${#BRANCHES[@]})) || mapfile -t BRANCHES < <(git -C "$REPO" for-each-ref --format='%(refname:lstrip=2)' refs/heads)
  ((${#BRANCHES[@]})) || { echo "No branches to check" >&2; exit 2; }
  for b in "${BRANCHES[@]}"; do resolve_ref "$b"; done
fi
say INFO "branches: ${BRANCHES[*]}"
if ((${#LOCAL_AHEAD[@]})); then
  say INFO "your local commits that are not on origin yet are checked for: ${LOCAL_AHEAD[*]}"
fi
if ((${#ONLY_BRANCHES[@]} == 0)); then
  missing=()
  for b in "${EXPECTED_BRANCHES[@]}"; do [[ " ${BRANCHES[*]} " == *" $b "* ]] || missing+=("$b"); done
  if ((${#missing[@]})); then say WARN "expected branches are missing: ${missing[*]}"; else say PASS "all ${#EXPECTED_BRANCHES[@]} project branches are there"; fi
fi

# every branch as plain files, for the tools that read folders
for b in "${BRANCHES[@]}"; do
  mkdir -p "$WORK/src/$b"
  git -C "$REPO" archive "$(ref_of "$b")" | tar -x -C "$WORK/src/$b"
done

head1 "Tools"
GITLEAKS="" TRIVY="" HADOLINT="" SHELLCHECK=""
for t in gitleaks trivy hadolint shellcheck; do
  if find_tool "$t"; then
    v=$("$TOOL_PATH" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    say INFO "$t ${v:-} ($TOOL_PATH)"
    case $t in gitleaks) GITLEAKS=$TOOL_PATH ;; trivy) TRIVY=$TOOL_PATH ;; hadolint) HADOLINT=$TOOL_PATH ;; shellcheck) SHELLCHECK=$TOOL_PATH ;; esac
  else
    say SKIP "$t is not available$( ((OFFLINE)) && echo ' (offline)'): its checks are skipped"
  fi
done
DOCKER_OK=0; have_docker && DOCKER_OK=1
COMPOSE_OK=0; command -v docker >/dev/null && docker compose version >/dev/null 2>&1 && COMPOSE_OK=1
if ((DOCKER_OK)); then
  say INFO "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
else
  say SKIP "Docker does not answer (not installed, not running, or this user is not in the docker group): nginx -t, image and container checks are skipped"
fi
TERRAFORM=$(command -v terraform 2>/dev/null || true)
ANSIBLE_LINT=$(command -v ansible-lint 2>/dev/null || true)
if [[ -n $TERRAFORM ]]; then
  say INFO "terraform $("$TERRAFORM" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
else
  say SKIP "terraform is not installed: Terraform checks are skipped"
fi
if [[ -n $ANSIBLE_LINT ]]; then say INFO "ansible-lint is installed"; else say SKIP "ansible-lint is not installed: Ansible lint is skipped"; fi

# ---------------------------------------------------------------- history

if wanted history; then
  head1 "History: every commit of every branch"
  REFS=()
  for b in "${BRANCHES[@]}"; do
    for r in "refs/remotes/origin/$b" "refs/heads/$b"; do
      git -C "$REPO" rev-parse -q --verify "$r" >/dev/null && REFS+=("$r")
    done
  done

  git -C "$REPO" -c core.quotePath=false log "${REFS[@]}" --no-renames --diff-filter=AM --name-only --format='commit %h' \
    | awk '$1 == "commit" && NF == 2 {c = $2; next} NF {print c "\t" $0}' > "$WORK/added-files.tsv"
  pyrelay forbidden "$WORK/added-files.tsv"

  mapfile -t emails < <(git -C "$REPO" log "${REFS[@]}" --format='%ae%n%ce' | sort -u)
  odd=()
  for e in "${emails[@]}"; do
    [[ $e == *@users.noreply.github.com || $e == noreply@github.com ]] || odd+=("$e")
  done
  if ((${#odd[@]})); then
    say WARN "commits with an email that GitHub does not link to an account, or a personal email: ${odd[*]}"
  else
    say PASS "every commit author uses a GitHub noreply address"
  fi

  coauth=$(git -C "$REPO" log "${REFS[@]}" --format='%(trailers:key=Co-authored-by,valueonly)' | grep -v '^$' | sort | uniq -c)
  if [[ -n $coauth ]]; then
    say WARN "commits list co-authors, GitHub shows them in Contributors"
    printf '%s\n' "$coauth" | detail
  else
    say PASS "no Co-authored-by lines in the commits"
  fi

  if [[ -n $GITLEAKS ]]; then
    "$GITLEAKS" git --no-banner --no-color --redact --exit-code 0 --log-opts="${REFS[*]}" \
      --report-format json --report-path "$WORK/gitleaks.json" "$REPO" > "$WORK/gitleaks.log" 2>&1
    commits=$(grep -oE '[0-9]+ commits scanned' "$WORK/gitleaks.log" | grep -oE '^[0-9]+' | tail -1)
    if [[ ! -s $WORK/gitleaks.json ]] || grep -qE ' (ERR|FTL) ' "$WORK/gitleaks.log"; then
      say SKIP "gitleaks did not finish: $(grep -E ' (ERR|FTL) ' "$WORK/gitleaks.log" | tail -1 | cut -c1-160)"
    elif [[ ${commits:-0} == 0 ]]; then
      say SKIP "gitleaks scanned 0 commits"
    else
      pyrelay gitleaks "$WORK/gitleaks.json" "$commits"
    fi
  fi
fi

# ---------------------------------------------------------------- files

if wanted files || wanted app; then
  head1 "Files: secrets and hardcoded settings in every branch"
  : > "$WORK/manifest.tsv"
  for b in "${BRANCHES[@]}"; do
    git -C "$REPO" -c core.quotePath=false ls-tree -r --full-tree "$(ref_of "$b")" \
      | awk -v b="$b" -F'\t' '{split($1, m, " "); if (m[2] == "blob") print m[3] "\t" b "\t" $2}' >> "$WORK/manifest.tsv"
  done
  pyrelay text "$REPO" "$WORK/manifest.tsv" "${#BRANCHES[@]}"
fi

if wanted files; then
  head1 "Files: .gitignore keeps secrets out of Git"
  for b in "${BRANCHES[@]}"; do
    d="$WORK/src/$b"
    probes=()
    [[ -f $d/.env.example ]] && probes+=(.env)
    [[ -f $d/jenkins/.env.example ]] && probes+=(jenkins/.env)
    [[ -d $d/terraform ]] && probes+=(terraform/terraform.tfvars terraform/terraform.tfstate terraform/terraform.tfstate.backup terraform/tfplan terraform/.terraform/x)
    grep -qs vault_password_file "$d/ansible/ansible.cfg" && probes+=(ansible/.vault_pass)
    ((${#probes[@]})) || continue
    tmpgit="$WORK/ignore-$b"
    rm -rf "$tmpgit"; cp -r "$d" "$tmpgit"; git -C "$tmpgit" init -q
    notignored=()
    for p in "${probes[@]}"; do
      git -c core.excludesFile=/dev/null -C "$tmpgit" check-ignore -q --no-index "$p" || notignored+=("$p")
    done
    if ((${#notignored[@]})); then say FAIL "$b: .gitignore does not cover ${notignored[*]}"
    else say PASS "$b: .gitignore covers ${probes[*]}"; fi
    rm -rf "$tmpgit"
  done

  head1 "Files: Dockerfiles (hadolint)"
  if [[ -n $HADOLINT ]]; then
    for b in "${BRANCHES[@]}"; do
      while IFS= read -r f; do
        id=$(git -C "$REPO" rev-parse "$(ref_of "$b"):$f")
        first_time hadolint "$id" || continue
        "$HADOLINT" --no-fail --format json "$WORK/src/$b/$f" > "$WORK/hadolint.json" 2>/dev/null < /dev/null
        pyrelay hadolint "$WORK/hadolint.json" "$f ($(branches_with "$f" "$id"))"
      done < <(cd "$WORK/src/$b" && find . -name 'Dockerfile*' -type f | sed 's|^\./||' | sort)
    done
  else
    say SKIP "hadolint is not available"
  fi

  head1 "Files: shell scripts (shellcheck)"
  if [[ -n $SHELLCHECK ]]; then
    n=0
    for b in "${BRANCHES[@]}"; do
      while IFS= read -r f; do
        id=$(git -C "$REPO" rev-parse "$(ref_of "$b"):$f")
        first_time shellcheck "$id" || continue
        n=$((n + 1))
        where="$f ($(branches_with "$f" "$id"))"
        if res=$("$SHELLCHECK" -f gcc -S warning "$WORK/src/$b/$f" 2>&1 < /dev/null); then
          say PASS "$where"
        elif grep -q ': error:' <<< "$res"; then
          say FAIL "$where: errors"; printf '%s\n' "${res//$WORK\/src\/$b\//}" | head -15 | detail
        else
          say WARN "$where: warnings"; printf '%s\n' "${res//$WORK\/src\/$b\//}" | head -15 | detail
        fi
      done < <(cd "$WORK/src/$b" && find . -name '*.sh' -type f | sed 's|^\./||' | sort)
    done
    ((n)) || say INFO "no shell scripts"
  else
    say SKIP "shellcheck is not available"
  fi

  head1 "Files: Docker Compose"
  if ((COMPOSE_OK)); then
    for b in "${BRANCHES[@]}"; do
      while IFS= read -r f; do
        dir=$(dirname "$f")
        id="$(git -C "$REPO" rev-parse "$(ref_of "$b"):$f")-$(git -C "$REPO" rev-parse -q --verify "$(ref_of "$b"):$dir/.env.example" 2>/dev/null)"
        first_time compose "$id" || continue
        label="$f ($(branches_with "$f" "${id%%-*}"))"
        # the real .env is not in Git: use the example values, the way the README starts the stack
        [[ -f $WORK/src/$b/$dir/.env.example && ! -e $WORK/src/$b/$dir/.env ]] && cp "$WORK/src/$b/$dir/.env.example" "$WORK/src/$b/$dir/.env"
        if DOCKER_GID=999 docker compose -f "$WORK/src/$b/$f" config --format json > "$WORK/compose.json" 2> "$WORK/compose.err" < /dev/null; then
          pyrelay compose "$WORK/compose.json" "$label"
        else
          say FAIL "$label: docker compose config fails"; detail < "$WORK/compose.err"
        fi
      done < <(cd "$WORK/src/$b" && find . \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose*.yml' -o -name 'compose*.yaml' \) -type f | sed 's|^\./||' | sort)
    done
  else
    say SKIP "docker compose is not installed"
  fi

  head1 "Files: Nginx configs (nginx -t)"
  lb_done=0
  for b in "${BRANCHES[@]}"; do
    d="$WORK/src/$b/lb"
    [[ -d $d/templates && -d $d/upstreams ]] || continue
    id=$(git -C "$REPO" rev-parse "$(ref_of "$b"):lb")
    first_time nginx "$id" || continue
    lb_done=1
    if ((DOCKER_OK == 0)); then say SKIP "Docker does not answer"; break; fi
    if ! docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1; then
      if ((OFFLINE)) || ! docker pull -q "$NGINX_IMAGE" >/dev/null 2>&1; then say SKIP "image $NGINX_IMAGE is not available"; break; fi
    fi
    failed=()
    total=0
    timed_out=0
    for up in "$d"/upstreams/*.conf; do
      alg=$(basename "$up" .conf)
      for sticky in "$d"/sticky/*.conf; do
        st=$(basename "$sticky" .conf)
        total=$((total + 1))
        if ! timeout 60 docker run --rm --name "travelagency-check-nginx-$$" -e LB_ALGORITHM="$alg" -e LB_STICKY="$st" \
             -v "$d/templates:/etc/nginx/templates:ro" -v "$d/upstreams:/etc/nginx/upstreams:ro" -v "$d/sticky:/etc/nginx/sticky:ro" \
             "$NGINX_IMAGE" nginx -t > "$WORK/nginx.log" 2>&1 < /dev/null; then
          if ! grep -q 'nginx: ' "$WORK/nginx.log"; then
            timed_out=1
            docker rm -f "travelagency-check-nginx-$$" >/dev/null 2>&1
            break 2
          fi
          failed+=("$alg/sticky-$st: $(grep -m1 -E 'emerg|error' "$WORK/nginx.log")")
        fi
      done
    done
    if ((timed_out)); then
      say SKIP "lb: $NGINX_IMAGE did not run nginx -t (is it the official image?)"
    elif ((${#failed[@]})); then
      say FAIL "lb ($(branches_with lb "$id")): ${#failed[@]} of $total configs are invalid"; printf '%s\n' "${failed[@]}" | detail
    else
      say PASS "lb ($(branches_with lb "$id")): all $total configs are valid (every algorithm, sticky on and off)"
    fi
  done
  ((lb_done)) || say INFO "no Nginx load balancer configs"

  head1 "Files: Terraform"
  tf_done=0
  for b in "${BRANCHES[@]}"; do
    d="$WORK/src/$b/terraform"
    [[ -d $d ]] || continue
    id=$(git -C "$REPO" rev-parse "$(ref_of "$b"):terraform")
    first_time terraform "$id" || continue
    tf_done=1
    label="terraform/ ($(branches_with terraform "$id"))"
    if [[ -z $TERRAFORM ]]; then say SKIP "$label: terraform is not installed"; continue; fi
    if res=$("$TERRAFORM" -chdir="$d" fmt -check -recursive -diff -no-color 2>&1); then
      say PASS "$label: formatted (terraform fmt)"
    elif grep -q 'Error' <<< "$res"; then
      say FAIL "$label: syntax errors"; head -20 <<< "$res" | detail
    else
      say WARN "$label: not formatted, run terraform fmt"; head -20 <<< "$res" | detail
    fi
    if ((OFFLINE)); then say SKIP "$label: terraform validate needs the provider download (offline)"; continue; fi
    if ! res=$(TF_IN_AUTOMATION=1 "$TERRAFORM" -chdir="$d" init -backend=false -input=false -no-color 2>&1); then
      say SKIP "$label: terraform init could not get the provider: $(grep -m1 'Error' <<< "$res" | cut -c1-140)"
    elif res=$("$TERRAFORM" -chdir="$d" validate -no-color 2>&1); then
      say PASS "$label: valid (terraform validate)"
    else
      say FAIL "$label: terraform validate fails"; tail -15 <<< "$res" | detail
    fi
  done
  ((tf_done)) || say INFO "no Terraform code"

  head1 "Files: Ansible"
  an_done=0
  for b in "${BRANCHES[@]}"; do
    d="$WORK/src/$b/ansible"
    [[ -d $d ]] || continue
    id=$(git -C "$REPO" rev-parse "$(ref_of "$b"):ansible")
    first_time ansible "$id" || continue
    an_done=1
    label="ansible/ ($(branches_with ansible "$id"))"
    if [[ -z $ANSIBLE_LINT ]]; then say SKIP "$label: ansible-lint is not installed"; continue; fi
    lint=("$ANSIBLE_LINT" --nocolor)
    ((OFFLINE)) && lint+=(--offline)
    res=$(cd "$d" && "${lint[@]}" 2>&1 < /dev/null); rc=$?
    if ((rc != 0)) && grep -q 'attempting to call Galaxy' <<< "$res"; then
      # could not download the collections from requirements.yml: use the installed ones
      res=$(cd "$d" && "$ANSIBLE_LINT" --nocolor --offline 2>&1 < /dev/null); rc=$?
    fi
    if ((rc == 0)); then
      prof=$(sed -nE "s/.*criteria was '([a-z]+)'.*/\1/p" <<< "$res" | head -1)
      say PASS "$label: ansible-lint finds nothing${prof:+ (profile $prof)}"
    else
      say WARN "$label: ansible-lint reports problems"; grep -vE '^\s*$' <<< "$res" | tail -20 | detail
    fi
  done
  ((an_done)) || say INFO "no Ansible code"
fi

# ---------------------------------------------------------------- dependencies

if wanted app; then
  head1 "App: known vulnerabilities in the Maven dependencies"
  if [[ -z $TRIVY ]]; then
    say SKIP "trivy is not available"
  elif ((OFFLINE)); then
    say SKIP "needs the vulnerability database (offline)"
  elif trivy_ready; then
    for b in "${BRANCHES[@]}"; do
      [[ -f $WORK/src/$b/pom.xml ]] || continue
      id=$(git -C "$REPO" rev-parse "$(ref_of "$b"):pom.xml")
      first_time trivy-pom "$id" || continue
      mkdir -p "$WORK/pom-$id" && cp "$WORK/src/$b/pom.xml" "$WORK/pom-$id/"
      if "$TRIVY" fs --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --format json \
           --output "$WORK/trivy-pom.json" "$WORK/pom-$id" > "$WORK/trivy.log" 2>&1 < /dev/null; then
        pyrelay trivy "$WORK/trivy-pom.json" "pom.xml ($(branches_with pom.xml "$id"))" "the dependencies"
      else
        say SKIP "trivy could not scan pom.xml: $(grep -m1 -iE 'error|fatal' "$WORK/trivy.log" | cut -c1-160)"
      fi
    done
  fi
fi

# ---------------------------------------------------------------- image

if wanted image; then
  head1 "Image: the application container"
  image=""
  if ((DOCKER_OK == 0)); then
    say SKIP "Docker does not answer"
  elif ((BUILD)); then
    src=""
    for b in jenkins terraform docker-load-balancer docker; do [[ -f $WORK/src/$b/Dockerfile ]] && { src=$b; break; }; done
    if [[ -z $src ]]; then
      say SKIP "no checked branch has a Dockerfile"
    elif docker build --provenance=false -t travelagency:check "$WORK/src/$src" > "$WORK/build.log" 2>&1 < /dev/null; then
      say PASS "image builds from branch $src (Maven compiles and tests inside the build)"
      image=travelagency:check
    else
      say FAIL "image does not build from branch $src"; tail -15 "$WORK/build.log" | detail
    fi
  else
    for candidate in "${APP_IMAGES[@]}"; do
      docker image inspect "$candidate" >/dev/null 2>&1 && { image=$candidate; break; }
    done
    if [[ -n $image ]]; then say INFO "checking the existing image $image (use --build to build a fresh one)"
    else say SKIP "no image ${APP_IMAGES[*]} on this machine: use --build"; fi
  fi
  if [[ -n $image ]]; then
    user=$(docker image inspect -f '{{.Config.User}}' "$image")
    if [[ -z $user || ${user%%:*} == root || ${user%%:*} == 0 ]]; then say FAIL "$image runs as root"
    else say PASS "$image runs as user '$user'"; fi
    if [[ -n $(docker image inspect -f '{{if .Config.Healthcheck}}yes{{end}}' "$image") ]]; then say PASS "$image has a health check"
    else say WARN "$image has no health check"; fi
    secret_env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
      | awk -F= 'toupper($1) ~ /PASSWORD|SECRET|TOKEN/ && $2 != "" {print $1}' | paste -sd' ')
    if [[ -n $secret_env ]]; then say FAIL "$image has passwords in its ENV (everyone who gets the image can read them): $secret_env"
    else say PASS "$image has no passwords in its ENV"; fi
    if [[ -z $TRIVY ]]; then
      say SKIP "trivy is not available: no vulnerability scan"
    elif ((OFFLINE)); then
      say SKIP "vulnerability scan needs the database (offline)"
    elif trivy_ready; then
      # the Java libraries of the WAR are the pom.xml dependencies checked above; Tomcat and the JDK
      # need trivy's Java database (about 1 GB more), so they are scanned only when there is room
      pkg=(--pkg-types os) what="the system packages of the image"
      free=$(free_mb "$CACHE")
      if [[ -f $CACHE/trivy/java-db/trivy-java.db ]] || ((${free:-0} > 3000)); then
        pkg=(--pkg-types "os,library" --skip-dirs /usr/local/tomcat/webapps) what="the image (system packages, Tomcat, JDK)"
      else
        say INFO "Tomcat and JDK libraries are not scanned: trivy needs about 1 GB more for its Java database"
      fi
      if "$TRIVY" image --quiet --scanners vuln "${pkg[@]}" --severity HIGH,CRITICAL --ignore-unfixed --format json \
           --output "$WORK/trivy-image.json" "$image" > "$WORK/trivy.log" 2>&1 < /dev/null; then
        pyrelay trivy "$WORK/trivy-image.json" "$image" "$what"
      else
        say SKIP "trivy could not scan $image: $(grep -m1 -iE 'error|fatal' "$WORK/trivy.log" | cut -c1-160)"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------- runtime

http_code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }

if wanted runtime; then
  head1 "Runtime: containers on this machine"
  if ((DOCKER_OK == 0)); then
    say SKIP "Docker does not answer"
  else
    mapfile -t names < <(docker ps --format '{{.Names}}' | grep -E 'travelagency|jenkins' | sort)
    if ((${#names[@]} == 0)); then
      say INFO "no project containers are running"
    else
      docker inspect "${names[@]}" > "$WORK/containers.json" 2>/dev/null
      pyrelay containers "$WORK/containers.json" "$(docker images --no-trunc -q travelagency 2>/dev/null | sort -u | paste -sd' ')"
    fi
    exposed=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E 'travelagency|jenkins' | while IFS=$'\t' read -r n p; do
      ports=$(grep -oE '0\.0\.0\.0:[0-9]+' <<< "$p" | cut -d: -f2 | sort -u | paste -sd,)
      [[ -n $ports ]] && printf '%s %s; ' "$n" "$ports"
    done)
    [[ -n $exposed ]] && say INFO "ports open on all network interfaces: ${exposed%; }"
  fi

  head1 "Runtime: the site"
  sites=()
  for url in http://localhost http://localhost:8080; do
    [[ $(http_code "$url/form-login") != 000 ]] && sites+=("$url")
  done
  if ((${#sites[@]} == 0)); then
    say INFO "the site does not answer on localhost:80 or :8080 (not running)"
  fi
  for url in "${sites[@]}"; do
    hdr=$(curl -s -D - -o /dev/null -m 10 "$url/form-login" | tr -d '\r')
    code=$(awk 'NR==1 {print $2}' <<< "$hdr")
    if [[ $code == 200 ]]; then say PASS "$url/form-login answers 200"; else say FAIL "$url/form-login answers $code"; fi
    server=$(awk -F': ' 'tolower($1)=="server" {print $2}' <<< "$hdr")
    if [[ $server =~ [0-9] ]]; then say WARN "$url: header 'Server: $server' shows the version"; else say PASS "$url: no software version in the headers"; fi
    for h in X-Content-Type-Options X-Frame-Options; do
      if grep -qi "^$h:" <<< "$hdr"; then say PASS "$url: header $h is set"; else say WARN "$url: no $h header"; fi
    done
    cookie=$(grep -i '^set-cookie:.*JSESSIONID' <<< "$hdr" | head -1)
    if [[ -n $cookie ]]; then
      if grep -qi 'httponly' <<< "$cookie"; then say PASS "$url: session cookie is HttpOnly"; else say WARN "$url: session cookie is not HttpOnly"; fi
    fi
    loc=$(curl -s -o /dev/null -m 10 -w '%{http_code} %{redirect_url}' "$url/users")
    if [[ $loc == 30?*form-login* ]]; then say PASS "$url/users without login redirects to the login page"
    elif [[ ${loc%% *} == 200 ]]; then say FAIL "$url/users opens without login"
    else say INFO "$url/users without login answers ${loc%% *}"; fi
    body=$(curl -s -m 10 "$url/%")
    if grep -qoE 'Apache Tomcat/[0-9.]+|nginx/[0-9.]+' <<< "$body"; then
      say WARN "$url: error pages show the server version ($(grep -oE 'Apache Tomcat/[0-9.]+|nginx/[0-9.]+' <<< "$body" | head -1))"
    else
      say PASS "$url: error pages do not show the server version"
    fi
    if [[ $(curl -s -m 10 "$url/nginx-status") == *"Active connections"* ]]; then
      say WARN "$url/nginx-status is open to everyone (connection statistics)"
    fi
    say WARN "$url is plain HTTP: logins and session cookies travel unencrypted (fine in a lab, not on the internet)"
  done

  head1 "Runtime: Jenkins"
  jurl=http://localhost:8081
  if [[ $(http_code "$jurl/login") == 000 ]]; then
    say INFO "Jenkins does not answer on localhost:8081 (not running)"
  else
    c=$(http_code "$jurl/api/json")
    case $c in
      401|403) say PASS "anonymous users get $c: they cannot see jobs or run anything" ;;
      200)     say FAIL "anonymous API request answers 200: Jenkins is open without a login" ;;
      *)       say INFO "Jenkins answers $c (still starting?): run the check again in a minute" ;;
    esac
    c=$(http_code "$jurl/script")
    case $c in
      401|403) say PASS "the script console needs a login ($c)" ;;
      200)     say FAIL "the script console opens without a login" ;;
      *)       say INFO "the script console answers $c" ;;
    esac
    c=$(http_code "$jurl/signup")
    case $c in
      200)         say WARN "anyone can create an account (/signup)" ;;
      401|403|404) say PASS "sign-up is turned off ($c)" ;;
      *)           say INFO "the sign-up page answers $c" ;;
    esac
    v=$(curl -s -I -m 10 "$jurl/login" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-jenkins" {print $2}')
    [[ -n $v ]] && say INFO "Jenkins $v (keep it updated: docker compose build --pull)"
  fi

  head1 "Runtime: secret files on this machine"
  mapfile -t secret_files < <(
    for d in "$REPO" "$HOME"/travel-*; do
      [[ -d $d ]] && find "$d" -maxdepth 3 -type f \( -name '.env' -o -name '*.tfvars' -o -name '*.tfstate' -o -name '*.tfstate.backup' \) \
        -not -path '*/.terraform/*' 2>/dev/null
    done | sort -u)
  if ((${#secret_files[@]})); then
    pyrelay envfile "${secret_files[@]}"
  else
    say INFO "no .env, tfvars or tfstate files in $REPO or ~/travel-*"
  fi
fi

# ---------------------------------------------------------------- summary

head1 "Summary"
printf '  %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
  "$C_PASS" "$N_PASS" "$C_OFF" "$C_WARN" "$N_WARN" "$C_OFF" "$C_FAIL" "$N_FAIL" "$C_OFF" "$C_SKIP" "$N_SKIP" "$C_OFF"
printf '  PASS %d   WARN %d   FAIL %d   SKIP %d\n' "$N_PASS" "$N_WARN" "$N_FAIL" "$N_SKIP" >> "$REPORT"
if ((N_FAIL)); then
  printf '\n  %sMust fix:%s\n' "$C_FAIL" "$C_OFF"; printf '\n  Must fix:\n' >> "$REPORT"
  printf '%s\n' "${SUMMARY_FAIL[@]}" | detail
fi
if ((N_WARN)); then
  printf '\n  %sWorth fixing or accepted risks:%s\n' "$C_WARN" "$C_OFF"; printf '\n  Worth fixing or accepted risks:\n' >> "$REPORT"
  printf '%s\n' "${SUMMARY_WARN[@]}" | detail
fi
printf '\n  Report: %s\n' "$REPORT"
((N_FAIL == 0))
