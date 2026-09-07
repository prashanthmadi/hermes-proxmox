#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Allow a trusted client's current IP to reach the Hermes HTTP gateway.

Normal use on the Proxmox host:
  ./set-hermes-client-ip.sh

Options needed only when auto-detection is unavailable or multiple Hermes LXCs exist:
  --client-ip IP    Trusted client IPv4 address
  --ctid ID         Hermes LXC ID
  -h, --help
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

CLIENT_IP=""
CTID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-ip)
      [[ $# -ge 2 && -n "$2" ]] || die "--client-ip requires an IPv4 address"
      CLIENT_IP="$2"
      shift 2
      ;;
    --ctid)
      [[ $# -ge 2 && -n "$2" ]] || die "--ctid requires a container ID"
      CTID="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found"
command -v python3 >/dev/null || die "python3 not found"

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

if [[ -z "$CTID" ]]; then
  mapfile -t HERMES_CTIDS < <(
    pct list | awk 'NR > 1 {print $1}' | while read -r candidate; do
      pct config "$candidate" 2>/dev/null \
        | grep -Eq '^tags: ([^;]+;)*hermes-agent(;|$)' \
        && printf '%s\n' "$candidate"
    done
  )
  [[ ${#HERMES_CTIDS[@]} -eq 1 ]] || die "Could not uniquely detect a running Hermes LXC; pass --ctid"
  CTID="${HERMES_CTIDS[0]}"
fi
[[ "$CTID" =~ ^[1-9][0-9]*$ ]] || die "Invalid CTID"
[[ "$(pct status "$CTID" 2>/dev/null)" == *running* ]] || die "CTID $CTID is not running"

pct exec "$CTID" -- env NEW_CLIENT_CIDR="$CLIENT_CIDR" python3 - <<'PY'
import os
import pathlib
import re
import subprocess
import tempfile

path = pathlib.Path("/etc/nftables.conf")
original = path.read_text(encoding="utf-8")
pattern = r"(?m)^(\s*ip saddr )\S+( tcp dport 9119 ct state new accept\s*)$"
updated, count = re.subn(pattern, rf"\g<1>{os.environ['NEW_CLIENT_CIDR']}\g<2>", original)
if count != 1:
    raise SystemExit("Expected exactly one Hermes HTTP firewall rule; no changes applied")

descriptor, temporary_name = tempfile.mkstemp(prefix="nftables.", dir="/etc")
temporary = pathlib.Path(temporary_name)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(updated)
    subprocess.run(["nft", "-c", "-f", str(temporary)], check=True)
    os.replace(temporary, path)
    try:
        subprocess.run(["nft", "-f", str(path)], check=True)
    except Exception:
        path.write_text(original, encoding="utf-8")
        subprocess.run(["nft", "-f", str(path)], check=False)
        raise
finally:
    temporary.unlink(missing_ok=True)
PY

printf 'Hermes LXC %s now accepts HTTP gateway traffic only from %s.\n' "$CTID" "$CLIENT_CIDR"
