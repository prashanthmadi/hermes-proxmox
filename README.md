# Hermes Agent on Proxmox LXC

This creates an unprivileged Debian LXC for
[Hermes Agent](https://github.com/NousResearch/hermes-agent). Hermes Desktop
connects directly to a persistent HTTP gateway on the home LAN. The gateway is
protected by Hermes username/password authentication and an LXC firewall rule
that permits only one trusted client IPv4 address.

This design is for a trusted private LAN. HTTP does not encrypt traffic. Never
forward port `9119` on the router or expose it to the internet; use a VPN and
TLS or an OAuth provider for access beyond the home network.

## Requirements

- A Proxmox VE host with internet access and DHCP on an attached Linux bridge
- Root access to the Proxmox shell
- A private IPv4 address for the device running Hermes Desktop
- Storage enabled for both container templates and LXC root disks

## Install

Place both scripts in `/root` on the Proxmox host. If remote access to Proxmox
is unavailable, use the Proxmox console to upload or paste them. Then run:

```bash
chmod 700 /root/create-hermes-lxc.sh /root/set-hermes-client-ip.sh
/root/create-hermes-lxc.sh
```

Enter the trusted client's current IPv4 address when prompted, then choose and confirm
a password of at least 16 characters. The plaintext password is removed after
the script creates its scrypt hash.

The script automatically chooses the next CTID, primary Proxmox bridge, active
storage with the most free space, latest Debian 12/13 template, and DHCP
networking. It creates a 4-core, 4 GB RAM, 16 GB unprivileged LXC, runs Hermes
as a non-root service, permits port `9119` only from the trusted client's `/32`, and
enables Debian security updates. SSH is not installed in the LXC.

## Connect

The script prints the assigned LXC IP and gateway URL. Configure Hermes from
the Proxmox host, replacing `CTID`:

```bash
pct exec CTID -- runuser -u hermes -- \
	/home/hermes/.hermes/hermes-agent/venv/bin/hermes setup
```

In Hermes Desktop, open **Settings -> Gateways -> Add connection**:

- Kind: **Remote gateway**
- URL: `http://LXC_IP:9119`
- Username: `admin`
- Password: the password entered during installation

Save and test the connection.

## Changed Client IP

If DHCP changes the trusted client's address, run this on the Proxmox host and enter
the new address:

```bash
/root/set-hermes-client-ip.sh
```

The helper automatically detects the tagged Hermes LXC. A DHCP reservation for
the client device avoids this step.

## Operations

```bash
# Service health and logs
pct exec CTID -- systemctl status hermes-serve.service
pct exec CTID -- journalctl -u hermes-serve.service -n 100 --no-pager

# Hermes diagnostics
pct exec CTID -- runuser -u hermes -- \
	/home/hermes/.hermes/hermes-agent/venv/bin/hermes doctor

# Proxmox backup before major changes
vzdump CTID --mode snapshot --compress zstd
```

The LXC has no passwordless sudo or SSH server. Administrative access remains
available through `pct enter CTID` on the Proxmox host.
