#!/usr/bin/env bash
# Read-only prerequisite check for running product-service on k3s (CentOS/Rocky/Alma).
# Changes nothing on the machine.
#
#   Usage:  bash scripts/preflight.sh server              # on node1
#           bash scripts/preflight.sh agent NODE1_IP      # on node2 / node3
set -u

ROLE="${1:-server}"
SERVER_IP="${2:-}"
PASS=0; WARN=0; FAIL=0

ok()   { echo "  [ OK ]  $*"; PASS=$((PASS + 1)); }
warn() { echo "  [WARN]  $*"; WARN=$((WARN + 1)); }
fail() { echo "  [FAIL]  $*"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$ROLE" != "server" ] && [ "$ROLE" != "agent" ]; then
  echo "usage: $0 server | agent NODE1_IP"; exit 2
fi
if [ "$ROLE" = "agent" ] && [ -z "$SERVER_IP" ]; then
  echo "usage: $0 agent NODE1_IP"; exit 2
fi

echo "product-service preflight -- role: $ROLE -- host: $(hostname)"

section "Operating system"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  major="${VERSION_ID%%.*}"
  if [ "${major:-0}" -ge 9 ] 2>/dev/null; then
    ok "$PRETTY_NAME"
  else
    fail "$PRETTY_NAME is end-of-life; use CentOS Stream 9 / Rocky 9 / Alma 9"
  fi
else
  fail "cannot read /etc/os-release"
fi
[ "$(uname -m)" = "x86_64" ] || [ "$(uname -m)" = "aarch64" ] \
  && ok "architecture $(uname -m)" || fail "unsupported architecture $(uname -m)"

section "Identity (compare these across the 3 VMs -- they must all differ)"
host="$(hostname)"
case "$host" in
  localhost|localhost.localdomain) fail "hostname is '$host'; set one: sudo hostnamectl set-hostname node1" ;;
  *) ok "hostname: $host" ;;
esac
echo "          machine-id: $(cat /etc/machine-id 2>/dev/null || echo unknown)"
echo "          IP addresses: $(hostname -I 2>/dev/null)"

section "Resources"
cpus="$(nproc)"
[ "$cpus" -ge 2 ] && ok "$cpus CPUs" || warn "$cpus CPU; 2+ recommended"

mem_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
if [ "$ROLE" = "server" ]; then need_mem=3500; else need_mem=1800; fi
[ "$mem_mb" -ge "$need_mem" ] && ok "${mem_mb} MB RAM" \
  || warn "${mem_mb} MB RAM; ~$((need_mem / 1000 + 1)) GB recommended for a $ROLE (node1 also runs Postgres)"

for dir in / /var; do
  free_gb=$(df -Pk "$dir" | awk 'NR==2 {print int($4 / 1048576)}')
  [ "$free_gb" -ge 15 ] && ok "$free_gb GB free on $dir" || warn "$free_gb GB free on $dir; 15+ GB recommended (images + 5Gi Postgres volume)"
done

section "Privileges"
if [ "$(id -u)" -eq 0 ]; then
  ok "running as root"
elif sudo -n true 2>/dev/null; then
  ok "passwordless sudo available"
elif have sudo; then
  warn "sudo needs a password (fine, the install steps will prompt)"
else
  fail "sudo is not installed"
fi

section "Required commands"
for cmd in curl tar podman make; do
  have "$cmd" && ok "$cmd" || fail "$cmd missing -> sudo dnf install -y $cmd"
done
have ethtool && ok "ethtool (for the VMware flannel workaround if needed)" \
  || warn "ethtool missing -> sudo dnf install -y ethtool (only needed if pod networking misbehaves)"

section "SELinux"
if have getenforce; then
  mode="$(getenforce)"
  [ "$mode" = "Enforcing" ] && ok "SELinux $mode (k3s installer adds the k3s-selinux policy)" \
    || warn "SELinux $mode; Enforcing is recommended"
else
  warn "getenforce not found"
fi

section "Firewall"
if have firewall-cmd && systemctl is-active --quiet firewalld; then
  ok "firewalld is running"
  ports="$(sudo -n firewall-cmd --list-ports 2>/dev/null || firewall-cmd --list-ports 2>/dev/null)"
  if [ -z "$ports" ] && ! sudo -n true 2>/dev/null; then
    warn "cannot read firewall rules without sudo; re-run with sudo to check ports"
  else
    if [ "$ROLE" = "server" ]; then want="6443/tcp 10250/tcp 8472/udp"; else want="10250/tcp 8472/udp"; fi
    for p in $want; do
      echo "$ports" | grep -qw "$p" && ok "port $p open" || fail "port $p not open (see the firewall-cmd step)"
    done
    trusted="$(sudo -n firewall-cmd --zone=trusted --list-sources 2>/dev/null || firewall-cmd --zone=trusted --list-sources 2>/dev/null)"
    for cidr in 10.42.0.0/16 10.43.0.0/16; do
      echo "$trusted" | grep -qw "$cidr" && ok "$cidr trusted" || fail "$cidr not in trusted zone (see the firewall-cmd step)"
    done
  fi
else
  warn "firewalld not running (k3s works, but the VM is unprotected)"
fi

section "Time sync (TLS between nodes breaks with clock skew)"
if systemctl is-active --quiet chronyd; then
  ok "chronyd running"
else
  fail "chronyd not running -> sudo dnf install -y chrony && sudo systemctl enable --now chronyd"
fi

section "Internet access (downloads during install)"
for url in https://get.k3s.io https://github.com https://rpm.rancher.io \
           https://registry-1.docker.io/v2/ https://raw.githubusercontent.com https://pypi.org/simple/; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" || true)"
  if [ "$code" != "000" ]; then ok "reachable: $url"; else fail "cannot reach $url (proxy/DNS/firewall?)"; fi
done

if [ "$ROLE" = "agent" ]; then
  section "Connection to node1"
  if timeout 5 bash -c "exec 3<>/dev/tcp/$SERVER_IP/6443" 2>/dev/null; then
    ok "$SERVER_IP:6443 reachable"
  else
    fail "$SERVER_IP:6443 not reachable (k3s not installed on node1 yet, or its firewall blocks 6443)"
  fi
fi

section "Existing installs"
if have k3s; then warn "k3s already installed: $(k3s --version | head -1)"; else ok "no previous k3s install"; fi
if [ "$ROLE" = "server" ] && [ -d "$HOME/product-service" ]; then
  ok "project found at ~/product-service"
elif [ "$ROLE" = "server" ]; then
  warn "~/product-service not found; copy it over with scp before building"
fi

echo
echo "Result: $PASS ok, $WARN warnings, $FAIL failures"
[ "$FAIL" -eq 0 ]
