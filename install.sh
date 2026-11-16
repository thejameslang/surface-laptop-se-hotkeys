#!/bin/bash
# Install (or upgrade) the Surface Laptop SE hotkey driver with DKMS.
# Usage: sudo bash install.sh
set -e
N=surface_laptop_se_buttons
SRC="$(dirname "$(readlink -f "$0")")/dkms"
V=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$SRC/dkms.conf")

# Check everything before removing anything.
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
[ -n "$V" ] || { echo "Could not read PACKAGE_VERSION from $SRC/dkms.conf."; exit 1; }
command -v dkms >/dev/null || { echo "Install dkms and kernel headers first (see README)."; exit 1; }
KBUILD="/lib/modules/$(uname -r)/build"
[ -d "$KBUILD" ] || {
	echo "No kernel headers for the running kernel ($(uname -r)): $KBUILD is missing."
	echo "Install them first (see README)."
	exit 1
}

# Remove any previously installed version: every version DKMS knows about
# (dkms status), plus any leftover source folders in /usr/src.
# dkms status prints "name/version, kernel, arch: state" (DKMS 3) or
# "name, version, kernel, arch: state" (DKMS 2). Either way, take the version.
rmmod $N 2>/dev/null || true
old_versions=$(
	{
		dkms status 2>/dev/null | sed -n -E "s#^$N(/|, )([^,:]+).*#\2#p"
		for old in /usr/src/$N-*; do
			[ -d "$old" ] && echo "${old##*/$N-}"
		done
	} | sort -u
)
for ov in $old_versions; do
	dkms remove -m $N -v "$ov" --all 2>/dev/null || true
	rm -rf "/usr/src/$N-$ov"
done

mkdir -p /usr/src/$N-$V
cp "$SRC"/{surface_laptop_se_buttons.c,Makefile,dkms.conf} /usr/src/$N-$V/
dkms add -m $N -v "$V"
dkms install -m $N -v "$V"

if ! modprobe $N; then
	if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
		# DKMS signed the module, but the firmware doesn't trust the key yet.
		mok=
		for k in /var/lib/shim-signed/mok/MOK.der /var/lib/dkms/mok.pub; do
			[ -f "$k" ] && { mok=$k; break; }
		done
		echo
		echo ">>> $N $V is built and installed, but Secure Boot is on and the module"
		echo "    can't load until you enrol the key DKMS signed it with."
		if [ -n "$mok" ]; then
			echo "    Run this, set a one-time password when asked, and reboot:"
			echo "      sudo mokutil --import $mok"
			echo "    On the blue MOK Manager screen choose Enroll MOK -> Continue -> Yes,"
			echo "    then enter that password. See \"With Secure Boot on\" in the README."
		else
			echo "    No signing key was found in /var/lib/shim-signed/mok/ or /var/lib/dkms/."
			echo "    See \"With Secure Boot on\" in the README for where your distro keeps it."
		fi
		exit 0
	fi
	echo "modprobe $N failed. Check: dmesg | tail"
	exit 1
fi

dkms status $N
grep -E 'N: Name="Surface Laptop SE' /proc/bus/input/devices ||
	echo "Warning: the module loaded but no Surface Laptop SE input device appeared. Is this a Surface Laptop SE? Check: dmesg | grep -i $N"
echo ">>> Installed $N $V. It loads at boot and rebuilds on kernel updates."
