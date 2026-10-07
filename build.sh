#!/usr/bin/env bash
# ==============================================================================
# build.sh - build the aap2go execution environment image (online).
#
# Requirements: podman and ansible-builder (python3 -m pip install ansible-builder).
# This is exactly what the GitHub Actions workflow runs.
#
# Usage: ./build.sh [-t NAME:TAG]... [-- <extra ansible-builder build args>]
#   default tag: options.tags in execution-environment.yml (localhost/aap2go:latest)
#   example:     ./build.sh -t localhost/aap2go:dev -- --no-cache
#   podman without a usable bridge network (e.g. nested in a container):
#                ./build.sh -- --extra-build-cli-args="--network=host"
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TAGS=()
EXTRA=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tag) TAGS+=("$2"); shift 2 ;;
        --)       shift; EXTRA=("$@"); break ;;
        -h|--help) sed -n '3,13p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

for cmd in podman ansible-builder; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found (pip install ansible-builder; install podman)" >&2; exit 1; }
done

tag_args=()
for t in ${TAGS[@]+"${TAGS[@]}"}; do tag_args+=(--tag "$t"); done

echo "==> ansible-builder $(ansible-builder --version) / $(podman --version)"
ansible-builder build \
    --file execution-environment.yml \
    --context context \
    --container-runtime podman \
    --verbosity 3 \
    ${tag_args[@]+"${tag_args[@]}"} \
    ${EXTRA[@]+"${EXTRA[@]}"}

image="${TAGS[0]:-$(awk '/^[[:space:]]*tags:/ {f=1; next} f && /^[[:space:]]*-/ {print $2; exit}' execution-environment.yml)}"
echo "==> built $image ($(podman image inspect --format '{{.Size}}' "$image" | awk '{printf "%.0f MB", $1/1024/1024}'))"
echo "    smoke tests: ./test.sh $image"
