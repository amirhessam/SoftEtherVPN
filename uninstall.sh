#!/bin/sh
# Remove a SoftEther VPN install created by build-install.sh and
# setup-fast-gateway.sh. nginx and this source tree are left in place.

set -eu

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
TAP="${VPN_TAP:-tap_soft}"
VPN_PUBLIC_PORT="${VPN_PUBLIC_PORT:-8080}"
VPN_INTERNAL_PORT="${VPN_INTERNAL_PORT:-55550}"
UDP_ACCEL_LOW="${UDP_ACCEL_LOW:-40000}"
UDP_ACCEL_HIGH="${UDP_ACCEL_HIGH:-44999}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-softether.conf}"
DNSMASQ_FILE="${DNSMASQ_FILE:-/etc/dnsmasq.d/softether-tap.conf}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
NGINX_STREAM_DIR="${NGINX_STREAM_DIR:-/etc/nginx/stream.d}"
NGINX_LEGACY_STREAM="${NGINX_LEGACY_STREAM:-/etc/nginx/stream-softether.conf}"
STATE_DIR="${STATE_DIR:-/var/lib/softether}"
NGINX_FRONT_STAMP="${NGINX_FRONT_STAMP:-${STATE_DIR}/nginx-front}"
LIBEXEC_DIR="${LIBEXEC_DIR:-${INSTALL_PREFIX}/libexec/softether}"
UFW_SYSCTL="${UFW_SYSCTL:-/etc/ufw/sysctl.conf}"
NGINX_CHANGED=0
NGINX_BACKUP=""

stop_unit() {
	frag=""
	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable --now "$1" >/dev/null 2>&1 || true
		frag=$(systemctl show -p FragmentPath --value "$1" 2>/dev/null || true)
	fi
	if [ -n "$frag" ] && [ "$frag" != "n/a" ]; then
		rm -f "$frag"
	fi
	rm -f "/etc/systemd/system/$1" "/lib/systemd/system/$1" "/usr/lib/systemd/system/$1"
}

stop_softether() {
	for unit in \
		softether-firewall.service \
		softether-tap-setup.service \
		softether-vpnserver.service \
		softether-vpnbridge.service \
		softether-vpnclient.service
	do
		stop_unit "$unit"
	done
	for cmd in vpnserver vpnbridge vpnclient; do
		if [ -x "${INSTALL_PREFIX}/bin/${cmd}" ]; then
			"${INSTALL_PREFIX}/bin/${cmd}" stop >/dev/null 2>&1 || true
		fi
	done
	if [ -f "$DNSMASQ_FILE" ]; then
		if command -v systemctl >/dev/null 2>&1; then
			systemctl stop dnsmasq >/dev/null 2>&1 || true
		elif command -v service >/dev/null 2>&1; then
			service dnsmasq stop >/dev/null 2>&1 || true
		fi
	fi
	if command -v ip >/dev/null 2>&1; then
		ip link delete "$TAP" >/dev/null 2>&1 || true
	fi
}

# stdin is `iptables -S` output. Matching rules are deleted.
delete_softether_rules() {
	tool=$1
	table=$2
	if ! command -v "$tool" >/dev/null 2>&1; then
		return 0
	fi
	"$tool" -t "$table" -S 2>/dev/null | while read -r action chain rest; do
		case "$rest" in
			*softether-*)
				# shellcheck disable=SC2086
				set -f
				"$tool" -t "$table" -D "$chain" $rest || true
				set +f
				;;
		esac
	done
	return 0
}

ufw_delete_exact() {
	i=0
	if ! command -v ufw >/dev/null 2>&1; then
		return 0
	fi
	# Stop once ufw reports the rule is already gone. Cap the loop so a
	# command that always succeeds cannot spin.
	while [ "$i" -lt 30 ]; do
		if ! ufw --force delete "$@" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
	done
	echo "Stopped removing a ufw rule after 30 deletes: $*" >&2
	return 0
}

delete_ufw_ports() {
	ufw_delete_exact allow "${VPN_PUBLIC_PORT}/tcp"
	ufw_delete_exact allow "${VPN_PUBLIC_PORT}/udp"
	ufw_delete_exact allow "${VPN_INTERNAL_PORT}/tcp"
	ufw_delete_exact allow "${VPN_INTERNAL_PORT}/udp"
	ufw_delete_exact deny "${VPN_INTERNAL_PORT}/tcp"
	ufw_delete_exact deny "${VPN_INTERNAL_PORT}/udp"
	ufw_delete_exact allow from 127.0.0.1 to any port "$VPN_INTERNAL_PORT" proto tcp
	ufw_delete_exact allow from 127.0.0.1 to any port "$VPN_INTERNAL_PORT" proto udp
	ufw_delete_exact allow from ::1 to any port "$VPN_INTERNAL_PORT" proto tcp
	ufw_delete_exact allow from ::1 to any port "$VPN_INTERNAL_PORT" proto udp
	ufw_delete_exact allow "${UDP_ACCEL_LOW}:${UDP_ACCEL_HIGH}/udp"
}

delete_firewall() {
	# Change ufw before the iptables cleanup. ufw rewrites the filter table
	# when it deletes a rule, which would put the comment rules back.
	if [ -f "$NGINX_FRONT_STAMP" ] || [ -f "$NGINX_STREAM_DIR/softether.conf" ] || [ -f "$NGINX_LEGACY_STREAM" ]; then
		delete_ufw_ports
	fi
	ufw_delete_exact allow in on "$TAP"
	delete_ufw_matching "$TAP" route
	for tool in iptables ip6tables; do
		for table in filter nat mangle; do
			delete_softether_rules "$tool" "$table"
		done
	done
	if command -v netfilter-persistent >/dev/null 2>&1; then
		netfilter-persistent save >/dev/null 2>&1 || true
	fi
}

ufw_rule_numbers() {
	pattern=$1
	awk -v pattern="$pattern" '
		function bounded(line, pat,    start, rel, pos, prev, after) {
			start = 1
			while (start <= length(line)) {
				rel = index(substr(line, start), pat)
				if (rel == 0) {
					return 0
				}
				pos = start + rel - 1
				prev = ""
				if (pos > 1) {
					prev = substr(line, pos - 1, 1)
				}
				after = substr(line, pos + length(pat), 1)
				if ((prev == "" || prev !~ /[0-9A-Za-z_]/) && (after == "" || after !~ /[0-9A-Za-z_]/)) {
					return 1
				}
				start = pos + 1
			}
			return 0
		}
		/^[[:space:]]*\[/ && bounded($0, pattern) {
			n = $0
			sub(/^[[:space:]]*\[ */, "", n)
			sub(/\].*/, "", n)
			if (n ~ /^[0-9]+$/) {
				print n
			}
		}
	' | sort -nr
}

delete_ufw_matching() {
	pattern=$1
	route=${2:-}
	nums=""
	if ! command -v ufw >/dev/null 2>&1; then
		return 0
	fi
	if [ "$route" = "route" ]; then
		nums=$(ufw route status numbered 2>/dev/null | ufw_rule_numbers "$pattern" || true)
		for n in $nums; do
			ufw --force route delete "$n" >/dev/null 2>&1 || true
		done
		return 0
	fi
	nums=$(ufw status numbered 2>/dev/null | ufw_rule_numbers "$pattern" || true)
	for n in $nums; do
		ufw --force delete "$n" >/dev/null 2>&1 || true
	done
	return 0
}

remove_nginx_stream() {
	rm -f "$NGINX_STREAM_DIR/softether.conf" "$NGINX_LEGACY_STREAM"
	if [ ! -f "$NGINX_CONF" ]; then
		return 0
	fi
	if ! grep -q 'softether-stream' "$NGINX_CONF" && ! grep -q 'stream-softether\.conf' "$NGINX_CONF"; then
		return 0
	fi
	NGINX_BACKUP="${NGINX_CONF}.uninstall-bak"
	cp "$NGINX_CONF" "$NGINX_BACKUP"
	awk '
		/^# softether-stream-begin$/ { skip = 1; next }
		/^# softether-stream-end$/ { skip = 0; next }
		skip { next }
		/softether-stream/ { next }
		/stream-softether\.conf/ { next }
		{ print }
	' "$NGINX_CONF" > "${NGINX_CONF}.tmp"
	mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
	NGINX_CHANGED=1
	if ! command -v nginx >/dev/null 2>&1; then
		rm -f "$NGINX_BACKUP"
	fi
}

reload_nginx_if_needed() {
	if [ "$NGINX_CHANGED" != 1 ] || ! command -v nginx >/dev/null 2>&1; then
		return 0
	fi
	if ! nginx -t >/dev/null 2>&1; then
		if [ -n "$NGINX_BACKUP" ] && [ -f "$NGINX_BACKUP" ]; then
			mv "$NGINX_BACKUP" "$NGINX_CONF"
		fi
		NGINX_CHANGED=0
		echo "nginx rejected ${NGINX_CONF} after the VPN stream was removed. The previous file was restored." >&2
		return 0
	fi
	rm -f "$NGINX_BACKUP"
	if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
		systemctl reload nginx >/dev/null 2>&1 || true
	else
		nginx -s reload >/dev/null 2>&1 || true
	fi
}

remove_tree() {
	case "$1" in
		*/softether|*/softether/)
			rm -rf "$1"
			;;
		*)
			echo "Refusing to remove ${1}." >&2
			return 1
			;;
	esac
}

remove_installed_files() {
	rm -f "$SYSCTL_FILE" "$DNSMASQ_FILE"
	rm -f \
		"${INSTALL_PREFIX}/sbin/softether-tap-setup" \
		"${INSTALL_PREFIX}/sbin/softether-firewall-restore" \
		"${INSTALL_PREFIX}/bin/vpnserver" \
		"${INSTALL_PREFIX}/bin/vpnbridge" \
		"${INSTALL_PREFIX}/bin/vpnclient" \
		"${INSTALL_PREFIX}/bin/vpncmd" \
		"${INSTALL_PREFIX}/lib/libmayaqua.a" \
		"${INSTALL_PREFIX}/lib/libcedar.a" \
		"${INSTALL_PREFIX}/lib/libmayaqua.so" \
		"${INSTALL_PREFIX}/lib/libcedar.so"
	remove_tree "$LIBEXEC_DIR"
	remove_tree "$STATE_DIR"
	restore_forwarding
	if command -v systemctl >/dev/null 2>&1; then
		systemctl daemon-reload >/dev/null 2>&1 || true
	fi
	if [ "${UNINSTALL_SKIP_SYSCTL:-}" != 1 ] && [ -f /proc/sys/net/ipv4/ip_forward ]; then
		sysctl --system >/dev/null 2>&1 || true
	fi
}

# The gateway install forces forwarding on, including in ufw's sysctl file,
# which keeps it on after reboot. Put that line back and drop the live flag
# when no other sysctl file still asks for it.
restore_forwarding() {
	if [ -f "$UFW_SYSCTL" ]; then
		awk '{
			if ($0 == "net/ipv4/ip_forward=1") {
				print "#net/ipv4/ip_forward=1"
			} else {
				print
			}
		}' "$UFW_SYSCTL" > "${UFW_SYSCTL}.tmp"
		mv "${UFW_SYSCTL}.tmp" "$UFW_SYSCTL"
	fi
	if [ "${UNINSTALL_SKIP_SYSCTL:-}" = 1 ]; then
		return 0
	fi
	if grep -R -q -E '^net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1([[:space:]]|$)' \
		/etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d 2>/dev/null; then
		return 0
	fi
	sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
}

if [ "${UNINSTALL_SOURCE_ONLY:-}" = 1 ]; then
	return 0 2>/dev/null || exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "Run this script as root." >&2
	exit 1
fi

stop_softether
delete_firewall
remove_nginx_stream
reload_nginx_if_needed
remove_installed_files
echo "SoftEther VPN has been removed. nginx and this source tree were left in place."
