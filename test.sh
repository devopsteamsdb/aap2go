#!/usr/bin/env bash
# ==============================================================================
# test.sh - smoke tests for the built execution environment image (podman).
#
# Usage: ./test.sh [IMAGE]     default: first tag in execution-environment.yml
# Exit status is non-zero if any check fails. Used by the GitHub Actions workflow.
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE="${1:-$(awk '/^[[:space:]]*tags:/ {f=1; next} f && /^[[:space:]]*-/ {print $2; exit}' execution-environment.yml)}"
PASS=0
FAIL=0
FAILED=()

ok()   { printf '\033[1;32m    OK  %s\033[0m\n' "$*"; }
# check "<description>" <command ...>   (output of passing checks is shown, trimmed)
check() {
    local desc=$1 out
    shift
    if out=$("$@" 2>&1); then
        PASS=$((PASS + 1))
        ok "$desc"
        [[ -n "$out" ]] && printf '%s\n' "$out" | head -n 8 | sed 's/^/         /'
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$desc")
        printf '\033[1;31m    FAIL %s\033[0m\n' "$desc"
        printf '%s\n' "$out" | tail -n 25 | sed 's/^/         /'
    fi
}
run()    { podman run --rm "$IMAGE" "$@"; }
run_as() { local user=$1; shift; podman run --rm --user "$user" "$IMAGE" "$@"; }

printf '\n\033[1;34m==> Smoke testing %s\033[0m\n' "$IMAGE"
podman image exists "$IMAGE" || { echo "image $IMAGE not found" >&2; exit 1; }

check "ansible-core" \
    run bash -c 'ansible --version | head -1'
check "ansible-runner" \
    run bash -c 'echo "ansible-runner $(ansible-runner --version)"'
check "ansible community package" \
    run python3.12 -c 'import importlib.metadata as m; print("ansible", m.version("ansible"))'
check "every collection from requirements.yml is installed" \
    bash -c 'list=$(podman run --rm "'"$IMAGE"'" ansible-galaxy collection list 2>/dev/null); rc=0
             for c in $(awk "/^[[:space:]]*- name:/ {print \$3}" requirements.yml); do
                 line=$(printf "%s\n" "$list" | grep -E "^$c " | head -1) || { echo "MISSING: $c"; rc=1; continue; }
                 echo "$line"
             done; exit $rc'
check "Windows connection plugins load (winrm, psrp)" \
    run bash -c 'ansible-doc -t connection winrm >/dev/null && ansible-doc -t connection psrp >/dev/null && echo "winrm + psrp OK"'
check "Python libraries for Windows / Kerberos / NTLM / CredSSP" \
    run python3.12 -c 'import winrm, kerberos, pypsrp, spnego, gssapi, krb5, requests_ntlm, requests_kerberos, requests_credssp
from importlib.metadata import version
print(" | ".join(f"{p} {version(p)}" for p in ("pywinrm", "pypsrp", "pyspnego", "pykerberos", "gssapi", "krb5", "requests-credssp")))'
check "winrm / psrp connection plugins run (expect a connection refusal, not a missing library)" \
    run bash -c 'rc=0
                 for conn in winrm psrp; do
                     out=$(ansible -i "127.0.0.1," all -m ansible.windows.win_ping -e ansible_connection=$conn \
                           -e ansible_winrm_transport=ntlm -e ansible_psrp_auth=ntlm -e ansible_user=test -e ansible_password=test \
                           -e ansible_port=5986 -e ansible_winrm_connection_timeout=3 -e ansible_psrp_connection_timeout=3 2>&1 || true)
                     if printf "%s" "$out" | grep -Eqi "not installed|No module named|ImportError"; then
                         echo "$conn: missing dependency"; printf "%s\n" "$out" | tail -5; rc=1
                     else
                         echo "$conn: $(printf "%s\n" "$out" | grep -Eio "connection refused|unreachable|connection failure[^\"]*" | head -1)"
                     fi
                 done
                 exit $rc'
check "Python libraries carried over from ansible2go (docker, kubernetes, netapp-lib, mitogen, ansible-lint, ...)" \
    run python3.12 -c 'import docker, kubernetes, netapp_lib, mitogen, jmespath, pexpect, pyVmomi, lxml, sansldap, dns, netaddr
from importlib.metadata import version
print(" | ".join(f"{p} {version(p)}" for p in ("docker", "kubernetes", "netapp-lib", "mitogen", "ansible-lint", "ansible-parallel", "pyvmomi")))'
check "ansible-lint runs" \
    run bash -c 'ansible-lint --version | head -1'
check "no Python 2 backports shadowing the standard library (enum34, ipaddress)" \
    run python3.12 -c 'import enum, re, ipaddress, importlib.metadata as m
assert hasattr(enum, "IntFlag"), "stdlib enum is shadowed"
leftover = [p for p in ("enum34", "ipaddress") if any(d.metadata["Name"].lower() == p for d in m.distributions())]
assert not leftover, f"backport packages still installed: {leftover}"
print("stdlib enum/re/ipaddress OK")'
check "PowerShell Core" \
    run pwsh -NoProfile -NonInteractive -Command 'Write-Host ("PowerShell " + $PSVersionTable.PSVersion + " / " + $PSVersionTable.OS)'
check "PowerShell modules from files/powershell_modules.txt are available" \
    bash -c 'mods=$(grep -Ev "^\s*(#|$)" files/powershell_modules.txt | tr "\n" "," | sed "s/,$//")
             podman run --rm "'"$IMAGE"'" pwsh -NoProfile -NonInteractive -Command "
                 \$missing = @(); foreach (\$m in \"$mods\".Split(\",\")) {
                     \$mod = Get-Module -ListAvailable -Name \$m | Sort-Object Version -Descending | Select-Object -First 1
                     if (\$mod) { Write-Host (\"{0,-28} {1}\" -f \$mod.Name, \$mod.Version) } else { \$missing += \$m } }
                 if (\$missing) { Write-Host \"MISSING: \$missing\"; exit 1 }"'
check "PowerCLI configuration (ignore invalid certificates, CEIP off) applies to the runtime user" \
    run_as 1000:0 pwsh -NoProfile -NonInteractive -Command '$c = Get-PowerCLIConfiguration -Scope AllUsers; Write-Host ("InvalidCertificateAction=" + $c.InvalidCertificateAction + " ParticipateInCEIP=" + $c.ParticipateInCEIP); if ($c.InvalidCertificateAction -ne "Ignore") { exit 1 }'
check "Kerberos client tools (kinit, klist)" \
    run bash -c 'klist -V && command -v kinit'
check "system tools (ssh, sshpass, git, jq, wget, vi, nc, ping, expect, rsync, tar, gzip, unzip, gpg)" \
    run bash -c 'ssh -V 2>&1 | head -1; sshpass -V | head -1; git --version; jq --version; wget --version | head -1; vi --version | head -1
                 missing=""; for tool in nc ping expect rsync tar gzip unzip gpg kinit; do command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done
                 [ -z "$missing" ] && echo "nc ping expect rsync tar gzip unzip gpg kinit present" || { echo "MISSING:$missing"; exit 1; }'
check "ansible localhost ping" \
    run ansible localhost -m ansible.builtin.ping
check "ansible-runner end to end (private data dir + playbook)" \
    run bash -c 'set -e; mkdir -p /tmp/pdd/project
                 printf -- "- hosts: localhost\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug:\n        msg: hello from aap2go\n" > /tmp/pdd/project/site.yml
                 ansible-runner run /tmp/pdd -p site.yml'
check "arbitrary UID like OpenShift / AAP job pods (uid 12345, gid 0)" \
    run_as 12345:0 bash -c 'ansible localhost -m ansible.builtin.ping >/dev/null && pwsh -NoProfile -NonInteractive -Command "Write-Host (\"pwsh ok as uid \" + (id -u))"'
check "ansible-execution-environment label" \
    bash -c "podman image inspect --format '{{index .Labels \"ansible-execution-environment\"}}' '$IMAGE' | grep -qx true && echo true"

echo
if (( FAIL > 0 )); then
    printf '\033[1;31m%d passed, %d FAILED:\033[0m\n' "$PASS" "$FAIL"
    printf '    - %s\n' "${FAILED[@]}"
    exit 1
fi
printf '\033[1;32mAll %d checks passed for %s\033[0m\n' "$PASS" "$IMAGE"
