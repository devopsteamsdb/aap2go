#!/usr/bin/env bash
# ==============================================================================
# image-info.sh - print a Markdown summary of what is inside an image
# (versions, collections, PowerShell modules, Python packages). Used for the
# GitHub release notes and the workflow job summary.
#
# Usage: tools/image-info.sh IMAGE [> image-info.md]
# ==============================================================================
set -euo pipefail
IMAGE="${1:?usage: image-info.sh IMAGE}"

run()   { podman run --rm "$IMAGE" "$@" 2>/dev/null; }
pyver() { run python3.12 -c "from importlib.metadata import version; print(version('$1'))" || echo "n/a"; }
pwver() { run pwsh -NoProfile -NonInteractive -Command "$1" || echo "n/a"; }

cat <<EOF
## aap2go execution environment

| Component | Version |
|-----------|---------|
| ansible-core | $(pyver ansible-core) |
| ansible (community package) | $(pyver ansible) |
| ansible-runner | $(pyver ansible-runner) |
| ansible-lint | $(pyver ansible-lint) |
| Python | $(run python3.12 --version | awk '{print $2}') |
| PowerShell | $(pwver '$PSVersionTable.PSVersion.ToString()') |
| VMware.PowerCLI | $(pwver '(Get-Module -ListAvailable VMware.PowerCLI | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()') |
| dbatools | $(pwver '(Get-Module -ListAvailable dbatools | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()') |
| pywinrm / pypsrp / pyspnego | $(pyver pywinrm) / $(pyver pypsrp) / $(pyver pyspnego) |
| Base image | $(run cat /etc/redhat-release) |
| Image size | $(podman image inspect --format '{{.Size}}' "$IMAGE" | awk '{printf "%.0f MB", $1/1024/1024}') |

<details>
<summary>Ansible collections</summary>

\`\`\`
$(run ansible-galaxy collection list 2>/dev/null | sed -n '/^# \/usr\/share\/ansible/,/^$/p')
\`\`\`
</details>

<details>
<summary>PowerShell modules</summary>

\`\`\`
$(pwver 'Get-Module -ListAvailable | Sort-Object Name, Version -Descending | Group-Object Name | ForEach-Object { "{0,-40} {1}" -f $_.Name, $_.Group[0].Version }')
\`\`\`
</details>

<details>
<summary>Python packages</summary>

\`\`\`
$(run python3.12 -m pip list --format=columns --disable-pip-version-check)
\`\`\`
</details>

<details>
<summary>System packages (RPM)</summary>

\`\`\`
$(run rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort)
\`\`\`
</details>
EOF
