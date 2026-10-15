#!/usr/bin/env bash
# Shows how the load balancer spreads requests.
#   ./lb/demo.sh                 15 new visitors (no cookies) -> which server answered each
#   ./lb/demo.sh --sticky        15 requests of one visitor (keeps the JSESSIONID cookie)
#   URL=http://localhost:8088/form-login ./lb/demo.sh      another address
set -euo pipefail

URL="${URL:-http://localhost/form-login}"
N="${N:-15}"
JAR=""
if [ "${1:-}" = "--sticky" ]; then
  JAR="$(mktemp)"
  trap 'rm -f "$JAR"' EXIT
fi

servers=()
for _ in $(seq "$N"); do
  # "|| true": a refused connection must not stop the script silently
  if [ -n "$JAR" ]; then
    headers=$(curl -s -o /dev/null -D - -b "$JAR" -c "$JAR" "$URL" || true)
  else
    headers=$(curl -s -o /dev/null -D - "$URL" || true)
  fi
  server=$(printf '%s\n' "$headers" | tr -d '\r' | awk 'tolower($1) == "x-served-by:" { print $2 }')
  servers+=("${server:-no-answer}")
done

echo "Order:  ${servers[*]}"
echo "Totals:"
printf '%s\n' "${servers[@]}" | sort | uniq -c
