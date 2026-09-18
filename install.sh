#!/bin/bash
# Install (or upgrade) the Surface Laptop SE hotkey driver with DKMS.
# Usage: sudo bash install.sh
set -e
N=surface_laptop_se_buttons
SRC="$(dirname "$(readlink -f "$0")")/dkms"
V=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$SRC/dkms.conf")

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
command -v dkms >/dev/null || { echo "Install dkms and kernel headers first (see README)."; exit 1; }

# Remove any previously installed version
rmmod $N 2>/dev/null || true
for old in /usr/src/$N-*; do
	[ -d "$old" ] || continue
	ov=${old##*/$N-}
	dkms remove -m $N -v "$ov" --all 2>/dev/null || true
	rm -rf "$old"
done

mkdir -p /usr/src/$N-$V
cp "$SRC"/{surface_laptop_se_buttons.c,Makefile,dkms.conf} /usr/src/$N-$V/
dkms add -m $N -v "$V"
dkms install -m $N -v "$V"
modprobe $N
dkms status $N
grep -E 'N: Name="Surface Laptop SE' /proc/bus/input/devices
echo ">>> Installed $N $V. It loads at boot and rebuilds on kernel updates."
