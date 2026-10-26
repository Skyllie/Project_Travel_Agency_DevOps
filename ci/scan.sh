#!/usr/bin/env bash
# Security scans of the Jenkins pipeline (Jenkinsfile). Each scan writes its reports to reports/
# and fails only when the scanner itself cannot run; the stage "Security gate" decides:
#   bash ci/scan.sh snyk    SCA: the Maven dependencies of pom.xml in Snyk Open Source; snyk monitor
#                           sends the dependency list to the Snyk project "travelagency"
#   bash ci/scan.sh trivy   the image: OS packages and the jars in the WAR (Trivy); SBOM in CycloneDX
#   bash ci/scan.sh grype   the image once more, with the Anchore database (Grype)
#   bash ci/scan.sh gate    fail if any scanner found a vulnerability of SCAN_FAIL_ON or higher that has a fix,
#                           except the ones listed, with a reason and an end date, in ci/accepted-risks.txt
#
# Settings: IMAGE (travelagency:<commit>), SCAN_FAIL_ON (CRITICAL or HIGH), SNYK_TOKEN (credential snyk-token).
# Reports in reports/: <scanner>.json (everything found), <scanner>.txt (table), snyk.sarif, sbom.cdx.json.
# Jenkins shows the JSON (Trivy, Grype) and the SARIF (Snyk) reports on the build page (Warnings plugin).
set -euo pipefail
shopt -s inherit_errexit

readonly REPORTS=reports

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

need() {
    local name
    for name in "$@"; do
        [ -n "${!name:-}" ] || fail "$name is not set"
    done
}

snyk_scan() {
    need SNYK_TOKEN
    mkdir -p "$REPORTS"
    local code=0
    # Exit codes: 0 nothing found, 1 vulnerabilities found (the gate decides), 2 error, 3 no project found
    snyk test --file=pom.xml \
        --json-file-output="$REPORTS/snyk.json" --sarif-file-output="$REPORTS/snyk.sarif" \
        | tee "$REPORTS/snyk.txt" || code=$?
    case "$code" in
        0 | 1) ;;
        *) fail "snyk test could not run (exit code $code): see the log above" ;;
    esac
    # A snapshot for the Snyk web UI; a failure here does not stop the build
    snyk monitor --file=pom.xml --project-name=travelagency >/dev/null \
        && echo "Snyk project travelagency updated: https://app.snyk.io" \
        || echo "WARNING: snyk monitor failed, the Snyk web UI shows an older snapshot"
}

trivy_scan() {
    need IMAGE
    mkdir -p "$REPORTS"
    trivy image --quiet --scanners vuln --format json --output "$REPORTS/trivy.json" "$IMAGE"
    trivy convert --format table --severity HIGH,CRITICAL --output "$REPORTS/trivy.txt" "$REPORTS/trivy.json"
    cat "$REPORTS/trivy.txt"
    # Software bill of materials: every package in the image; stored in Nexus next to the WAR
    trivy image --quiet --format cyclonedx --output "$REPORTS/sbom.cdx.json" "$IMAGE"
    echo "SBOM: $(jq '.components | length' "$REPORTS/sbom.cdx.json") components in $REPORTS/sbom.cdx.json"
}

grype_scan() {
    need IMAGE
    mkdir -p "$REPORTS"
    # The Anchore database, cached in the Jenkins home. A separate step, so a failed download
    # (network, full disk) is reported as such
    grype db update
    # No --quiet: in Grype it hides the errors as well. Without a terminal Grype prints only
    # warnings and errors anyway
    GRYPE_DB_AUTO_UPDATE=false grype "docker:$IMAGE" -o "json=$REPORTS/grype.json" -o "table=$REPORTS/grype.txt"
    # The table only with High and Critical, like the Trivy one
    grep -E 'NAME|High|Critical' "$REPORTS/grype.txt" || echo "Grype: no High or Critical vulnerabilities"
}

# Findings at or above SCAN_FAIL_ON that have a fixed version, one JSON object per line:
# {severity, ids: [the scanner id, CVE and GHSA aliases], package, version, fix}
findings() {
    local tool=$1 file="$REPORTS/$1.json"
    [ -f "$file" ] || fail "$file is missing: the $tool scan did not run"
    case "$tool" in
        snyk)
            jq -c --argjson min "$min" '
                def rank: {"low":1,"medium":2,"high":3,"critical":4}[ascii_downcase] // 0;
                [.vulnerabilities[]? | select((.severity | rank) >= $min and ((.fixedIn // []) | length > 0))]
                | unique_by(.id, .packageName, .version)[]
                | {severity: (.severity | ascii_upcase),
                   ids: ([.id] + (.identifiers.CVE // []) + (.identifiers.GHSA // [])),
                   package: .packageName, version, fix: (.fixedIn | join(", "))}' "$file"
            ;;
        trivy)
            jq -c --argjson min "$min" '
                def rank: {"LOW":1,"MEDIUM":2,"HIGH":3,"CRITICAL":4}[.] // 0;
                [.Results[]?.Vulnerabilities[]? | select((.Severity | rank) >= $min and (.FixedVersion // "") != "")]
                | unique_by(.VulnerabilityID, .PkgName, .InstalledVersion)[]
                | {severity: .Severity, ids: ([.VulnerabilityID] + (.VendorIDs // [])),
                   package: .PkgName, version: .InstalledVersion, fix: .FixedVersion}' "$file"
            ;;
        grype)
            jq -c --argjson min "$min" '
                def rank: {"low":1,"medium":2,"high":3,"critical":4}[ascii_downcase] // 0;
                [.matches[]? | select((.vulnerability.severity | rank) >= $min and .vulnerability.fix.state == "fixed")]
                | unique_by(.vulnerability.id, .artifact.name, .artifact.version)[]
                | {severity: (.vulnerability.severity | ascii_upcase),
                   ids: ([.vulnerability.id] + [.relatedVulnerabilities[]?.id]),
                   package: .artifact.name, version: .artifact.version,
                   fix: (.vulnerability.fix.versions | join(", "))}' "$file"
            ;;
    esac
}

# IDs from ci/accepted-risks.txt whose date has not passed, as a JSON array
accepted_ids() {
    local file=ci/accepted-risks.txt today id until reason ids=()
    today=$(date +%F)
    if [ -f "$file" ]; then
        while read -r id until reason; do
            case "$id" in '' | '#'*) continue ;; esac
            if ! [[ "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || [ -z "$reason" ]; then
                fail "$file: '$id $until $reason' must be: <ID> <YYYY-MM-DD> <reason>"
            fi
            if [[ "$until" < "$today" ]]; then
                echo "  accepted risk $id expired on $until: the gate blocks it again" >&2
            else
                ids+=("$id")
            fi
        done < "$file"
    fi
    if [ "${#ids[@]}" -eq 0 ]; then
        echo '[]'
    else
        printf '%s\n' "${ids[@]}" | jq -R . | jq -sc .
    fi
}

gate() {
    local level=${SCAN_FAIL_ON:-CRITICAL}
    case "${level^^}" in
        CRITICAL) min=4 ;;
        HIGH) min=3 ;;
        MEDIUM) min=2 ;;
        *) fail "SCAN_FAIL_ON must be CRITICAL, HIGH or MEDIUM, not '$level'" ;;
    esac
    local accepted
    accepted=$(accepted_ids)
    echo "Security gate: no ${level^^} or higher vulnerability that already has a fix"
    local tool all blocking count total=0
    for tool in snyk trivy grype; do
        all=$(findings "$tool" | jq -sc .)
        blocking=$(jq -c --argjson acc "$accepted" '[.[] | select(any(.ids[]; IN($acc[])) | not)]' <<< "$all")
        count=$(jq length <<< "$blocking")
        total=$((total + count))
        printf '  %-6s %3d\n' "$tool" "$count"
        jq -r --argjson acc "$accepted" '.[] |
            "           \(.severity) \(.ids[0]) \(.package) \(.version) -> \(.fix)"
            + (if any(.ids[]; IN($acc[])) then "   (accepted: ci/accepted-risks.txt)" else "" end)' <<< "$all"
    done
    [ "$total" -eq 0 ] || fail "$total findings above: upgrade the packages to the versions after '->' (pom.xml or the base image)"
    echo "Passed"
}

case "${1:-}" in
    snyk) snyk_scan ;;
    trivy) trivy_scan ;;
    grype) grype_scan ;;
    gate) gate ;;
    *)
        echo "usage: bash ci/scan.sh snyk|trivy|grype|gate" >&2
        exit 2
        ;;
esac
