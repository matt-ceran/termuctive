"""One-time, idempotent preparation of a Termuctive server.

Runs as root from Termuctive's setup sheet in a visible terminal, so every step
prints what it is doing and failures stay readable.
"""

import ipaddress
import json
import os
import platform
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

from . import VERSION, admin, paths, proc, validate

BASE_PACKAGES = [
    "acl",
    "ca-certificates",
    "curl",
    "git",
    "gnupg",
    "jq",
    "lsof",
    "ncurses-term",
    "pciutils",
    "python3",
    "python3-venv",
    "rsync",
    "sqlite3",
    "tmux",
    "unzip",
]
FULL_PACKAGES = [
    "build-essential",
    "ffmpeg",
    "htop",
    "python3-pip",
    "unattended-upgrades",
]

SSHD_DROP_IN = "/etc/ssh/sshd_config.d/10-termuctive.conf"
LOGIND_DROP_IN = "/etc/systemd/logind.conf.d/termuctive.conf"
UNATTENDED_DROP_IN = "/etc/apt/apt.conf.d/52termuctive-unattended"


@dataclass
class SetupOptions:
    admin_user: str
    member: Optional[str] = None
    member_home: Optional[str] = None
    member_key: Optional[str] = None
    hostname: Optional[str] = None
    node_major: int = 22
    container: bool = False
    minimal: bool = False
    tailscale: bool = True
    firewall: bool = True
    gpu: bool = True
    docker: bool = False
    awscli: bool = True
    claude: bool = True
    swap_gigabytes: int = 8


@dataclass
class SetupResult:
    reboot_required: bool = False
    warnings: List[str] = field(default_factory=list)
    tailscale: Dict[str, object] = field(default_factory=dict)


def apt_install(packages: List[str]) -> None:
    missing = [package for package in packages if not dpkg_installed(package)]
    if not missing:
        return
    proc.note("Installing " + ", ".join(missing))
    environment = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    proc.run(["apt-get", "update", "-qq"], env=environment)
    proc.run(
        ["apt-get", "install", "-y", "-qq", "--no-install-recommends", *missing],
        env=environment,
    )


def dpkg_installed(package: str) -> bool:
    result = subprocess.run(
        ["dpkg-query", "-W", "-f=${Status}", package],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.returncode == 0 and "install ok installed" in result.stdout


def shell(script: str) -> None:
    """Runs a fixed installer pipeline. Never receives user-controlled text."""
    proc.run(["bash", "-o", "pipefail", "-c", script], capture=False)


def node_major() -> Optional[int]:
    version = proc.output(["node", "--version"])
    if not version:
        return None
    try:
        return int(version.strip().lstrip("v").split(".")[0])
    except ValueError:
        return None


def install_node(major: int) -> None:
    if node_major() == major:
        return
    proc.note(f"Installing Node.js {major}")
    shell(f"curl -fsSL https://deb.nodesource.com/setup_{major}.x | bash -")
    proc.run(["apt-get", "install", "-y", "-qq", "nodejs"])


def install_uv() -> None:
    if proc.have("uv"):
        return
    proc.note("Installing uv")
    shell(
        "curl -LsSf https://astral.sh/uv/install.sh"
        " | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh"
    )


def install_gh() -> None:
    if proc.have("gh"):
        return
    proc.note("Installing the GitHub CLI")
    shell(
        "mkdir -p -m 755 /etc/apt/keyrings"
        " && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg"
        " -o /etc/apt/keyrings/githubcli-archive-keyring.gpg"
        " && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg"
        ' && echo "deb [arch=$(dpkg --print-architecture)'
        " signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg]"
        ' https://cli.github.com/packages stable main"'
        " > /etc/apt/sources.list.d/github-cli.list"
        " && apt-get update -qq && apt-get install -y -qq gh"
    )


def install_awscli() -> None:
    if proc.have("aws"):
        return
    proc.note("Installing the AWS CLI")
    shell(
        'workdir=$(mktemp -d) && cd "$workdir"'
        ' && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip"'
        " -o awscliv2.zip && unzip -q awscliv2.zip && ./aws/install --update"
        ' && cd / && rm -rf "$workdir"'
    )


def install_docker(members: List[str]) -> None:
    apt_install(["docker.io", "docker-compose-v2"])
    for member in members:
        admin.add_to_group(member, "docker")


def configure_swap(gigabytes: int) -> None:
    existing = proc.output(["swapon", "--show", "--noheadings"])
    if existing and existing.strip():
        return
    proc.note(f"Creating a {gigabytes} GB swap file")
    swapfile = Path("/swapfile")
    if not swapfile.exists():
        proc.run(["fallocate", "-l", f"{gigabytes}G", str(swapfile)])
        os.chmod(swapfile, 0o600)
        proc.run(["mkswap", str(swapfile)])
    proc.run(["swapon", str(swapfile)], check=False)
    fstab = Path("/etc/fstab")
    if "/swapfile" not in fstab.read_text():
        with fstab.open("a") as handle:
            handle.write("/swapfile none swap sw 0 0\n")


def configure_power() -> None:
    proc.run(
        [
            "systemctl",
            "mask",
            "sleep.target",
            "suspend.target",
            "hibernate.target",
            "hybrid-sleep.target",
        ],
        check=False,
    )
    write_file(
        LOGIND_DROP_IN,
        "[Login]\nKillUserProcesses=no\nHandleLidSwitch=ignore\nIdleAction=ignore\n",
    )


def configure_unattended_upgrades() -> None:
    write_file(UNATTENDED_DROP_IN, 'Unattended-Upgrade::Automatic-Reboot "false";\n')


def sshd_drop_in(disable_passwords: bool) -> str:
    lines = [
        "# Managed by Termuctive.",
        "MaxSessions 32",
        "MaxStartups 30:30:100",
        "ClientAliveInterval 30",
        "ClientAliveCountMax 4",
        "AcceptEnv LANG LC_* COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION",
        "PermitRootLogin no",
    ]
    if disable_passwords:
        lines += ["PasswordAuthentication no", "KbdInteractiveAuthentication no"]
    return "\n".join(lines) + "\n"


def configure_sshd(admin_user: str, container: bool, result: SetupResult) -> None:
    authorized = Path(os.path.expanduser(f"~{admin_user}")) / ".ssh" / "authorized_keys"
    has_key = authorized.exists() and authorized.read_text().strip() != ""
    if not has_key:
        result.warnings.append(
            "Password sign-in stays enabled because the admin account has no SSH key yet."
        )
    write_file(SSHD_DROP_IN, sshd_drop_in(disable_passwords=has_key))
    check = subprocess.run(["sshd", "-t"], stderr=subprocess.PIPE, text=True)
    if check.returncode != 0:
        os.unlink(SSHD_DROP_IN)
        result.warnings.append("Skipped SSH tuning: " + check.stderr.strip())
        return
    if container:
        subprocess.run(["pkill", "-HUP", "-o", "-x", "sshd"], check=False)
    else:
        subprocess.run(["systemctl", "reload", "ssh"], check=False)


def tailscale_status() -> Dict[str, object]:
    raw = proc.output(["tailscale", "status", "--json"])
    if not raw:
        return {}
    try:
        status = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    own = status.get("Self") or {}
    return {
        "state": status.get("BackendState"),
        "dnsName": (own.get("DNSName") or "").rstrip("."),
        "addresses": own.get("TailscaleIPs") or [],
    }


def configure_tailscale(hostname: Optional[str], result: SetupResult) -> None:
    if not proc.have("tailscale"):
        proc.note("Installing Tailscale")
        shell("curl -fsSL https://tailscale.com/install.sh | sh")
    if tailscale_status().get("state") != "Running":
        proc.note("Sign this server in to Tailscale using the link below.")
        command = ["tailscale", "up"]
        if hostname:
            command += ["--hostname", hostname]
        proc.run(command, capture=False)
    result.tailscale = tailscale_status()


def lan_networks() -> List[str]:
    raw = proc.output(["ip", "-o", "-4", "addr", "show", "scope", "global"])
    networks = []
    for line in (raw or "").splitlines():
        fields = line.split()
        if len(fields) < 4 or fields[1].startswith(("tailscale", "docker", "br-")):
            continue
        try:
            network = ipaddress.ip_interface(fields[3]).network
        except ValueError:
            continue
        if network.is_private:
            networks.append(str(network))
    return networks


def client_address() -> Optional[str]:
    connection = os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_CLIENT") or ""
    return connection.split()[0] if connection else None


def ssh_source_allowed(source: Optional[str], networks: List[str]) -> bool:
    if source is None:
        return True
    try:
        address = ipaddress.ip_address(source)
    except ValueError:
        return False
    tailnet = ipaddress.ip_network("100.64.0.0/10")
    if address in tailnet:
        return True
    return any(address in ipaddress.ip_network(network) for network in networks)


def configure_firewall(result: SetupResult) -> None:
    apt_install(["ufw"])
    networks = lan_networks()
    source = client_address()
    if not ssh_source_allowed(source, networks):
        result.warnings.append(
            f"Skipped the firewall because this connection comes from {source}, "
            "which is neither the local network nor Tailscale."
        )
        return
    proc.run(["ufw", "default", "deny", "incoming"])
    proc.run(["ufw", "default", "allow", "outgoing"])
    proc.run(["ufw", "allow", "in", "on", "tailscale0"])
    for network in networks:
        proc.run(["ufw", "allow", "from", network, "to", "any", "port", "22", "proto", "tcp"])
    proc.run(["ufw", "--force", "enable"])


def configure_gpu(result: SetupResult) -> None:
    devices = proc.output(["lspci"]) or ""
    if "nvidia" not in devices.lower():
        return
    if proc.have("nvidia-smi"):
        return
    proc.note("Installing NVIDIA drivers for the GPU")
    apt_install(["ubuntu-drivers-common"])
    proc.run(["ubuntu-drivers", "install"], capture=False)
    result.reboot_required = True


def create_directories() -> None:
    for directory in ("projects", "meta", "shared", "run"):
        (paths.srv_root() / directory).mkdir(mode=0o755, parents=True, exist_ok=True)
    Path("/Users").mkdir(mode=0o755, exist_ok=True)


def write_file(path: str, content: str, mode: int = 0o644) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.read_text() == content:
        return
    target.write_text(content)
    os.chmod(target, mode)


def check_platform(result: SetupResult) -> None:
    release = Path("/etc/os-release")
    text = release.read_text() if release.exists() else ""
    if 'VERSION_ID="24.04"' not in text:
        result.warnings.append("This server is not Ubuntu 24.04; some steps may not apply.")
    if platform.machine() not in {"x86_64", "aarch64"}:
        result.warnings.append(f"Untested CPU architecture {platform.machine()}.")


def run_setup(options: SetupOptions) -> SetupResult:
    admin.require_root()
    result = SetupResult()
    options.admin_user = validate.user(options.admin_user)
    if options.member:
        options.member = validate.user(options.member)
        options.member_home = validate.home_path(options.member_home or "")
        options.member_key = validate.public_key(options.member_key or "")
    if options.hostname:
        options.hostname = validate.hostname(options.hostname)

    proc.step(f"Termuctive server setup (toolkit {VERSION})")
    check_platform(result)

    proc.step("Installing packages")
    apt_install(BASE_PACKAGES + ([] if options.minimal else FULL_PACKAGES))
    if not options.minimal:
        install_node(options.node_major)
        install_uv()
        install_gh()
        if options.awscli:
            install_awscli()

    proc.step("Preparing Termuctive folders")
    create_directories()

    proc.step("Configuring the administrator account")
    admin.grant_admin(options.admin_user)

    if options.member:
        proc.step(f"Creating your account ({options.member})")
        admin.user_add(options.member, options.member_home, options.member_key)
        if options.docker:
            install_docker([options.member])

    if not options.container:
        proc.step("Keeping the server awake")
        configure_power()
        if not options.minimal:
            configure_unattended_upgrades()
        configure_swap(options.swap_gigabytes)

    proc.step("Configuring SSH")
    configure_sshd(options.admin_user, options.container, result)

    if options.tailscale and not options.container:
        proc.step("Connecting to Tailscale")
        configure_tailscale(options.hostname, result)

    if options.firewall and not options.container:
        proc.step("Configuring the firewall")
        configure_firewall(result)

    if options.gpu and not options.container:
        proc.step("Checking for a GPU")
        configure_gpu(result)

    if options.member and options.claude:
        proc.step("Installing Claude Code")
        try:
            admin.install_claude(options.member)
        except proc.CommandError as error:
            result.warnings.append(f"Claude Code was not installed: {error}")

    if Path("/var/run/reboot-required").exists():
        result.reboot_required = True

    for warning in result.warnings:
        proc.warn(warning)
    proc.step("Termuctive setup finished.")
    print(
        "TMC-SETUP-RESULT "
        + json.dumps(
            {
                "version": VERSION,
                "rebootRequired": result.reboot_required,
                "tailscale": result.tailscale,
                "warnings": result.warnings,
            },
            sort_keys=True,
        ),
        flush=True,
    )
    return result


def which_or_none(name: str) -> Optional[str]:
    return shutil.which(name)
