#!/bin/sh
# Checks uninstall helpers without touching a live server.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

INSTALL_PREFIX="$tmp/usr"
LIBEXEC_DIR="$tmp/libexec/softether"
STATE_DIR="$tmp/state/softether"
SYSCTL_FILE="$tmp/99-softether.conf"
DNSMASQ_FILE="$tmp/softether-tap.conf"
NGINX_CONF="$tmp/nginx.conf"
NGINX_STREAM_DIR="$tmp/stream.d"
NGINX_LEGACY_STREAM="$tmp/stream-softether.conf"
NGINX_FRONT_STAMP="$STATE_DIR/nginx-front"
UFW_SYSCTL="$tmp/ufw-sysctl.conf"
UNINSTALL_SKIP_SYSCTL=1
UNINSTALL_SOURCE_ONLY=1
# shellcheck disable=SC1091
. "$ROOT/uninstall.sh"

sample='Status: active
     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 8080/tcp                   ALLOW IN    Anywhere
[ 5] 18080/tcp                  ALLOW IN    Anywhere
[ 3] 55550/tcp                  DENY IN     Anywhere
[12] Anywhere on tap_soft       ALLOW IN    Anywhere
[13] Anywhere on tap_soft0      ALLOW IN    Anywhere
[ 4] 40000:44999/udp            ALLOW IN    Anywhere'
got=$(printf '%s\n' "$sample" | ufw_rule_numbers '8080')
[ "$got" = "2" ] || fail "public port rule number was [$got]"
got=$(printf '%s\n' "$sample" | ufw_rule_numbers 'tap_soft')
[ "$got" = "12" ] || fail "tap rule number was [$got]"
got=$(printf '%s\n' "$sample" | ufw_rule_numbers '5555')
[ -z "$got" ] || fail "5555 matched the internal port [$got]"
got=$(printf '%s\n' "$sample" | ufw_rule_numbers '40000:44999')
[ "$got" = "4" ] || fail "acceleration rule number was [$got]"

bin="$tmp/bin"
log="$tmp/iptables.log"
mkdir -p "$bin"
cat > "$bin/iptables" <<'EOF'
#!/bin/sh
echo "$*" >> "$IPTABLES_LOG"
if [ "$1" = "-t" ] && [ "$3" = "-S" ]; then
	printf '%s\n' \
		'-P INPUT ACCEPT' \
		'-A INPUT -p tcp --dport 22 -j ACCEPT' \
		'-A INPUT -p tcp --dport 8080 -m comment --comment softether-public -j ACCEPT' \
		'-A FORWARD -i tap_soft -m comment --comment softether-fwd -j ACCEPT'
fi
exit 0
EOF
chmod 755 "$bin/iptables"
: > "$log"
IPTABLES_LOG="$log" PATH="$bin:$PATH" delete_softether_rules iptables filter
grep -q -- '-D INPUT -p tcp --dport 8080' "$log" || fail "public rule was not deleted"
grep -q -- '-D FORWARD -i tap_soft' "$log" || fail "forward rule was not deleted"
if grep -q -- '-D INPUT -p tcp --dport 22' "$log"; then
	fail "an unrelated firewall rule was deleted"
fi
PATH="$tmp/missing" delete_softether_rules iptables filter

cat > "$bin/ufw" <<'EOF'
#!/bin/sh
echo "$*" >> "$UFW_LOG"
if [ "$1" = "route" ] && [ "$2" = "status" ]; then
	printf '%s\n' '[ 1] Anywhere on ens5 ALLOW FWD Anywhere on tap_soft' '[ 2] Anywhere on tap_soft ALLOW FWD Anywhere on ens5' '[ 3] Anywhere on tap_soft0 ALLOW FWD Anywhere on ens5'
	exit 0
fi
if [ "$1" = "--force" ] && [ "$2" = "route" ]; then
	exit 0
fi
exit 1
EOF
chmod 755 "$bin/ufw"
: > "$log"
UFW_LOG="$log" PATH="$bin:$PATH" ufw_delete_exact allow 8080/tcp
grep -q -- '--force delete allow 8080/tcp' "$log" || fail "public UFW rule was not deleted"
if grep -q '18080' "$log"; then
	fail "UFW deleted a different port that only contains 8080"
fi
: > "$log"
UFW_LOG="$log" PATH="$bin:$PATH" delete_ufw_matching tap_soft route
grep -q -- '--force route delete 1' "$log" || fail "first routed TAP rule was not deleted"
grep -q -- '--force route delete 2' "$log" || fail "second routed TAP rule was not deleted"
if grep -q -- '--force route delete 3' "$log"; then
	fail "UFW deleted a different interface that only contains tap_soft"
fi

mkdir -p "$NGINX_STREAM_DIR" "$STATE_DIR" "$(dirname "$LIBEXEC_DIR")" "$INSTALL_PREFIX/bin" "$INSTALL_PREFIX/lib"
printf 'listen 8080;\n' > "$NGINX_STREAM_DIR/softether.conf"
printf 'legacy\n' > "$NGINX_LEGACY_STREAM"
printf '%s\n' 'events {}' 'stream {' '    include /etc/nginx/other.conf;' '    include /etc/nginx/stream.d/*.conf; # softether-stream' '}' > "$NGINX_CONF"
remove_nginx_stream
[ ! -f "$NGINX_STREAM_DIR/softether.conf" ] || fail "stream server file was kept"
[ ! -f "$NGINX_LEGACY_STREAM" ] || fail "legacy stream file was kept"
grep -q 'other.conf' "$NGINX_CONF" || fail "existing nginx stream config was removed"
if grep -q 'softether-stream' "$NGINX_CONF"; then
	fail "nginx stream include was left in place"
fi

printf '%s\n' 'events {}' '# softether-stream-begin' 'stream { broken' '# softether-stream-end' > "$NGINX_CONF"
cat > "$bin/nginx" <<'EOF'
#!/bin/sh
if [ "$1" = "-t" ]; then
	exit 1
fi
exit 0
EOF
chmod 755 "$bin/nginx"
saved=$(cat "$NGINX_CONF")
PATH="$bin:$PATH" remove_nginx_stream
PATH="$bin:$PATH" reload_nginx_if_needed
[ "$(cat "$NGINX_CONF")" = "$saved" ] || fail "rejected nginx config was not restored"

printf '1\n' > "$SYSCTL_FILE"
printf '1\n' > "$DNSMASQ_FILE"
printf '1\n' > "$NGINX_FRONT_STAMP"
printf 'bin\n' > "$INSTALL_PREFIX/bin/vpnserver"
printf 'lib\n' > "$INSTALL_PREFIX/lib/libcedar.a"
mkdir -p "$LIBEXEC_DIR"
printf 'cfg\n' > "$LIBEXEC_DIR/vpn_server.config"
remove_installed_files
[ ! -e "$SYSCTL_FILE" ] || fail "sysctl file was kept"
[ ! -e "$DNSMASQ_FILE" ] || fail "dnsmasq file was kept"
[ ! -e "$STATE_DIR" ] || fail "state directory was kept"
[ ! -e "$LIBEXEC_DIR" ] || fail "installed binaries were kept"
[ ! -e "$INSTALL_PREFIX/bin/vpnserver" ] || fail "vpnserver command was kept"
[ ! -e "$INSTALL_PREFIX/lib/libcedar.a" ] || fail "cedar library was kept"

if remove_tree "$tmp/not-softether"; then
	fail "uninstall agreed to remove an unrelated directory"
fi

printf '%s\n' '# keep' 'net/ipv4/ip_forward=1' > "$UFW_SYSCTL"
restore_forwarding
grep -q '^#net/ipv4/ip_forward=1$' "$UFW_SYSCTL" || fail "ufw forwarding line was left enabled"
if grep -q '^net/ipv4/ip_forward=1$' "$UFW_SYSCTL"; then
	fail "ufw forwarding line was not commented out"
fi
printf '%s\n' 'net/ipv4/ip_forward=0' > "$UFW_SYSCTL"
restore_forwarding
grep -q '^net/ipv4/ip_forward=0$' "$UFW_SYSCTL" || fail "an existing forwarding disable was rewritten"

echo "ok"
