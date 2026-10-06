#!/bin/sh
# Turn a SoftEther VPN Server into a kernel-speed gateway.
#
# SecureNAT runs in user space and shares 192.168.30.1 with a local bridge, so
# clients either stay slow or never get an address. This script disables
# SecureNAT, bridges the hub to a tap, and lets the kernel forward, NAT, and
# clamp TCP MSS. Larger socket buffers let UDP acceleration use the sizes
# SoftEther already requests.
#
# Optional environment:
#   VPN_HUB=VPN
#   VPN_PASSWORD=          server admin password, empty if unset
#   VPN_HOST=127.0.0.1:5555
#   VPN_TAP=tap_soft       device created by BridgeCreate /DEVICE:soft /TAP:yes
#   VPN_BRIDGE_DEVICE=soft
#   VPN_GW=192.168.30.1
#   VPN_PREFIX=24
#   VPN_DHCP_START=192.168.30.10
#   VPN_DHCP_END=192.168.30.200
#   VPNCMD=/path/to/vpncmd

set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "Run this script as root." >&2
	exit 1
fi

HUB="${VPN_HUB:-VPN}"
PASSWORD="${VPN_PASSWORD:-}"
HOSTPORT="${VPN_HOST:-127.0.0.1:5555}"
TAP="${VPN_TAP:-tap_soft}"
BRIDGE_DEVICE="${VPN_BRIDGE_DEVICE:-soft}"
GW="${VPN_GW:-192.168.30.1}"
PREFIX="${VPN_PREFIX:-24}"
DHCP_START="${VPN_DHCP_START:-192.168.30.10}"
DHCP_END="${VPN_DHCP_END:-192.168.30.200}"
NET="${GW%.*}.0/${PREFIX}"

install_packages() {
	if command -v apt-get >/dev/null 2>&1; then
		export DEBIAN_FRONTEND=noninteractive
		echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
		echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
		apt-get update
		apt-get install -y dnsmasq iptables-persistent
	elif command -v dnf >/dev/null 2>&1; then
		dnf -y install dnsmasq iptables
	elif command -v yum >/dev/null 2>&1; then
		yum -y install dnsmasq iptables
	else
		echo "Install dnsmasq and iptables, then re-run." >&2
		exit 1
	fi
}

write_sysctl() {
	cat > /etc/sysctl.d/99-softether.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
EOF
	if [ -f /etc/ufw/sysctl.conf ]; then
		if grep -q '^net/ipv4/ip_forward=' /etc/ufw/sysctl.conf; then
			sed -i 's|^net/ipv4/ip_forward=.*|net/ipv4/ip_forward=1|' /etc/ufw/sysctl.conf
		else
			echo 'net/ipv4/ip_forward=1' >> /etc/ufw/sysctl.conf
		fi
	fi
	while read -r line; do
		case "$line" in
			''|\#*) continue ;;
		esac
		sysctl -w "$line" >/dev/null || true
	done < /etc/sysctl.d/99-softether.conf
}

dns_servers() {
	servers=$(awk '/^nameserver[ \t]/ { if ($2 !~ /^127\./) print $2 }' /etc/resolv.conf 2>/dev/null | awk 'NR<=2 { printf "%s%s", sep, $0; sep="," }')
	if [ -z "$servers" ]; then
		servers="1.1.1.1,8.8.8.8"
	fi
	printf '%s\n' "$servers"
}

write_dnsmasq() {
	dns=$(dns_servers)
	mkdir -p /etc/dnsmasq.d
	cat > /etc/dnsmasq.d/softether-tap.conf <<EOF
# DHCP only. DNS is handed to clients directly so this host does not proxy it.
port=0
interface=${TAP}
bind-interfaces
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h
dhcp-option=option:router,${GW}
dhcp-option=option:dns-server,${dns}
EOF
	# The tap does not exist until SoftEther starts. A boot-time start fails
	# with "unknown interface" and never recovers.
	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable dnsmasq >/dev/null 2>&1 || true
	fi
}

write_tap_helper() {
	cat > /usr/local/sbin/softether-tap-setup <<EOF
#!/bin/sh
set -eu
TAP=${TAP}
GW=${GW}
PREFIX=${PREFIX}
NET=${NET}
i=0
while [ "\$i" -lt 60 ]; do
	if ip link show "\$TAP" >/dev/null 2>&1; then
		break
	fi
	i=\$((i + 1))
	sleep 1
done
if ! ip link show "\$TAP" >/dev/null 2>&1; then
	echo "\${TAP} did not appear. Create the local bridge in vpncmd first." >&2
	exit 1
fi
ip addr replace "\${GW}/\${PREFIX}" dev "\$TAP"
ip link set "\$TAP" up
WAN=\$(ip route show default | awk '{print \$5; exit}')
if [ -z "\$WAN" ]; then
	echo "No default route. NAT was not installed, so client upload will not leave this host." >&2
else
	iptables -t nat -S POSTROUTING | sed -n 's/^-A \\(.*softether-nat.*\\)\$/\\1/p' | while read -r spec; do
		# shellcheck disable=SC2086
		iptables -t nat -D \$spec || true
	done
	iptables -t nat -A POSTROUTING -s "\$NET" -o "\$WAN" -m comment --comment softether-nat -j MASQUERADE
fi
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment softether-mss -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \\
	iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment softether-mss -j TCPMSS --clamp-mss-to-pmtu
iptables -C FORWARD -i "\$TAP" -m comment --comment softether-fwd -j ACCEPT 2>/dev/null || \\
	iptables -I FORWARD 1 -i "\$TAP" -m comment --comment softether-fwd -j ACCEPT
if ! iptables -C FORWARD -o "\$TAP" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment softether-fwd-back -j ACCEPT 2>/dev/null \
	&& ! iptables -C FORWARD -o "\$TAP" -m state --state RELATED,ESTABLISHED -m comment --comment softether-fwd-back -j ACCEPT 2>/dev/null; then
	iptables -I FORWARD 1 -o "\$TAP" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment softether-fwd-back -j ACCEPT 2>/dev/null \
		|| iptables -I FORWARD 1 -o "\$TAP" -m state --state RELATED,ESTABLISHED -m comment --comment softether-fwd-back -j ACCEPT
fi
if command -v netfilter-persistent >/dev/null 2>&1; then
	netfilter-persistent save || true
fi
if command -v systemctl >/dev/null 2>&1; then
	systemctl restart dnsmasq
else
	service dnsmasq restart || true
fi
EOF
	chmod 755 /usr/local/sbin/softether-tap-setup

	if command -v systemctl >/dev/null 2>&1; then
		cat > /etc/systemd/system/softether-tap-setup.service <<'EOF'
[Unit]
Description=SoftEther VPN tap gateway
After=network-online.target softether-vpnserver.service vpnserver.service SoftEtherVPN.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/softether-tap-setup

[Install]
WantedBy=multi-user.target
EOF
		systemctl daemon-reload
		systemctl enable softether-tap-setup.service
	fi
}

find_vpncmd() {
	if [ -n "${VPNCMD:-}" ] && [ -x "$VPNCMD" ]; then
		printf '%s\n' "$VPNCMD"
		return 0
	fi
	if command -v vpncmd >/dev/null 2>&1; then
		command -v vpncmd
		return 0
	fi
	for candidate in \
		/usr/local/bin/vpncmd \
		/usr/bin/vpncmd \
		/usr/local/libexec/softether/vpncmd/vpncmd \
		/usr/libexec/softether/vpncmd/vpncmd
	do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

wait_for_admin_port() {
	port=${HOSTPORT##*:}
	case "$port" in
		''|*[!0-9]*) port=443 ;;
	esac
	i=0
	while [ "$i" -lt 30 ]; do
		if ss -ltn 2>/dev/null | grep -E -q ":${port}([^0-9]|\$)" || netstat -ltn 2>/dev/null | grep -E -q ":${port}([^0-9]|\$)"; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

configure_hub() {
	cmd=$(find_vpncmd) || {
		echo "vpncmd was not found. Kernel forwarding is in place." >&2
		echo "Set VPNCMD to the vpncmd binary and re-run to create the bridge." >&2
		return 0
	}

	if ! wait_for_admin_port; then
		started=0
		if command -v systemctl >/dev/null 2>&1; then
			for unit in softether-vpnserver.service vpnserver.service SoftEtherVPN.service; do
				if systemctl cat "$unit" >/dev/null 2>&1; then
					systemctl enable --now "$unit" || true
					started=1
					break
				fi
			done
		fi
		if [ "$started" -eq 0 ] && command -v vpnserver >/dev/null 2>&1; then
			vpnserver start || true
		fi
	fi
	if ! wait_for_admin_port; then
		echo "vpnserver is not listening on ${HOSTPORT}. Start it, then re-run this script." >&2
		return 0
	fi

	set -- "$cmd" "$HOSTPORT" /SERVER
	if [ -n "$PASSWORD" ]; then
		set -- "$@" "/PASSWORD:${PASSWORD}"
	fi

	# Userspace SecureNAT is the slow path and uses the same 192.168.30.1
	# address as the tap gateway.
	"$@" /CMD HubCreate "$HUB" /PASSWORD: || true
	"$@" /HUB:"$HUB" /CMD Online || true
	"$@" /HUB:"$HUB" /CMD NatSet /MTU:1280 /TCPTIMEOUT:1800 /UDPTIMEOUT:60 /LOG:no || true
	"$@" /HUB:"$HUB" /CMD SecureNatDisable || true
	"$@" /HUB:"$HUB" /CMD LogDisable || true
	if ! "$@" /CMD BridgeCreate "$HUB" /DEVICE:"$BRIDGE_DEVICE" /TAP:yes; then
		echo "BridgeCreate did not succeed. If ${TAP} already exists, that is fine." >&2
		echo "If vpncmd rejected the login, re-run with VPN_PASSWORD set." >&2
	fi
}

allow_firewall() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
		if [ -f /etc/default/ufw ]; then
			sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
		fi
		wan=$(ip route show default | awk '{print $5; exit}')
		ufw allow in on "$TAP" || true
		if [ -n "$wan" ]; then
			ufw route allow in on "$TAP" out on "$wan" || true
			ufw route allow in on "$wan" out on "$TAP" || true
		fi
	fi
}

print_notes() {
	echo "Gateway ${GW}/${PREFIX} on ${TAP}, DHCP ${DHCP_START}-${DHCP_END}, hub ${HUB}."
	echo "SecureNAT is off. Clients should obtain an address automatically."
	if [ -r /sys/class/dmi/id/sys_vendor ] && grep -qi 'amazon' /sys/class/dmi/id/sys_vendor; then
		echo "This is an EC2 instance. In the AWS console, turn off Source/destination check for this instance."
		echo "Open UDP 443, 1194, 500 and 4500 in the security group so sessions are not forced onto TCP."
	fi
}

install_packages
write_sysctl
write_dnsmasq
write_tap_helper
allow_firewall
configure_hub
/usr/local/sbin/softether-tap-setup
print_notes
