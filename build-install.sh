#!/bin/sh
# Build and install SoftEther VPN on the machine running this script.
# Native Ubuntu/Debian and RHEL builds for aarch64 (ARM64) and x86_64 use the
# same commands. Run the script on the target machine; it does not cross-compile.
# After install it configures kernel NAT. Set SKIP_GATEWAY=1 to skip that.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$ROOT"

if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
else
	SUDO="sudo"
fi

arch=$(uname -m)
case "$arch" in
	aarch64|arm64)
		arch_kind="ARM64"
		;;
	arm|armv6l|armv7l|armv8l|armhf)
		arch_kind="ARM (32-bit)"
		;;
	x86_64|amd64|i386|i686)
		arch_kind="x86"
		;;
	*)
		echo "Unsupported architecture: ${arch}" >&2
		echo "Run this script on an ARM64, 32-bit ARM, or x86 machine." >&2
		exit 1
		;;
esac

echo "Building SoftEther VPN for ${arch_kind} (${arch})"

install_dependencies() {
	if command -v apt-get >/dev/null 2>&1; then
		$SUDO apt-get update
		$SUDO apt-get install -y \
			cmake gcc g++ make pkgconf git \
			libncurses5-dev libssl-dev libsodium-dev libreadline-dev zlib1g-dev
	elif command -v dnf >/dev/null 2>&1; then
		$SUDO dnf -y install \
			cmake gcc gcc-c++ make pkgconf-pkg-config git \
			ncurses-devel openssl-devel libsodium-devel readline-devel zlib-devel
	elif command -v yum >/dev/null 2>&1; then
		$SUDO yum -y groupinstall "Development Tools"
		$SUDO yum -y install \
			cmake ncurses-devel openssl-devel libsodium-devel readline-devel zlib-devel git
	else
		echo "No apt-get, dnf, or yum found. Install cmake, gcc, g++, make, git, ncurses, OpenSSL, libsodium, readline, and zlib, then re-run." >&2
		exit 1
	fi
}

install_dependencies

if [ -d .git ]; then
	git submodule update --init --recursive
fi

./configure
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
make -C build -j"$jobs"
$SUDO make -C build install

if [ "${SKIP_GATEWAY:-}" = "1" ]; then
	echo "Installed SoftEther VPN (${arch_kind}). Skipped gateway setup."
	echo "Start the server with: vpnserver start"
else
	$SUDO sh "$ROOT/setup-fast-gateway.sh"
fi
