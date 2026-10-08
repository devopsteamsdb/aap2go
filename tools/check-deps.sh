#!/usr/bin/env bash
# ==============================================================================
# check-deps.sh - fast preflight for the execution environment definition.
#
# Runs in a throw-away container of the base image (needs podman + network) and
# answers, in a few minutes instead of a full build:
#   * do all collections in requirements.yml resolve and install from Galaxy?
#   * what Python / system requirements do they add (ansible-builder introspect)?
#   * does the merged Python requirement set resolve on the target python? (pip dry run)
#   * is every requested RPM available from the UBI 9 + Microsoft repositories?
#
# Usage: tools/check-deps.sh            (from the project directory)
#        PODMAN_NETWORK=host tools/check-deps.sh   (podman without a bridge network)
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE_IMAGE="$(awk '/^images:/ {f=1} f && /^[[:space:]]*name:[[:space:]]*/ {print $2; exit}' execution-environment.yml)"
PYPKG="$(awk '/package_system:/ {print $2; exit}' execution-environment.yml)"
PYCMD="$(awk '/python_path:/ {print $2; exit}' execution-environment.yml)"
NET="${PODMAN_NETWORK:-bridge}"

echo "==> base image: $BASE_IMAGE  python: $PYPKG ($PYCMD)"
podman run --rm -i --network="$NET" -v "$PWD:/src:ro" -e PYPKG="$PYPKG" -e PYCMD="$PYCMD" "$BASE_IMAGE" bash -s <<'INNER'
set -euo pipefail
export PATH=/usr/local/bin:$PATH PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore
log() { printf '\n==> %s\n' "$*"; }

log "Toolchain (same packages as the builder stage)"
curl -fsSL https://packages.microsoft.com/config/rhel/9/prod.repo -o /etc/yum.repos.d/microsoft-prod.repo
rpm --import https://packages.microsoft.com/keys/microsoft.asc
microdnf -y --nodocs --setopt=install_weak_deps=0 install "$PYPKG" "$PYPKG-devel" gcc krb5-devel git-core >/dev/null 2>&1
"$PYCMD" -m ensurepip --root / >/dev/null 2>&1
"$PYCMD" -m pip install -q ansible-core ansible-builder bindep
echo "$(ansible --version | head -1) / ansible-builder $(ansible-builder --version) / $("$PYCMD" --version)"

log "Installing collections from Galaxy + local_collections/ (resolves dependencies)"
mkdir -p /tmp/colls
# run from /src: tarball entries in requirements.yml are relative to the project directory
( cd /src && ansible-galaxy collection install -r requirements.yml -p /tmp/colls 2>&1 ) | grep -E "was installed successfully|ERROR|error" || true
echo "installed: $(find /tmp/colls/ansible_collections -mindepth 2 -maxdepth 2 -type d | wc -l) collections"

log "Introspection (ansible-builder): merged Python / system requirements"
mkdir -p /tmp/ctx
cp /src/execution-environment.yml /src/requirements.yml /src/requirements.txt /src/bindep.txt /tmp/ctx/
cp -r /src/files /tmp/ctx/files
cp -r /src/local_collections /tmp/ctx/local_collections
( cd /tmp/ctx && ansible-builder create -f execution-environment.yml -c context --output-filename Containerfile >/dev/null )
B=/tmp/ctx/context/_build
args=(--user-pip="$B/requirements.txt" --user-bindep="$B/bindep.txt")
[[ -f "$B/exclude-requirements.txt" ]] && args+=(--exclude-pip-reqs="$B/exclude-requirements.txt")
[[ -f "$B/exclude-bindep.txt" ]]       && args+=(--exclude-bindep-reqs="$B/exclude-bindep.txt")
[[ -f "$B/exclude-collections.txt" ]]  && args+=(--exclude-collection-reqs="$B/exclude-collections.txt")
"$PYCMD" "$B/scripts/introspect.py" introspect "${args[@]}" \
    --write-pip=/tmp/merged-requirements.txt --write-bindep=/tmp/merged-bindep.txt /tmp/colls

log "System packages for this platform (bindep) and their availability"
{ bindep -l newline -f /tmp/merged-bindep.txt || true; bindep -l newline -f /tmp/merged-bindep.txt compile || true; echo "$PYPKG"; } \
    | sed '/^[[:space:]]*$/d' | sort -u > /tmp/rpm-packages.txt
missing=0
while read -r pkg; do
    if microdnf repoquery "$pkg" 2>/dev/null | grep -q .; then echo "  ok       $pkg"; else echo "  MISSING  $pkg"; missing=1; fi
done < /tmp/rpm-packages.txt

log "Python requirement set: pip dry run on $("$PYCMD" --version)"
if "$PYCMD" -m pip install --dry-run -r /tmp/merged-requirements.txt ansible-core ansible-runner dumb-init==1.2.5 > /tmp/pip-dry-run.log 2>&1; then
    grep -E "^Would install" /tmp/pip-dry-run.log | tr ' ' '\n' | sed '1d' | sort | tr '\n' ' ' | fold -s -w 110 | sed 's/^/  /'
    echo
    echo "  $(grep -E '^Would install' /tmp/pip-dry-run.log | wc -w) packages resolve"
else
    tail -n 30 /tmp/pip-dry-run.log
    echo "ERROR: the Python requirement set does not resolve"
    exit 1
fi

if (( missing )); then echo; echo "ERROR: some RPMs are not available (see MISSING above)"; exit 1; fi
log "check-deps.sh finished: dependency set looks good"
INNER
