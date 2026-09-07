#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CLIENT_IP=""
CREATED=0
COMPLETE=0
CTID=""
WORK_DIR=""

usage() {
  cat <<'EOF'
Create a secure Proxmox LXC for Hermes Desktop's HTTP gateway mode.

Normal use on the Proxmox host:
  ./create-hermes-lxc.sh

The script automatically selects the next CTID, primary bridge, suitable
storage, and Debian template. It prompts for the trusted client IP when it
cannot infer it from an SSH session.

Optional:
  --client-ip IP    Trusted client IPv4 address
  -h, --help
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
  if [[ $exit_code -ne 0 && $CREATED -eq 1 && $COMPLETE -eq 0 ]]; then
    printf 'Provisioning failed; removing incomplete CTID %s.\n' "$CTID" >&2
    pct stop "$CTID" --skiplock 1 >/dev/null 2>&1 || true
    pct destroy "$CTID" --purge 1 >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-ip)
      [[ $# -ge 2 && -n "$2" ]] || die "--client-ip requires an IPv4 address"
      CLIENT_IP="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run as root on the Proxmox host"
for command in pct pveam pvesh pvesm python3 ip dpkg; do
  command -v "$command" >/dev/null || die "Missing Proxmox dependency: $command"
done

if [[ -z "$CLIENT_IP" && -n "${SSH_CLIENT:-}" ]]; then
  CLIENT_IP="${SSH_CLIENT%% *}"
fi
if [[ -z "$CLIENT_IP" ]]; then
  read -r -p "Trusted client IPv4 address: " CLIENT_IP
fi
CLIENT_CIDR="$(python3 - "$CLIENT_IP" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
private_networks = (
  ipaddress.ip_network("10.0.0.0/8"),
  ipaddress.ip_network("172.16.0.0/12"),
  ipaddress.ip_network("192.168.0.0/16"),
)
if address.version != 4 or not any(address in network for network in private_networks):
    raise SystemExit(1)
print(f"{address}/32")
PY
)" || die "Could not detect a private client IPv4 address; pass --client-ip"

read -r -s -p "Hermes Desktop password (16+ characters): " DASHBOARD_PASSWORD
printf '\n'
[[ ${#DASHBOARD_PASSWORD} -ge 16 ]] || die "Password must contain at least 16 characters"
read -r -s -p "Confirm password: " DASHBOARD_PASSWORD_CONFIRM
printf '\n'
[[ "$DASHBOARD_PASSWORD" == "$DASHBOARD_PASSWORD_CONFIRM" ]] || die "Passwords do not match"
unset DASHBOARD_PASSWORD_CONFIRM

CTID="$(pvesh get /cluster/nextid 2>/dev/null)"
[[ "$CTID" =~ ^[1-9][0-9]*$ ]] || die "Could not obtain the next Proxmox CTID"

BRIDGE="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
if [[ -z "$BRIDGE" || ! -d "/sys/class/net/$BRIDGE/bridge" ]]; then
  mapfile -t BRIDGES < <(find /sys/class/net -mindepth 2 -maxdepth 2 -name bridge -printf '%h\n' | xargs -r -n1 basename)
  [[ ${#BRIDGES[@]} -eq 1 ]] || die "Could not uniquely detect the Proxmox bridge"
  BRIDGE="${BRIDGES[0]}"
fi

pick_storage() {
  local content="$1"
  pvesm status --content "$content" 2>/dev/null \
    | awk 'NR > 1 && $3 == "active" {print $1, $6}' \
    | sort -k2,2nr \
    | awk 'NR == 1 {print $1}'
}

ROOT_STORAGE="$(pick_storage rootdir)"
TEMPLATE_STORAGE="$(pick_storage vztmpl)"
[[ -n "$ROOT_STORAGE" ]] || die "No active storage supports LXC root disks"
[[ -n "$TEMPLATE_STORAGE" ]] || die "No active storage supports LXC templates"

ARCH="$(dpkg --print-architecture)"
pveam update
TEMPLATE_NAME="$(pveam available --section system \
  | awk -v arch="$ARCH" '$2 ~ "^debian-12-standard_.*_" arch "\\.tar\\.(zst|gz)$" {print $2}' \
  | sort -V | tail -n1)"
[[ -n "$TEMPLATE_NAME" ]] || die "No Debian 12 template is available for $ARCH"
TEMPLATE_VOLUME="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
if ! pvesm path "$TEMPLATE_VOLUME" >/dev/null 2>&1; then
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
fi

WORK_DIR="$(mktemp -d)"
printf '%s' "$DASHBOARD_PASSWORD" > "$WORK_DIR/dashboard-password"
unset DASHBOARD_PASSWORD

printf 'Creating Hermes LXC %s on %s using %s...\n' "$CTID" "$BRIDGE" "$ROOT_STORAGE"
pct create "$CTID" "$TEMPLATE_VOLUME" \
  --hostname "hermes-$CTID" \
  --ostype debian \
  --unprivileged 1 \
  --cores 4 \
  --memory 4096 \
  --swap 1024 \
  --rootfs "${ROOT_STORAGE}:16" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,type=veth" \
  --onboot 1 \
  --startup order=30,up=30 \
  --tags hermes-agent \
  --description "Hermes Agent; authenticated LAN gateway for Hermes Desktop"
CREATED=1
pct start "$CTID"

for attempt in {1..60}; do
  SYSTEM_STATE="$(pct exec "$CTID" -- systemctl is-system-running 2>/dev/null || true)"
  if [[ "$SYSTEM_STATE" == "running" || "$SYSTEM_STATE" == "degraded" ]]; then
    break
  fi
  [[ "$attempt" -lt 60 ]] || die "Container did not finish booting (systemd state: ${SYSTEM_STATE:-unknown})"
  sleep 1
done

pct push "$CTID" "$WORK_DIR/dashboard-password" /root/hermes-dashboard-password -perms 0600

printf 'Installing and hardening Hermes...\n'
pct exec "$CTID" -- env CLIENT_CIDR="$CLIENT_CIDR" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y dist-upgrade
apt-get install -y --no-install-recommends \
  ca-certificates curl git jq nftables openssl unattended-upgrades
apt-get purge -y openssh-server
apt-get clean
rm -rf /var/lib/apt/lists/*

id hermes >/dev/null 2>&1 || useradd --create-home --shell /bin/bash hermes

cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iifname "lo" accept
    ct state established,related accept
    ct state invalid drop
    ip protocol icmp accept
    meta l4proto ipv6-icmp accept
    ip saddr $CLIENT_CIDR tcp dport 9119 ct state new accept
  }
  chain forward { type filter hook forward priority 0; policy drop; }
  chain output { type filter hook output priority 0; policy accept; }
}
EOF
nft -c -f /etc/nftables.conf
systemctl enable --now nftables

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

INSTALLER="$(mktemp)"
trap 'rm -f "$INSTALLER"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL \
  https://hermes-agent.nousresearch.com/install.sh -o "$INSTALLER"
chown hermes:hermes "$INSTALLER"
runuser -u hermes -- env HOME=/home/hermes bash "$INSTALLER" \
  --non-interactive --skip-setup --skip-computer-use
rm -f "$INSTALLER"
trap - EXIT

HERMES=/home/hermes/.hermes/hermes-agent/venv/bin/hermes
HERMES_PYTHON=/home/hermes/.hermes/hermes-agent/venv/bin/python
[[ -x "$HERMES" ]] || { echo "Hermes launcher was not installed" >&2; exit 1; }
[[ -x "$HERMES_PYTHON" ]] || { echo "Hermes Python was not installed" >&2; exit 1; }
runuser -u hermes -- "$HERMES" --version

trap 'rm -f /root/hermes-dashboard-password' EXIT
PASSWORD_HASH="$(cd /home/hermes/.hermes/hermes-agent && runuser -u hermes -- "$HERMES_PYTHON" -c \
  'import sys; from plugins.dashboard_auth.basic import hash_password; print(hash_password(sys.stdin.read()))' \
  < /root/hermes-dashboard-password)"
rm -f /root/hermes-dashboard-password
trap - EXIT
[[ "$PASSWORD_HASH" == scrypt\$* ]] || { echo "Password hashing failed" >&2; exit 1; }
SIGNING_SECRET="$(openssl rand -base64 48 | tr -d '\n')"
[[ ${#SIGNING_SECRET} -ge 43 ]] || { echo "Signing secret generation failed" >&2; exit 1; }

AUTH_ENV=/home/hermes/.hermes/dashboard-auth.env
cat > "$AUTH_ENV" <<EOF
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$PASSWORD_HASH
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$SIGNING_SECRET
HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=43200
EOF
chown hermes:hermes "$AUTH_ENV"
chmod 0600 "$AUTH_ENV"

cat > /etc/systemd/system/hermes-serve.service <<EOF
[Unit]
Description=Hermes Agent remote backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hermes
Group=hermes
Environment=HOME=/home/hermes
Environment=HERMES_HOME=/home/hermes/.hermes
Environment=PATH=/home/hermes/.hermes/node/bin:/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=$AUTH_ENV
WorkingDirectory=/home/hermes
ExecStart=$HERMES serve --host 0.0.0.0 --port 9119
Restart=on-failure
RestartSec=5
TimeoutStopSec=45
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectKernelLogs=yes
ProtectClock=yes
RestrictSUIDSGID=yes
LockPersonality=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now hermes-serve.service

for attempt in $(seq 1 30); do
  curl -fsS http://127.0.0.1:9119/api/status >/tmp/hermes-status.json 2>/dev/null && break
  if [[ "$attempt" -eq 30 ]]; then
    journalctl -u hermes-serve.service --no-pager -n 100 >&2
    exit 1
  fi
  sleep 2
done
jq -e '.auth_required == true and (.auth_providers | index("basic") != null)' \
  /tmp/hermes-status.json >/dev/null
rm -f /tmp/hermes-status.json
CONTAINER_SCRIPT

LXC_IP=""
for attempt in {1..30}; do
  LXC_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\./) {print $i; exit}}')"
  [[ -z "$LXC_IP" ]] || break
  sleep 1
done
[[ -n "$LXC_IP" ]] || die "Hermes installed, but the DHCP address could not be determined"

COMPLETE=1
printf '\nHermes LXC is ready.\n'
printf '  CTID: %s\n  URL:  http://%s:9119\n  User: admin\n' "$CTID" "$LXC_IP"
printf '\nIn Hermes Desktop, add a Remote gateway with the URL above and sign in.\n'
printf 'Configure Hermes from the Proxmox shell with:\n'
printf '  pct exec %s -- runuser -u hermes -- %s setup\n' "$CTID" "/home/hermes/.hermes/hermes-agent/venv/bin/hermes"
