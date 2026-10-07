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
#
# If nginx is already serving TCP 443, this script does not take that port.
# It turns off the extra SoftEther listeners and publishes TCP 8080, plus
# OpenVPN, SSTP, and WireGuard UDP, through the nginx stream module.
# SoftEther listens on 55550, which is reachable only from localhost.
# Native UDP acceleration stays on UDP 40000-44999. Each session binds its own
# port in that range, so nginx cannot carry it on 8080.

set -eu

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
VPN_PUBLIC_PORT=8080
VPN_INTERNAL_PORT=55550
VPN_DEFAULT_UDP_PORTS="443,992,1194,5555"
UDP_ACCEL_LOW=40000
UDP_ACCEL_HIGH=44999
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
NGINX_STREAM_DIR="${NGINX_STREAM_DIR:-/etc/nginx/stream.d}"
UDP_PORTS_BACKUP="${UDP_PORTS_BACKUP:-/var/lib/softether/udp-ports.before-nginx}"
NGINX_FRONT_STAMP="${NGINX_FRONT_STAMP:-/var/lib/softether/nginx-front}"
FIREWALL_RESTORE_BIN="${FIREWALL_RESTORE_BIN:-/usr/local/sbin/softether-firewall-restore}"
FIREWALL_SERVICE_FILE="${FIREWALL_SERVICE_FILE:-/etc/systemd/system/softether-firewall.service}"
NGINX_FRONT=0
VPN_BIN=""

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

# Install a boot service that puts the nginx-front filter rules back before
# vpnserver listens. This does not depend on the tap helper, and it covers
# hosts that have no netfilter-persistent package.
write_firewall_boot() {
	mkdir -p "$(dirname "$FIREWALL_RESTORE_BIN")" "$(dirname "$FIREWALL_SERVICE_FILE")"
	cat > "$FIREWALL_RESTORE_BIN" <<EOF
#!/bin/sh
set -eu
STAMP=${NGINX_FRONT_STAMP}
PUBLIC=${VPN_PUBLIC_PORT}
INTERNAL=${VPN_INTERNAL_PORT}
LOW=${UDP_ACCEL_LOW}
HIGH=${UDP_ACCEL_HIGH}

ipv6_enabled() {
	[ -d /proc/sys/net/ipv6 ] || return 1
	[ "\$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" != 1 ]
}

delete_filter_rule() {
	tool=\$1
	shift
	if ! command -v "\$tool" >/dev/null 2>&1; then
		return 0
	fi
	while "\$tool" -D INPUT "\$@" 2>/dev/null; do
		:
	done
	return 0
}

release_rules() {
	for proto in tcp udp; do
		delete_filter_rule iptables -p "\$proto" --dport "\$INTERNAL" -s 127.0.0.1 -m comment --comment softether-internal -j ACCEPT
		delete_filter_rule iptables -p "\$proto" --dport "\$INTERNAL" -m comment --comment softether-internal -j DROP
		delete_filter_rule ip6tables -p "\$proto" --dport "\$INTERNAL" -s ::1 -m comment --comment softether-internal -j ACCEPT
		delete_filter_rule ip6tables -p "\$proto" --dport "\$INTERNAL" -m comment --comment softether-internal -j DROP
		delete_filter_rule iptables -p "\$proto" --dport "\$PUBLIC" -m comment --comment softether-public -j ACCEPT
		delete_filter_rule ip6tables -p "\$proto" --dport "\$PUBLIC" -m comment --comment softether-public -j ACCEPT
	done
	delete_filter_rule iptables -p udp --dport "\${LOW}:\${HIGH}" -m comment --comment softether-accel -j ACCEPT
	delete_filter_rule ip6tables -p udp --dport "\${LOW}:\${HIGH}" -m comment --comment softether-accel -j ACCEPT
}

save_rules() {
	if command -v netfilter-persistent >/dev/null 2>&1; then
		netfilter-persistent save || true
	fi
}

if [ ! -f "\$STAMP" ]; then
	release_rules
	save_rules
	exit 0
fi

if ! command -v iptables >/dev/null 2>&1; then
	echo "iptables is not installed, so the VPN firewall rules were not restored." >&2
	exit 1
fi

for proto in tcp udp; do
	iptables -C INPUT -p "\$proto" --dport "\$INTERNAL" -s 127.0.0.1 -m comment --comment softether-internal -j ACCEPT 2>/dev/null || \\
		iptables -I INPUT 1 -p "\$proto" --dport "\$INTERNAL" -s 127.0.0.1 -m comment --comment softether-internal -j ACCEPT || exit 1
	iptables -C INPUT -p "\$proto" --dport "\$INTERNAL" -m comment --comment softether-internal -j DROP 2>/dev/null || \\
		iptables -A INPUT -p "\$proto" --dport "\$INTERNAL" -m comment --comment softether-internal -j DROP || exit 1
	iptables -C INPUT -p "\$proto" --dport "\$PUBLIC" -m comment --comment softether-public -j ACCEPT 2>/dev/null || \\
		iptables -I INPUT 1 -p "\$proto" --dport "\$PUBLIC" -m comment --comment softether-public -j ACCEPT || exit 1
	if ipv6_enabled; then
		ip6tables -C INPUT -p "\$proto" --dport "\$INTERNAL" -s ::1 -m comment --comment softether-internal -j ACCEPT 2>/dev/null || \\
			ip6tables -I INPUT 1 -p "\$proto" --dport "\$INTERNAL" -s ::1 -m comment --comment softether-internal -j ACCEPT || exit 1
		ip6tables -C INPUT -p "\$proto" --dport "\$INTERNAL" -m comment --comment softether-internal -j DROP 2>/dev/null || \\
			ip6tables -A INPUT -p "\$proto" --dport "\$INTERNAL" -m comment --comment softether-internal -j DROP || exit 1
		ip6tables -C INPUT -p "\$proto" --dport "\$PUBLIC" -m comment --comment softether-public -j ACCEPT 2>/dev/null || \\
			ip6tables -I INPUT 1 -p "\$proto" --dport "\$PUBLIC" -m comment --comment softether-public -j ACCEPT || exit 1
	fi
done
iptables -C INPUT -p udp --dport "\${LOW}:\${HIGH}" -m comment --comment softether-accel -j ACCEPT 2>/dev/null || \\
	iptables -I INPUT 1 -p udp --dport "\${LOW}:\${HIGH}" -m comment --comment softether-accel -j ACCEPT || exit 1
if ipv6_enabled; then
	ip6tables -C INPUT -p udp --dport "\${LOW}:\${HIGH}" -m comment --comment softether-accel -j ACCEPT 2>/dev/null || \\
		ip6tables -I INPUT 1 -p udp --dport "\${LOW}:\${HIGH}" -m comment --comment softether-accel -j ACCEPT || exit 1
fi
save_rules
EOF
	chmod 755 "$FIREWALL_RESTORE_BIN"
	cat > "$FIREWALL_SERVICE_FILE" <<EOF
[Unit]
Description=SoftEther VPN firewall rules
After=netfilter-persistent.service network-pre.target
Before=softether-vpnserver.service vpnserver.service nginx.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${FIREWALL_RESTORE_BIN}

[Install]
WantedBy=multi-user.target
EOF
	if [ "${FIREWALL_BOOT_INSTALL:-1}" = 1 ] && command -v systemctl >/dev/null 2>&1; then
		systemctl daemon-reload
		systemctl enable softether-firewall.service
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
	VPN_BIN=$(find_vpncmd) || {
		echo "vpncmd was not found. Kernel forwarding is in place." >&2
		echo "Set VPNCMD to the vpncmd binary and re-run to create the bridge." >&2
		return 0
	}

	if ! wait_for_admin_port && ! wait_for_tcp_port "$VPN_INTERNAL_PORT"; then
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
	if ! wait_for_admin_port && ! wait_for_tcp_port "$VPN_INTERNAL_PORT"; then
		echo "vpnserver is not listening on ${HOSTPORT}. Start it, then re-run this script." >&2
		return 0
	fi

	set -- "$VPN_BIN" "$(admin_hostport)" /SERVER
	if [ -n "$PASSWORD" ]; then
		set -- "$@" "/PASSWORD:${PASSWORD}"
	fi

	# Userspace SecureNAT is the slow path and uses the same 192.168.30.1
	# address as the tap gateway.
	"$@" /CMD HubCreate "$HUB" /PASSWORD: || true
	"$@" /HUB:"$HUB" /CMD Online || true
	"$@" /HUB:"$HUB" /CMD NatSet /MTU:1280 /TCPTIMEOUT:1800 /UDPTIMEOUT:60 /LOG:no || true
	"$@" /HUB:"$HUB" /CMD SecureNatDisable || true
	"$@" /HUB:"$HUB" /CMD LogDisable security || true
	"$@" /HUB:"$HUB" /CMD LogDisable packet || true
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
	if [ "$NGINX_FRONT" -eq 1 ]; then
		echo "Clients connect with TCP ${VPN_PUBLIC_PORT}. OpenVPN, SSTP, and WireGuard use UDP ${VPN_PUBLIC_PORT}."
		echo "SoftEther UDP acceleration uses UDP ${UDP_ACCEL_LOW}-${UDP_ACCEL_HIGH}."
		echo "Port 443 stays with nginx."
	fi
	if [ -r /sys/class/dmi/id/sys_vendor ] && grep -qi 'amazon' /sys/class/dmi/id/sys_vendor; then
		echo "This is an EC2 instance. In the AWS console, turn off Source/destination check for this instance."
		if [ "$NGINX_FRONT" -eq 1 ]; then
			echo "Open TCP ${VPN_PUBLIC_PORT}, UDP ${VPN_PUBLIC_PORT}, and UDP ${UDP_ACCEL_LOW}-${UDP_ACCEL_HIGH} in the security group."
		else
			echo "Open UDP 443, 1194, 500, 4500, and UDP ${UDP_ACCEL_LOW}-${UDP_ACCEL_HIGH} in the security group so sessions are not forced onto TCP."
		fi
	fi
}

tcp_port_is_listening() {
	ss -ltn 2>/dev/null | grep -E -q ":$1([^0-9]|\$)" && return 0
	netstat -ltn 2>/dev/null | grep -E -q ":$1([^0-9]|\$)" && return 0
	return 1
}

port_is_listening() {
	tcp_port_is_listening "$1" && return 0
	ss -uln 2>/dev/null | grep -E -q ":$1([^0-9]|\$)" && return 0
	return 1
}

admin_hostport() {
	if tcp_port_is_listening "$VPN_INTERNAL_PORT"; then
		printf '127.0.0.1:%s\n' "$VPN_INTERNAL_PORT"
	else
		printf '%s\n' "$HOSTPORT"
	fi
}

wait_for_tcp_port() {
	i=0
	while [ "$i" -lt 30 ]; do
		if tcp_port_is_listening "$1"; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

wait_for_port() {
	i=0
	while [ "$i" -lt 30 ]; do
		if port_is_listening "$1"; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

udp_port_is_listening() {
	ss -uln 2>/dev/null | grep -E -q ":$1([^0-9]|\$)" && return 0
	netstat -uln 2>/dev/null | grep -E -q ":$1([^0-9]|\$)" && return 0
	return 1
}

wait_for_udp_port() {
	i=0
	while [ "$i" -lt 30 ]; do
		if udp_port_is_listening "$1"; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

nginx_serves_tcp_443() {
	command -v nginx >/dev/null 2>&1 || return 1
	[ -d /etc/nginx ] || return 1
	for f in /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
		[ -f "$f" ] || continue
		if grep -E '^[[:space:]]*listen[[:space:]][^#]*\b443\b' "$f" | grep -vi quic | grep -q .; then
			return 0
		fi
	done
	return 1
}

public_port_is_ours() {
	if [ ! -f "$NGINX_STREAM_DIR/softether.conf" ] && [ ! -f /etc/nginx/stream-softether.conf ]; then
		return 1
	fi
	ss -ltnp 2>/dev/null | grep -E ":${VPN_PUBLIC_PORT}([^0-9]|\$)" | grep -q nginx
}

ports_from_vpncmd_output() {
	awk -F'|' '
		{
			val = $NF
			gsub(/^[ \t]+|[ \t]+$/, "", val)
			gsub(/ /, "", val)
			if (val ~ /^[0-9]+(,[0-9]+)*$/) {
				print val
				exit
			}
		}
	'
}

original_udp_ports() {
	if [ -s "$UDP_PORTS_BACKUP" ]; then
		saved=$(head -n 1 "$UDP_PORTS_BACKUP")
		case "$saved" in
			*[!0-9,]*) printf '%s\n' "$VPN_DEFAULT_UDP_PORTS" ;;
			*) printf '%s\n' "$saved" ;;
		esac
		return 0
	fi
	printf '%s\n' "$VPN_DEFAULT_UDP_PORTS"
}

remember_udp_ports() {
	current=$(run_vpncmd "$1" /CMD PortsUDPGet | ports_from_vpncmd_output)
	if [ -z "$current" ]; then
		echo "Could not read the current SoftEther UDP listeners." >&2
		return 1
	fi
	if [ "$current" = "$VPN_INTERNAL_PORT" ]; then
		return 0
	fi
	mkdir -p "$(dirname "$UDP_PORTS_BACKUP")"
	printf '%s\n' "$current" > "$UDP_PORTS_BACKUP"
}

listener_held_by_vpnserver() {
	if ! command -v ss >/dev/null 2>&1; then
		return 0
	fi
	ss -ltnp 2>/dev/null | grep -E ":$1([^0-9]|\$)" | grep -E -q 'vpnserver|vpnbridge'
}

# stdin is ss output. Success means some listener on this port is not vpnserver.
foreign_listener_in_ss() {
	grep -E ":$1([^0-9]|\$)" | grep -E -v -q 'vpnserver|vpnbridge'
}

foreign_tcp_listener() {
	command -v ss >/dev/null 2>&1 || return 1
	ss -ltnp 2>/dev/null | foreign_listener_in_ss "$1"
}

foreign_udp_listener() {
	command -v ss >/dev/null 2>&1 || return 1
	ss -ulnp 2>/dev/null | foreign_listener_in_ss "$1"
}

vpnserver_listens_on() {
	command -v ss >/dev/null 2>&1 || return 1
	ss -ltnp 2>/dev/null | grep -E ":$1([^0-9]|\$)" | grep -E -q 'vpnserver|vpnbridge'
}

wait_for_vpnserver_port() {
	i=0
	while [ "$i" -lt 30 ]; do
		if vpnserver_listens_on "$1"; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

disable_public_listeners() {
	for port in 443 992 1194 5555; do
		if run_vpncmd "127.0.0.1:${VPN_INTERNAL_PORT}" /CMD ListenerDisable "$port"; then
			continue
		fi
		if listener_held_by_vpnserver "$port"; then
			echo "Could not disable SoftEther listener ${port}." >&2
			return 1
		fi
	done
	return 0
}

run_vpncmd() {
	hostport=$1
	shift
	if [ -z "$VPN_BIN" ]; then
		return 1
	fi
	if [ -n "$PASSWORD" ]; then
		"$VPN_BIN" "$hostport" /SERVER "/PASSWORD:${PASSWORD}" "$@"
	else
		"$VPN_BIN" "$hostport" /SERVER "$@"
	fi
}

reload_nginx() {
	if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
		systemctl reload nginx || return $?
		return 0
	fi
	nginx -s reload || return $?
}

install_stream_module() {
	if command -v apt-get >/dev/null 2>&1; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update || return 1
		apt-get install -y libnginx-mod-stream || return 1
		return 0
	fi
	if command -v dnf >/dev/null 2>&1; then
		dnf -y install nginx-mod-stream || return 1
		return 0
	fi
	if command -v yum >/dev/null 2>&1; then
		yum -y install nginx-mod-stream || return 1
		return 0
	fi
	echo "Install the nginx stream module, then re-run." >&2
	return 1
}

ipv6_enabled() {
	if [ "${VPN_IPV6:-}" = 1 ]; then
		return 0
	fi
	if [ "${VPN_IPV6:-}" = 0 ]; then
		return 1
	fi
	[ -d /proc/sys/net/ipv6 ] || return 1
	[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" != 1 ]
}

remove_nginx_stream() {
	rm -f "$NGINX_STREAM_DIR/softether.conf" /etc/nginx/stream-softether.conf
	if [ ! -f "$NGINX_CONF" ]; then
		return 0
	fi
	awk '
		/^# softether-stream-begin$/ { skip = 1; next }
		/^# softether-stream-end$/ { skip = 0; next }
		skip { next }
		/softether-stream/ { next }
		/stream-softether\.conf/ { next }
		{ print }
	' "$NGINX_CONF" > "${NGINX_CONF}.tmp"
	mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
}

write_stream_servers() {
	mkdir -p "$NGINX_STREAM_DIR"
	# TCP carries the client address in a PROXY header. This vpnserver build
	# reads that header. UDP replies must go back through nginx, so the UDP
	# proxy keeps nginx as the packet source.
	cat > "$NGINX_STREAM_DIR/softether.conf" <<EOF
server {
	listen ${VPN_PUBLIC_PORT};
	proxy_pass 127.0.0.1:${VPN_INTERNAL_PORT};
	proxy_protocol on;
	proxy_timeout 1h;
}

server {
	listen ${VPN_PUBLIC_PORT} udp;
	proxy_pass 127.0.0.1:${VPN_INTERNAL_PORT};
	proxy_timeout 1h;
}
EOF
}

ensure_nginx_stream_include() {
	if [ ! -f "$NGINX_CONF" ]; then
		echo "nginx.conf was not found at ${NGINX_CONF}." >&2
		return 1
	fi
	if grep -q 'softether-stream' "$NGINX_CONF"; then
		return 0
	fi
	include_line="    include ${NGINX_STREAM_DIR}/*.conf; # softether-stream"
	if nginx_has_stream_block "$NGINX_CONF"; then
		awk -v include_line="$include_line" '
			{
				prev_was_stream = (prev ~ /^[[:space:]]*stream[[:space:]]*$/)
				if (inserted == 0 && $0 ~ /^[[:space:]]*stream[[:space:]]*\{/) {
					print
					print include_line
					inserted = 1
					prev = $0
					next
				}
				if (inserted == 0 && prev_was_stream && $0 ~ /^[[:space:]]*\{/) {
					print
					print include_line
					inserted = 1
					prev = $0
					next
				}
				print
				prev = $0
			}
		' "$NGINX_CONF" > "${NGINX_CONF}.tmp"
		mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
		if grep -q 'softether-stream' "$NGINX_CONF"; then
			return 0
		fi
		echo "nginx already has a stream block, and the VPN include could not be added inside it." >&2
		return 1
	fi
	printf '\n# softether-stream-begin\nstream {\n%s\n}\n# softether-stream-end\n' "$include_line" >> "$NGINX_CONF"
}

nginx_has_stream_block() {
	if grep -E -q '^[[:space:]]*stream[[:space:]]*{' "$1"; then
		return 0
	fi
	awk '
		prev ~ /^[[:space:]]*stream[[:space:]]*$/ && $0 ~ /^[[:space:]]*\{/ { found = 1 }
		{ prev = $0 }
		END { exit found ? 0 : 1 }
	' "$1"
}

restore_public_listeners() {
	run_vpncmd "127.0.0.1:${VPN_INTERNAL_PORT}" /CMD PortsUDPSet "$(original_udp_ports)" || true
	run_vpncmd "127.0.0.1:${VPN_INTERNAL_PORT}" /CMD ListenerEnable 443 || true
	run_vpncmd "127.0.0.1:${VPN_INTERNAL_PORT}" /CMD ListenerEnable 992 || true
	run_vpncmd "127.0.0.1:${VPN_INTERNAL_PORT}" /CMD ListenerEnable 1194 || true
	run_vpncmd "127.0.0.1:${VPN_INTERNAL_PORT}" /CMD ListenerEnable 5555 || true
	run_vpncmd "127.0.0.1:${VPN_INTERNAL_PORT}" /CMD ListenerDelete "$VPN_INTERNAL_PORT" || true
	remove_nginx_stream
	release_internal_port
	release_public_port
	release_udp_accel
	clear_nginx_front
	save_firewall || true
}

lock_port_family() {
	tool=$1
	source_addr=$2
	if ! command -v "$tool" >/dev/null 2>&1; then
		return 1
	fi
	for proto in tcp udp; do
		"$tool" -C INPUT -p "$proto" --dport "$VPN_INTERNAL_PORT" -s "$source_addr" -m comment --comment softether-internal -j ACCEPT 2>/dev/null || \
			"$tool" -I INPUT 1 -p "$proto" --dport "$VPN_INTERNAL_PORT" -s "$source_addr" -m comment --comment softether-internal -j ACCEPT || return 1
		"$tool" -C INPUT -p "$proto" --dport "$VPN_INTERNAL_PORT" -m comment --comment softether-internal -j DROP 2>/dev/null || \
			"$tool" -A INPUT -p "$proto" --dport "$VPN_INTERNAL_PORT" -m comment --comment softether-internal -j DROP || return 1
	done
	return 0
}

restrict_internal_port() {
	lock_port_family iptables 127.0.0.1 || return 1
	if ipv6_enabled; then
		lock_port_family ip6tables ::1 || return 1
	fi
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
		ufw insert 1 allow from 127.0.0.1 to any port "$VPN_INTERNAL_PORT" proto tcp || return 1
		ufw insert 1 allow from 127.0.0.1 to any port "$VPN_INTERNAL_PORT" proto udp || return 1
		if ipv6_enabled; then
			ufw insert 1 allow from ::1 to any port "$VPN_INTERNAL_PORT" proto tcp || return 1
			ufw insert 1 allow from ::1 to any port "$VPN_INTERNAL_PORT" proto udp || return 1
		fi
		ufw deny "${VPN_INTERNAL_PORT}/tcp" || return 1
		ufw deny "${VPN_INTERNAL_PORT}/udp" || return 1
	fi
	return 0
}

allow_public_port() {
	for proto in tcp udp; do
		iptables -C INPUT -p "$proto" --dport "$VPN_PUBLIC_PORT" -m comment --comment softether-public -j ACCEPT 2>/dev/null || \
			iptables -I INPUT 1 -p "$proto" --dport "$VPN_PUBLIC_PORT" -m comment --comment softether-public -j ACCEPT || return 1
		if ipv6_enabled; then
			ip6tables -C INPUT -p "$proto" --dport "$VPN_PUBLIC_PORT" -m comment --comment softether-public -j ACCEPT 2>/dev/null || \
				ip6tables -I INPUT 1 -p "$proto" --dport "$VPN_PUBLIC_PORT" -m comment --comment softether-public -j ACCEPT || return 1
		fi
	done
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
		ufw allow "${VPN_PUBLIC_PORT}/tcp" || return 1
		ufw allow "${VPN_PUBLIC_PORT}/udp" || return 1
	fi
	return 0
}

delete_filter_rule() {
	tool=$1
	shift
	if ! command -v "$tool" >/dev/null 2>&1; then
		return 0
	fi
	while "$tool" -D INPUT "$@" 2>/dev/null; do
		:
	done
	return 0
}

ufw_delete_rule() {
	if ! command -v ufw >/dev/null 2>&1; then
		return 0
	fi
	while ufw --force delete "$@" >/dev/null 2>&1; do
		:
	done
	return 0
}

release_internal_port() {
	for proto in tcp udp; do
		delete_filter_rule iptables -p "$proto" --dport "$VPN_INTERNAL_PORT" -s 127.0.0.1 -m comment --comment softether-internal -j ACCEPT
		delete_filter_rule iptables -p "$proto" --dport "$VPN_INTERNAL_PORT" -m comment --comment softether-internal -j DROP
		delete_filter_rule ip6tables -p "$proto" --dport "$VPN_INTERNAL_PORT" -s ::1 -m comment --comment softether-internal -j ACCEPT
		delete_filter_rule ip6tables -p "$proto" --dport "$VPN_INTERNAL_PORT" -m comment --comment softether-internal -j DROP
		ufw_delete_rule allow from 127.0.0.1 to any port "$VPN_INTERNAL_PORT" proto "$proto"
		ufw_delete_rule allow from ::1 to any port "$VPN_INTERNAL_PORT" proto "$proto"
		ufw_delete_rule deny "${VPN_INTERNAL_PORT}/${proto}"
	done
	return 0
}

release_public_port() {
	for proto in tcp udp; do
		delete_filter_rule iptables -p "$proto" --dport "$VPN_PUBLIC_PORT" -m comment --comment softether-public -j ACCEPT
		delete_filter_rule ip6tables -p "$proto" --dport "$VPN_PUBLIC_PORT" -m comment --comment softether-public -j ACCEPT
	done
	ufw_delete_rule allow "${VPN_PUBLIC_PORT}/tcp"
	ufw_delete_rule allow "${VPN_PUBLIC_PORT}/udp"
	return 0
}

release_udp_accel() {
	delete_filter_rule iptables -p udp --dport "${UDP_ACCEL_LOW}:${UDP_ACCEL_HIGH}" -m comment --comment softether-accel -j ACCEPT
	delete_filter_rule ip6tables -p udp --dport "${UDP_ACCEL_LOW}:${UDP_ACCEL_HIGH}" -m comment --comment softether-accel -j ACCEPT
	ufw_delete_rule allow "${UDP_ACCEL_LOW}:${UDP_ACCEL_HIGH}/udp"
	return 0
}

abort_internal_listener() {
	run_vpncmd "127.0.0.1:${VPN_INTERNAL_PORT}" /CMD ListenerDelete "$VPN_INTERNAL_PORT" || true
	release_internal_port
}

mark_nginx_front() {
	mkdir -p "$(dirname "$NGINX_FRONT_STAMP")"
	printf '1\n' > "$NGINX_FRONT_STAMP"
}

clear_nginx_front() {
	rm -f "$NGINX_FRONT_STAMP"
}

save_firewall() {
	if command -v netfilter-persistent >/dev/null 2>&1; then
		netfilter-persistent save || return 1
	fi
	return 0
}

firewall_unit_enabled() {
	if [ "${FIREWALL_UNIT_ENABLED:-}" = 1 ]; then
		return 0
	fi
	if [ "${FIREWALL_UNIT_ENABLED:-}" = 0 ]; then
		return 1
	fi
	command -v systemctl >/dev/null 2>&1 || return 1
	systemctl is-enabled softether-firewall.service >/dev/null 2>&1
}

commit_nginx_front() {
	if ! command -v netfilter-persistent >/dev/null 2>&1 && ! firewall_unit_enabled; then
		echo "No firewall service can restore these rules after a reboot." >&2
		return 1
	fi
	mark_nginx_front
	if ! command -v netfilter-persistent >/dev/null 2>&1; then
		return 0
	fi
	if save_firewall; then
		return 0
	fi
	if firewall_unit_enabled; then
		echo "Saving the firewall table failed. softether-firewall.service will restore the VPN rules on boot." >&2
		return 0
	fi
	clear_nginx_front
	return 1
}

allow_udp_accel() {
	iptables -C INPUT -p udp --dport "${UDP_ACCEL_LOW}:${UDP_ACCEL_HIGH}" -m comment --comment softether-accel -j ACCEPT 2>/dev/null || \
		iptables -I INPUT 1 -p udp --dport "${UDP_ACCEL_LOW}:${UDP_ACCEL_HIGH}" -m comment --comment softether-accel -j ACCEPT || return 1
	if ipv6_enabled; then
		ip6tables -C INPUT -p udp --dport "${UDP_ACCEL_LOW}:${UDP_ACCEL_HIGH}" -m comment --comment softether-accel -j ACCEPT 2>/dev/null || \
			ip6tables -I INPUT 1 -p udp --dport "${UDP_ACCEL_LOW}:${UDP_ACCEL_HIGH}" -m comment --comment softether-accel -j ACCEPT || return 1
	fi
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
		ufw allow "${UDP_ACCEL_LOW}:${UDP_ACCEL_HIGH}/udp" || return 1
	fi
	return 0
}

configure_nginx_front() {
	if [ -z "$VPN_BIN" ]; then
		return 0
	fi
	if ! nginx_serves_tcp_443; then
		return 0
	fi
	if port_is_listening "$VPN_PUBLIC_PORT" && ! public_port_is_ours; then
		echo "Port ${VPN_PUBLIC_PORT} is already in use. SoftEther listeners were left unchanged." >&2
		return 0
	fi
	if ! install_stream_module; then
		echo "The nginx stream module is not available. SoftEther listeners were left unchanged." >&2
		return 0
	fi
	if foreign_tcp_listener "$VPN_INTERNAL_PORT" || foreign_udp_listener "$VPN_INTERNAL_PORT"; then
		echo "Port ${VPN_INTERNAL_PORT} is already in use by another program. SoftEther listeners were left unchanged." >&2
		return 0
	fi
	# Drop outside traffic before SoftEther binds, so 55550 is never public.
	if ! restrict_internal_port; then
		release_internal_port
		echo "Could not restrict ${VPN_INTERNAL_PORT} to localhost. SoftEther listeners were left unchanged." >&2
		return 0
	fi

	run_vpncmd "$(admin_hostport)" /CMD ListenerCreate "$VPN_INTERNAL_PORT" || true
	if ! wait_for_vpnserver_port "$VPN_INTERNAL_PORT"; then
		abort_internal_listener
		echo "SoftEther did not listen on ${VPN_INTERNAL_PORT}. Listeners were left unchanged." >&2
		return 0
	fi
	if ! remember_udp_ports "127.0.0.1:${VPN_INTERNAL_PORT}"; then
		abort_internal_listener
		echo "SoftEther listeners were left unchanged." >&2
		return 0
	fi
	udp_ok=0
	if run_vpncmd "127.0.0.1:${VPN_INTERNAL_PORT}" /CMD PortsUDPSet "$VPN_INTERNAL_PORT"; then
		if wait_for_udp_port "$VPN_INTERNAL_PORT"; then
			udp_ok=1
		fi
	fi
	if [ "$udp_ok" -eq 0 ]; then
		echo "Could not move SoftEther UDP listeners to ${VPN_INTERNAL_PORT}. Listeners were left unchanged." >&2
		run_vpncmd "127.0.0.1:${VPN_INTERNAL_PORT}" /CMD PortsUDPSet "$(original_udp_ports)" || true
		abort_internal_listener
		return 0
	fi
	if ! disable_public_listeners; then
		echo "Restoring the original SoftEther listeners." >&2
		restore_public_listeners
		return 0
	fi

	write_stream_servers
	if ! ensure_nginx_stream_include; then
		echo "Could not add the nginx stream include. Restoring the original SoftEther listeners." >&2
		restore_public_listeners
		return 0
	fi

	if ! nginx -t; then
		echo "nginx rejected the stream config. Restoring the original SoftEther listeners." >&2
		restore_public_listeners
		return 0
	fi

	if ! reload_nginx; then
		echo "nginx reload failed. Restoring the original SoftEther listeners." >&2
		restore_public_listeners
		return 0
	fi
	if ! allow_public_port; then
		echo "Could not open ${VPN_PUBLIC_PORT} in the firewall. Restoring the original SoftEther listeners." >&2
		restore_public_listeners
		reload_nginx || true
		return 0
	fi
	if ! allow_udp_accel; then
		echo "Could not open UDP ${UDP_ACCEL_LOW}-${UDP_ACCEL_HIGH} for SoftEther UDP acceleration." >&2
		restore_public_listeners
		reload_nginx || true
		return 0
	fi
	if ! commit_nginx_front; then
		echo "Could not keep the firewall rules across a reboot. Restoring the original SoftEther listeners." >&2
		restore_public_listeners
		reload_nginx || true
		return 0
	fi
	NGINX_FRONT=1
}

if [ "${SETUP_FAST_GATEWAY_SOURCE_ONLY:-}" = 1 ]; then
	return 0 2>/dev/null || exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "Run this script as root." >&2
	exit 1
fi

install_packages
write_sysctl
write_dnsmasq
write_tap_helper
write_firewall_boot
allow_firewall
configure_hub
configure_nginx_front
/usr/local/sbin/softether-tap-setup
print_notes
