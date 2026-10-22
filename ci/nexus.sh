#!/usr/bin/env bash
# Nexus steps of the Jenkins pipeline (Jenkinsfile):
#   bash ci/nexus.sh publish     the WAR (+ SBOM) -> Maven repository, the image -> Docker registry; skips what is there
#   bash ci/nexus.sh pull        pull the image from the Nexus registry: the deploy always uses that copy
#   bash ci/nexus.sh retention   keep the NEXUS_KEEP newest versions in both repositories, delete older ones
#
# Settings come from the environment (the environment block of the Jenkinsfile):
#   NEXUS_URL, NEXUS_MAVEN_REPO, NEXUS_DOCKER_REPO, REGISTRY, NEXUS_KEEP,
#   IMAGE (travelagency:<commit>), IMAGE_TAG (<commit>), REGISTRY_IMAGE (<registry>/travelagency:<commit>),
#   NEXUS_USER, NEXUS_PASSWORD (the Jenkins credential nexus-ci).
set -euo pipefail
# A failed command inside $( ) stops the script too, not only the command substitution
shopt -s inherit_errexit
umask 077

# Where the Dockerfile puts the WAR inside the image
readonly WAR_IN_IMAGE=/usr/local/tomcat/webapps/ROOT.war
# Written by ci/scan.sh trivy; stored next to the WAR as TravelAgency-<version>-cyclonedx.json
readonly SBOM=reports/sbom.cdx.json

work=$(mktemp -d)
container=
cleanup() {
    if [ -n "$container" ]; then
        docker rm -f "$container" >/dev/null 2>&1 || true
    fi
    # Holds the curl login and the Docker login (DOCKER_CONFIG)
    rm -rf "$work"
}
trap cleanup EXIT

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

# The login goes to curl in a file, so the password is not in the process list
curl_login() {
    need NEXUS_USER NEXUS_PASSWORD
    local user=${NEXUS_USER//\\/\\\\} password=${NEXUS_PASSWORD//\\/\\\\}
    printf 'user = "%s:%s"\n' "${user//\"/\\\"}" "${password//\"/\\\"}" > "$work/curl.cfg"
}

# REST call that must succeed; on an error curl prints the answer of Nexus
nexus() {
    curl -sS --fail-with-body -K "$work/curl.cfg" "$@"
}

# HTTP status of a request, without failing on 4xx
nexus_status() {
    curl -sS -o /dev/null -w '%{http_code}' -K "$work/curl.cfg" "$@"
}

registry_login() {
    need REGISTRY NEXUS_USER NEXUS_PASSWORD
    export DOCKER_CONFIG="$work/docker"
    mkdir -p "$DOCKER_CONFIG"
    printf '%s' "$NEXUS_PASSWORD" \
        | docker login --username "$NEXUS_USER" --password-stdin "$REGISTRY" >/dev/null \
        || fail "the Docker registry $REGISTRY refused $NEXUS_USER: check NEXUS_CI_USER / NEXUS_CI_PASSWORD"
}

# First value of a tag in pom.xml: <groupId>, <artifactId>, <version> of the project
pom() {
    local value
    value=$(sed -n "/<$1>/{s#.*<$1>\\(.*\\)</$1>.*#\\1#p;q}" pom.xml)
    [ -n "$value" ] || fail "no <$1> in pom.xml"
    printf '%s' "$value"
}

# Maven coordinates of this build: the release part of the pom version + the commit id, e.g. 1.0-3f2a9c1
maven_coordinates() {
    group=$(pom groupId)
    artifact=$(pom artifactId)
    local base
    base=$(pom version)
    version="${base%-SNAPSHOT}-$IMAGE_TAG"
}

# Image name inside the registry: localhost:8092/travelagency:3f2a9c1 -> travelagency
image_name() {
    local name=${REGISTRY_IMAGE#"$REGISTRY"/}
    printf '%s' "${name%:*}"
}

# All components of a repository, one JSON object per line (the API returns pages)
components() {
    local repo=$1 token='' page
    while :; do
        local args=(--data-urlencode "repository=$repo")
        [ -z "$token" ] || args+=(--data-urlencode "continuationToken=$token")
        page=$(nexus -G "$NEXUS_URL/service/rest/v1/components" "${args[@]}")
        jq -c '.items[]' <<< "$page"
        token=$(jq -r '.continuationToken // empty' <<< "$page")
        [ -n "$token" ] || break
    done
}

publish() {
    need IMAGE IMAGE_TAG REGISTRY REGISTRY_IMAGE NEXUS_URL NEXUS_MAVEN_REPO NEXUS_DOCKER_REPO
    curl_login
    maven_coordinates

    # ---- WAR -> Maven repository
    local path="${group//.//}/$artifact/$version/$artifact-$version.war"
    local url="$NEXUS_URL/repository/$NEXUS_MAVEN_REPO/$path"
    local code
    # curl prints 000 and fails when nothing answers; the case below explains it
    code=$(nexus_status -I "$url") || true
    case "$code" in
        200)
            echo "WAR $group:$artifact:$version is already in $NEXUS_MAVEN_REPO: a release is never overwritten"
            ;;
        404)
            container=$(docker create "$IMAGE")
            docker cp "$container:$WAR_IN_IMAGE" "$work/$artifact.war"
            docker rm "$container" >/dev/null
            container=
            local form=(
                -F "maven2.groupId=$group"
                -F "maven2.artifactId=$artifact"
                -F "maven2.version=$version"
                -F "maven2.packaging=war"
                -F "maven2.generate-pom=true"
                -F "maven2.asset1=@$work/$artifact.war"
                -F "maven2.asset1.extension=war"
            )
            local upload="$NEXUS_URL/service/rest/v1/components?repository=$NEXUS_MAVEN_REPO"
            if [ -f "$SBOM" ] && nexus -X POST "$upload" "${form[@]}" \
                    -F "maven2.asset2=@$SBOM" -F "maven2.asset2.extension=json" -F "maven2.asset2.classifier=cyclonedx"; then
                echo "WAR and SBOM uploaded: $url"
            else
                [ ! -f "$SBOM" ] || echo "WARNING: Nexus did not take the WAR with the SBOM (see above), uploading the WAR alone"
                nexus -X POST "$upload" "${form[@]}"
                echo "WAR uploaded: $url"
            fi
            ;;
        401 | 403)
            fail "Nexus refused $NEXUS_USER (HTTP $code): check NEXUS_CI_USER / NEXUS_CI_PASSWORD in jenkins/.env and nexus/.env"
            ;;
        *)
            fail "Nexus answered HTTP $code for $url. Is it running? cd nexus && docker compose ps"
            ;;
    esac

    # ---- image -> Docker registry
    local name found
    name=$(image_name)
    found=$(components "$NEXUS_DOCKER_REPO" \
        | jq -s --arg name "$name" --arg tag "$IMAGE_TAG" '[.[] | select(.name == $name and .version == $tag)] | length')
    if [ "$found" -gt 0 ]; then
        echo "Image $name:$IMAGE_TAG is already in $NEXUS_DOCKER_REPO: a tag is never overwritten"
    else
        registry_login
        docker tag "$IMAGE" "$REGISTRY_IMAGE"
        docker push "$REGISTRY_IMAGE"
        echo "Image pushed: $REGISTRY_IMAGE"
    fi
}

pull() {
    need REGISTRY REGISTRY_IMAGE NEXUS_DOCKER_REPO
    registry_login
    docker pull "$REGISTRY_IMAGE" \
        || fail "$REGISTRY_IMAGE is not in Nexus. The stored versions: Nexus UI -> Browse -> $NEXUS_DOCKER_REPO"
    echo "Deploying the image from Nexus: $(docker image inspect --format '{{join .RepoDigests " "}}' "$REGISTRY_IMAGE")"
}

# Delete all versions of one component except the $keep newest and the one just deployed.
# Image tags of commits that did not change the application point to the same image (manifest);
# such an old tag is kept as long as a kept tag has the same manifest, so the kept one never loses it
prune() {
    local repo=$1 name=$2 current=$3 id old
    components "$repo" \
        | jq -rs --arg name "$name" --arg current "$current" --argjson keep "$keep" '
            [.[] | select(.name == $name)
                 | {id, version, time: ([.assets[].lastModified // ""] | max),
                    sums: [.assets[] | select(.path | test("/manifests/")) | .checksum.sha256 // empty]}]
            | sort_by(.time) | reverse
            | (.[:$keep] + map(select(.version == $current)) | map(.sums[])) as $kept
            | .[$keep:][] | select(.version != $current)
            | if any(.sums[]; IN($kept[])) then "keep \(.version)" else "\(.id) \(.version)" end' \
        | while read -r id old; do
            if [ "$id" = keep ]; then
                echo "$repo: kept $name $old, it is the same image as a newer kept version"
                continue
            fi
            nexus -o /dev/null -X DELETE "$NEXUS_URL/service/rest/v1/components/$id"
            echo "$repo: deleted $name $old"
        done
    echo "$repo: kept the $keep newest versions of $name and the deployed one"
}

retention() {
    need IMAGE_TAG REGISTRY REGISTRY_IMAGE NEXUS_URL NEXUS_MAVEN_REPO NEXUS_DOCKER_REPO
    keep=${NEXUS_KEEP:-5}
    case "$keep" in
        '' | *[!0-9]* | 0) fail "NEXUS_KEEP must be a number from 1, not '$keep'" ;;
    esac
    curl_login
    maven_coordinates
    prune "$NEXUS_MAVEN_REPO" "$artifact" "$version"
    prune "$NEXUS_DOCKER_REPO" "$(image_name)" "$IMAGE_TAG"
}

case "${1:-}" in
    publish) publish ;;
    pull) pull ;;
    retention) retention ;;
    *)
        echo "usage: bash ci/nexus.sh publish|pull|retention" >&2
        exit 2
        ;;
esac
