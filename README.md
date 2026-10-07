# aap2go – Ansible Automation Platform execution environment

[![Build execution environment](https://github.com/devopsteamsdb/aap2go/actions/workflows/build-ee.yml/badge.svg)](https://github.com/devopsteamsdb/aap2go/actions/workflows/build-ee.yml)

An [ansible-builder](https://ansible.readthedocs.io/projects/builder/) (schema v3) project that
builds an execution environment (EE) image for **Ansible Automation Platform / AWX** and for
running Ansible from a container anywhere. It is the successor of
[devopsteamsdb/ansible2go](https://github.com/devopsteamsdb/ansible2go): same collections, same
PowerShell modules, same publishing scheme – but a real execution environment (ansible-runner,
non-root, `/runner` work dir) on Red Hat UBI 9 with the latest ansible-core, built and published
by GitHub Actions.

| Component | Details |
|-----------|---------|
| Base image | `registry.access.redhat.com/ubi9/ubi-minimal` with Python 3.12 |
| Ansible | latest `ansible-core`, latest `ansible` community package, `ansible-runner`, `ansible-lint`, `mitogen` |
| Collections (latest from Galaxy, deps resolved) | ansible.netcommon, ansible.posix, ansible.utils, ansible.windows, check_point.mgmt, cisco.aci, cisco.ios, cisco.ise, community.crypto, community.docker, community.general, community.vmware, community.windows, containers.podman, dellemc.openmanage, f5networks.f5_modules, fortinet.console, fortinet.fortimanager, fortinet.fortios, fortinet.fortiswitch, fortinet.fortiweb, junipernetworks.junos, kubernetes.core, lowlydba.sqlserver, microsoft.ad, netapp.ontap, netbox.netbox, paloaltonetworks.panos, vmware.vmware, vmware.vmware_rest, **splunk.es** |
| Windows management | `winrm` + `psrp` connection plugins with every auth backend: pywinrm/pypsrp with Kerberos, NTLM and CredSSP (`pykerberos`, `gssapi`, `krb5`, `pyspnego`, `requests-kerberos/-ntlm/-credssp`), Kerberos client (`kinit`, `klist`) with container friendly defaults |
| PowerShell | pwsh 7 (Microsoft RHEL 9 repo) + modules: VMware.PowerCLI (CEIP off, invalid certificates ignored), VMware.vSphere.SsoAdmin, ImportExcel, PScribo, dbatools, SqlServerDsc, Cisco.IMC, Cisco.UCS.Core, Jenkins, PSWindowsUpdate, Pester, psCheckPoint, psPAS |
| Python extras | docker, kubernetes, netapp-lib, pyvmomi, jmespath, netaddr, lxml, sansldap, dnspython, dpapi-ng, … (plus everything the collections declare) |
| Tools | ssh, sshpass, git, rsync, tar/gzip/unzip, jq, wget, vi, nc (nmap-ncat), ping, expect, gpg |

Every GitHub release lists the exact versions that went into the image (ansible-core, ansible,
PowerShell, PowerCLI, all collections, Python and RPM packages).

## Images

| Registry | Image | Notes |
|----------|-------|-------|
| GitHub Container Registry | `ghcr.io/devopsteamsdb/aap2go:latest`, `:<YYYY_MM_DD_HH_MM>`, `:sha-<commit>` | pushed on every build of `main` |
| Docker Hub | `devopsteamsdb/devopsteamsdb:aap2go_latest`, `:aap2go_<YYYY_MM_DD_HH_MM>` | same repository / naming scheme as `ansible2go_*`; requires the `DOCKERHUB_USERNAME` / `DOCKERHUB_PASSWORD` secrets |
| GitHub release | `aap2go_<date>.tar.gz` (`podman load -i`) | release tag = workflow run number, like before |

```bash
podman pull ghcr.io/devopsteamsdb/aap2go:latest
podman run --rm ghcr.io/devopsteamsdb/aap2go:latest ansible --version
```

### Use it in Ansible Automation Platform / AWX

*Automation Execution → Infrastructure → Execution Environments → Create*: image
`ghcr.io/devopsteamsdb/aap2go:latest` (or the Docker Hub name), pull policy "Only pull the image
if not present" (or "Always" to follow `latest`), plus a registry credential if the package/repo is
private. Then select it on the job templates / projects.

### Use it like the old ansible2go image (plain docker/podman)

The image runs as user 1000 with `/runner` as work directory (AAP convention); mount your
project there:

```bash
alias ansible-playbook='podman run --rm -it -v "$PWD:/runner/project:Z" -w /runner/project ghcr.io/devopsteamsdb/aap2go:latest ansible-playbook'
alias ansible='podman run --rm -it -v "$PWD:/runner/project:Z" -w /runner/project ghcr.io/devopsteamsdb/aap2go:latest ansible'
ansible-playbook site.yml
# SSH key for Linux targets:  add  -v ~/.ssh/id_rsa:/runner/.ssh/id_rsa:ro   (file must be readable by uid 1000, or run with --user $(id -u):0)
```

## Managing Windows hosts

```yaml
ansible_connection: winrm            # or psrp (PowerShell Remoting Protocol, usually faster)
ansible_port: 5986
ansible_winrm_transport: kerberos    # ntlm / credssp / basic are available too
ansible_winrm_server_cert_validation: ignore
ansible_user: svc-ansible@EXAMPLE.COM
```

* Kerberos: `/etc/krb5.conf.d/ee.conf` sets a file credential cache and KDC discovery via DNS SRV
  records. Realm settings are not baked in: in AAP add a machine credential (AAP runs `kinit`), and
  if DNS discovery is not enough, expose `/etc/krb5.conf` to jobs (*Settings → Job settings → Paths
  to expose to isolated jobs*: `/etc/krb5.conf:/etc/krb5.conf:O`) or bake a customised
  `files/krb5.conf.example` into the image (see the comments in that file).
* `pwsh` and the PowerShell modules are available for control-side scripts
  (`ansible.builtin.command: pwsh -File ...`); `lowlydba.sqlserver` still needs `dbatools` on the
  Windows target.

## Building

The workflow `.github/workflows/build-ee.yml` runs on every push to `main` (build → smoke tests →
push to GHCR and Docker Hub → GitHub release with versions and the image archive), on pull
requests (build + tests only) and manually (*Actions → Run workflow*). Locally:

```bash
python3 -m pip install ansible-builder          # podman must be installed
./build.sh                                      # -> localhost/aap2go:latest  (ansible-builder build)
./test.sh                                       # smoke tests (also run in CI)
tools/image-info.sh localhost/aap2go:latest     # what is inside (release notes format)
tools/check-deps.sh                             # fast preflight of the dependency set (no full build)
```

Secrets / variables used by the workflow (all optional):

| Name | Purpose |
|------|---------|
| `DOCKERHUB_USERNAME`, `DOCKERHUB_PASSWORD` | push to Docker Hub (same names as in ansible2go) |
| `REDHAT_REGISTRY_USERNAME`, `REDHAT_REGISTRY_PASSWORD` | only when switching the base image to `registry.redhat.io/...` |
| variable `ATTACH_IMAGE_ARCHIVE=false` | do not attach the (large) image archive to releases |

`GITHUB_TOKEN` is enough for GHCR and the release. The first push creates the GHCR package as
*private*; make it public under *Packages → aap2go → Package settings* if anonymous pulls are wanted.

## Customising

| Want to… | Edit |
|----------|------|
| add / remove / pin collections | `requirements.yml` |
| Python packages | `requirements.txt` (collections' own requirements are merged automatically) |
| RPM packages | `bindep.txt` (UBI 9 BaseOS/AppStream/CRB + Microsoft repo; `[compile]` = builder stage only) |
| PowerShell modules | `files/powershell_modules.txt` |
| drop the big `ansible` community package | remove the `ansible` line in `requirements.txt` |
| Red Hat supported base image | `images.base_image.name: registry.redhat.io/ansible-automation-platform/ee-minimal-rhel9:latest`, remove `python_interpreter`, `ansible_core`, `ansible_runner` (pre-installed there) and set the `REDHAT_REGISTRY_*` secrets |
| image name / registries | `env:` block at the top of the workflow |

## Repository layout

```
execution-environment.yml          ansible-builder v3 definition
requirements.yml                   collections (Galaxy)
requirements.txt                   Python packages
bindep.txt                         RPM packages
files/powershell_modules.txt       PowerShell modules (PSGallery)
files/install-powershell-modules.ps1
files/krb5-ee.conf                 Kerberos defaults installed as /etc/krb5.conf.d/ee.conf
files/krb5.conf.example            example realm configuration (not installed)
build.sh                           ansible-builder build wrapper (used by CI)
test.sh                            smoke tests (used by CI)
tools/image-info.sh                release notes / job summary generator
tools/check-deps.sh                dependency preflight without a full build
.github/workflows/build-ee.yml     CI: build, test, publish, release
```

## Differences to ansible2go

* RHEL 9 UBI instead of Debian `python:3-slim`; `microdnf` package names in `bindep.txt`.
* Runs as uid 1000 with `/runner` (AAP/ansible-runner convention) instead of root with `/ansible`.
* `openshift` (Python) was dropped (`kubernetes.core` ≥ 2.0 does not use it); `pipx` is not
  needed inside an EE; the unused `CARKaim` package was not carried over.
* `telnet`, `cifs-utils` and `nfs-utils` are not available in the UBI repositories (`nmap-ncat`
  replaces telnet; mounting shares is impossible from a non-root EE anyway). The ISO tooling that
  `dellemc.openmanage` declares for `idrac_os_deployment` (`xorriso`, `syslinux`, `isomd5sum`) is
  excluded for the same reason. The Python 2 backports `enum34` / `ipaddress` that some SDKs drag
  in are removed after installation.
* Everything else – collections, PowerShell modules incl. PowerCLI settings, Python packages,
  tools, Docker Hub naming and GitHub releases with the image archive – is kept.
