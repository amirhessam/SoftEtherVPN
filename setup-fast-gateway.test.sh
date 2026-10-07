#!/bin/sh
# Checks the nginx stream and submodule helpers without touching a live server.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

NGINX_CONF="$tmp/nginx.conf"
NGINX_STREAM_DIR="$tmp/stream.d"
UDP_PORTS_BACKUP="$tmp/udp-ports"
NGINX_FRONT_STAMP="$tmp/nginx-front"
FIREWALL_RESTORE_BIN="$tmp/softether-firewall-restore"
FIREWALL_SERVICE_FILE="$tmp/softether-firewall.service"
FIREWALL_BOOT_INSTALL=0
SETUP_FAST_GATEWAY_SOURCE_ONLY=1
# shellcheck disable=SC1091
. "$ROOT/setup-fast-gateway.sh"

sample='Item | Value
UDP Ports |443, 992, 1194, 5555
The command completed successfully.'
got=$(printf '%s\n' "$sample" | ports_from_vpncmd_output)
[ "$got" = "443,992,1194,5555" ] || fail "port parse returned [$got]"

printf 'events {}\nhttp {}\n' > "$NGINX_CONF"
ensure_nginx_stream_include || fail "could not add a stream block"
ensure_nginx_stream_include || fail "second include pass failed"
count=$(grep -c '^stream {' "$NGINX_CONF")
[ "$count" = 1 ] || fail "expected one stream block, found $count"
count=$(grep -c 'softether-stream' "$NGINX_CONF")
[ "$count" = 3 ] || fail "stream markers changed on the second pass ($count)"

printf 'events {}\nstream {\n    include /etc/nginx/other.conf;\n}\nhttp {}\n' > "$NGINX_CONF"
ensure_nginx_stream_include || fail "could not insert into an existing stream block"
count=$(grep -c '^stream {' "$NGINX_CONF")
[ "$count" = 1 ] || fail "inserted a second stream block"
grep -q 'other.conf' "$NGINX_CONF" || fail "existing stream contents were dropped"
remove_nginx_stream
grep -q 'softether-stream' "$NGINX_CONF" && fail "include was left behind"
grep -q 'other.conf' "$NGINX_CONF" || fail "existing stream include was removed"

printf 'stream\n{\n}\n' > "$NGINX_CONF"
ensure_nginx_stream_include || fail "could not insert into a split stream block"
count=$(grep -c '^stream$' "$NGINX_CONF")
[ "$count" = 1 ] || fail "split stream block was duplicated"
grep -q 'softether-stream' "$NGINX_CONF" || fail "split stream block has no include"

write_stream_servers
if grep -q '^stream' "$NGINX_STREAM_DIR/softether.conf"; then
	fail "server file must not wrap itself in stream"
fi
grep -q 'listen 8080 udp;' "$NGINX_STREAM_DIR/softether.conf" || fail "UDP server is missing"
count=$(grep -c 'proxy_protocol on;' "$NGINX_STREAM_DIR/softether.conf")
[ "$count" = 1 ] || fail "TCP client address header should be enabled once, found $count"

printf '%s\n' 'LISTEN 0 128 0.0.0.0:55550 0.0.0.0:* users:(("nginx",pid=1,fd=3))' | foreign_listener_in_ss 55550 || fail "another program on 55550 was ignored"
if printf '%s\n' 'LISTEN 0 128 0.0.0.0:55550 0.0.0.0:* users:(("vpnserver",pid=1,fd=3))' | foreign_listener_in_ss 55550; then
	fail "vpnserver was treated as another program"
fi

bin="$tmp/bin"
log="$tmp/iptables.log"
mkdir -p "$bin"
cat > "$bin/iptables" <<'EOF'
#!/bin/sh
echo "iptables $*" >> "$IPTABLES_LOG"
case "$1" in
	-I|-A) exit 0 ;;
esac
exit 1
EOF
cat > "$bin/ip6tables" <<'EOF'
#!/bin/sh
echo "ip6tables $*" >> "$IPTABLES_LOG"
case "$1" in
	-I|-A) exit 0 ;;
esac
exit 1
EOF
chmod 755 "$bin/iptables" "$bin/ip6tables"
IPTABLES_LOG="$log" PATH="$bin:$PATH" release_internal_port
grep -q -- '-D' "$log" || fail "rollback did not delete firewall rules"
grep -q 'softether-internal' "$log" || fail "rollback did not target the internal port rules"
grep -q '127.0.0.1' "$log" || fail "rollback did not remove the localhost allow"

: > "$log"
if ! VPN_IPV6=1 IPTABLES_LOG="$log" PATH="$bin:$PATH" allow_public_port; then
	fail "allow_public_port failed"
fi
grep -q 'iptables -I INPUT 1 -p tcp --dport 8080 .* softether-public' "$log" || fail "TCP 8080 was not allowed in iptables"
grep -q 'iptables -I INPUT 1 -p udp --dport 8080 .* softether-public' "$log" || fail "UDP 8080 was not allowed in iptables"
grep -q 'ip6tables -I INPUT 1 -p tcp --dport 8080 .* softether-public' "$log" || fail "TCP 8080 was not allowed in ip6tables"
grep -q 'ip6tables -I INPUT 1 -p udp --dport 8080 .* softether-public' "$log" || fail "UDP 8080 was not allowed in ip6tables"

printf '%s\n' 'events {}' > "$NGINX_CONF"
printf '\n# softether-stream-begin\nstream {\n    include %s/*.conf; # softether-stream\n}\n# softether-stream-end\n' "$NGINX_STREAM_DIR" >> "$NGINX_CONF"
mark_nginx_front
[ -f "$NGINX_FRONT_STAMP" ] || fail "nginx front was not recorded"
: > "$log"
IPTABLES_LOG="$log" PATH="$bin:$PATH" restore_public_listeners
if grep -q 'softether-stream' "$NGINX_CONF"; then
	fail "failed nginx setup left the stream include in place"
fi
grep -q 'softether-accel' "$log" || fail "rollback did not remove acceleration rules"
grep -q 'softether-public' "$log" || fail "rollback did not remove the public port rules"
[ ! -f "$NGINX_FRONT_STAMP" ] || fail "rollback left the nginx front flag in place"

cat > "$bin/netfilter-persistent" <<'EOF'
#!/bin/sh
echo "$*" >> "$IPTABLES_LOG"
exit 0
EOF
chmod 755 "$bin/netfilter-persistent"
: > "$log"
FIREWALL_UNIT_ENABLED=0 IPTABLES_LOG="$log" PATH="$bin:$PATH" commit_nginx_front || fail "firewall rules were not saved"
[ -f "$NGINX_FRONT_STAMP" ] || fail "saved nginx front was not recorded"
grep -q '^save$' "$log" || fail "firewall save was not called"
cat > "$bin/netfilter-persistent" <<'EOF'
#!/bin/sh
echo "$*" >> "$IPTABLES_LOG"
exit 1
EOF
chmod 755 "$bin/netfilter-persistent"
rm -f "$NGINX_FRONT_STAMP"
: > "$log"
FIREWALL_UNIT_ENABLED=1 IPTABLES_LOG="$log" PATH="$bin:$PATH" commit_nginx_front || fail "boot service was not enough to keep the firewall rules"
[ -f "$NGINX_FRONT_STAMP" ] || fail "boot service did not record the nginx front"
rm -f "$NGINX_FRONT_STAMP"
if FIREWALL_UNIT_ENABLED=0 IPTABLES_LOG="$log" PATH="$bin:$PATH" commit_nginx_front; then
	fail "commit succeeded without a way to restore rules on boot"
fi
[ ! -f "$NGINX_FRONT_STAMP" ] || fail "failed commit left the nginx front flag"

write_firewall_boot
grep -q 'Before=softether-vpnserver.service' "$FIREWALL_SERVICE_FILE" || fail "boot service does not run before vpnserver"
grep -q 'softether-public' "$FIREWALL_RESTORE_BIN" || fail "boot restore does not allow the public port"
grep -q 'ip6tables -I INPUT 1 -p "$proto" --dport "$PUBLIC".*softether-public' "$FIREWALL_RESTORE_BIN" || fail "boot restore does not allow IPv6"
grep -q 'ip6tables -I INPUT 1 -p udp' "$FIREWALL_RESTORE_BIN" || fail "boot restore does not allow IPv6 UDP"
grep -q 'softether-internal' "$FIREWALL_RESTORE_BIN" || fail "boot restore does not lock the internal port"
printf '1\n' > "$NGINX_FRONT_STAMP"
: > "$log"
IPTABLES_LOG="$log" PATH="$bin:$PATH" sh "$FIREWALL_RESTORE_BIN" || fail "boot restore failed"
grep -q 'iptables -I INPUT 1 -p tcp --dport 8080 .* softether-public' "$log" || fail "boot restore did not allow TCP 8080"
grep -q 'iptables -I INPUT 1 -p udp --dport 8080 .* softether-public' "$log" || fail "boot restore did not allow UDP 8080"
grep -q 'iptables -A INPUT -p tcp --dport 55550 .* softether-internal -j DROP' "$log" || fail "boot restore did not drop outside traffic to 55550"
rm -f "$NGINX_FRONT_STAMP"
: > "$log"
IPTABLES_LOG="$log" PATH="$bin:$PATH" sh "$FIREWALL_RESTORE_BIN" || fail "boot cleanup failed"
grep -q 'iptables -D INPUT -p tcp --dport 8080 .* softether-public' "$log" || fail "boot cleanup left the public port rule"

printf '%s\n' '1194,5555' > "$UDP_PORTS_BACKUP"
[ "$(original_udp_ports)" = "1194,5555" ] || fail "saved UDP ports were not restored"
printf '%s\n' 'not-ports' > "$UDP_PORTS_BACKUP"
[ "$(original_udp_ports)" = "443,992,1194,5555" ] || fail "invalid backup was accepted"
: > "$UDP_PORTS_BACKUP"
[ "$(original_udp_ports)" = "443,992,1194,5555" ] || fail "empty backup was accepted"

oqs="$tmp/oqs"
mkdir -p "$oqs"
(
	cd "$oqs"
	mkdir -p src/Mayaqua/3rdparty/liboqs .git/modules/src/Mayaqua/3rdparty/liboqs
	BUILD_INSTALL_SOURCE_ONLY=1
	# shellcheck disable=SC1091
	. "$ROOT/build-install.sh"
	cd "$oqs"
	remove_incomplete_liboqs
	if [ -d src/Mayaqua/3rdparty/liboqs ]; then
		echo "incomplete liboqs checkout was kept" >&2
		exit 1
	fi
	mkdir -p src/Mayaqua/3rdparty/liboqs
	printf 'ok\n' > src/Mayaqua/3rdparty/liboqs/CMakeLists.txt
	remove_incomplete_liboqs
	if [ ! -f src/Mayaqua/3rdparty/liboqs/CMakeLists.txt ]; then
		echo "complete liboqs checkout was removed" >&2
		exit 1
	fi
) || fail "liboqs cleanup"

echo "ok"
