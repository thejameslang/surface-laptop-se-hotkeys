#!/bin/bash
# Install (or upgrade) the Surface Laptop SE hotkey driver with DKMS.
# Usage: sudo bash install.sh
# The new version is built first. If the build fails, the driver you already
# have installed is left alone.
set -e
N=surface_laptop_se_buttons
SRC="$(dirname "$(readlink -f "$0")")/dkms"
V=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$SRC/dkms.conf")

# Check everything before changing anything.
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
[ -n "$V" ] || { echo "Could not read PACKAGE_VERSION from $SRC/dkms.conf."; exit 1; }
command -v dkms >/dev/null || { echo "Install dkms and kernel headers first (see README)."; exit 1; }
KBUILD="/lib/modules/$(uname -r)/build"
[ -d "$KBUILD" ] || {
	echo "No kernel headers for the running kernel ($(uname -r)): $KBUILD is missing."
	echo "Install them first (see README)."
	exit 1
}

# Every version of this driver that DKMS or /usr/src knows about.
# dkms status prints "name/version, kernel, arch: state" (DKMS 3) or
# "name, version, kernel, arch: state" (DKMS 2). Either way, take the version.
old_versions=$(
	{
		dkms status 2>/dev/null | sed -n -E "s#^$N(/|, )([^,:]+).*#\2#p"
		for old in /usr/src/$N-*; do
			[ -d "$old" ] && echo "${old##*/$N-}"
		done
	} | sort -u
)
same_registered=0
others=
for ov in $old_versions; do
	if [ "$ov" = "$V" ]; then
		same_registered=1
	else
		others="$others $ov"
	fi
done

# 1. Stage and build the new version. Other versions stay installed for now.
if [ "$same_registered" = 1 ]; then
	echo "==> Version $V is already registered. Removing just that version so it rebuilds cleanly..."
	dkms remove -m $N -v "$V" --all 2>/dev/null || true
fi
mkdir -p /usr/src/$N-$V
cp "$SRC"/{surface_laptop_se_buttons.c,Makefile,dkms.conf} /usr/src/$N-$V/
dkms add -m $N -v "$V"
if ! dkms build -m $N -v "$V"; then
	echo
	log=/var/lib/dkms/$N/$V/build/make.log
	[ -f "$log" ] && { echo "Last lines of $log:"; tail -n 20 "$log"; echo; }
	# Put things back the way they were: don't leave the failed version registered.
	dkms remove -m $N -v "$V" --all 2>/dev/null || true
	rm -rf "/usr/src/$N-$V"
	if [ "$same_registered" = 1 ]; then
		echo "Build failed. Version $V had to be removed to rebuild it, so no driver is installed now."
		echo "A module that is already loaded keeps working until you reboot."
	elif [ -n "$others" ]; then
		echo "Build failed; your existing driver is still installed"
	else
		echo "Build failed; nothing was installed."
	fi
	exit 1
fi

# 2. The build worked. Now remove the other versions and switch over.
for ov in $others; do
	dkms remove -m $N -v "$ov" --all 2>/dev/null || true
	rm -rf "/usr/src/$N-$ov"
done
dkms install -m $N -v "$V" || { echo "dkms install failed."; exit 1; }
rmmod $N 2>/dev/null || true

if ! modprobe $N; then
	if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
		# Which certificate does DKMS sign with? A mok_certificate set in
		# /etc/dkms/framework.conf (or framework.conf.d) wins. The ${kernelver}
		# placeholder DKMS allows in it is replaced here.
		mok=$(sed -n -E "s/^[[:space:]]*mok_certificate=[\"']?([^\"']*)[\"']?.*/\1/p" \
			/etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf 2>/dev/null | tail -n 1)
		mok=${mok//'${kernelver}'/$(uname -r)}
		mok=${mok//'$kernelver'/$(uname -r)}
		if [ -z "$mok" ] || [ ! -f "$mok" ]; then
			mok=
			for k in /var/lib/shim-signed/mok/MOK.der /var/lib/dkms/mok.pub; do
				[ -f "$k" ] && { mok=$k; break; }
			done
		fi
		echo
		echo ">>> $N $V is built and installed, but it isn't loaded."
		if [ -z "$mok" ]; then
			echo "    Secure Boot is on, but no DKMS signing key was found (looked in"
			echo "    /etc/dkms/framework.conf, /var/lib/shim-signed/mok/ and /var/lib/dkms/)."
			echo "    See \"With Secure Boot on\" in the README."
			exit 1
		fi
		# mokutil --test-key exits 0 if the key is enrolled, 1 if it isn't,
		# and something else if it can't tell (unreadable or invalid file).
		rc=0
		mokutil --test-key "$mok" >/dev/null 2>&1 || rc=$?
		case "$rc" in
		0)
			echo "    Secure Boot is on, but $mok is already enrolled,"
			echo "    so the key isn't what's blocking it. Look at: dmesg | tail"
			;;
		1)
			echo "    Secure Boot is on and $mok isn't enrolled yet."
			echo "    Run this, set a one-time password when asked, and reboot:"
			echo "      sudo mokutil --import $mok"
			echo "    On the blue MOK Manager screen choose Enroll MOK -> Continue -> Yes,"
			echo "    then enter that password. If you already did this, reboot and finish it."
			echo "    See \"With Secure Boot on\" in the README."
			;;
		*)
			echo "    Secure Boot is on, but mokutil couldn't check $mok."
			echo "    If the key isn't enrolled, run: sudo mokutil --import $mok"
			echo "    Otherwise look at: dmesg | tail"
			;;
		esac
		exit 1
	fi
	echo "modprobe $N failed. Check: dmesg | tail"
	exit 1
fi

dkms status $N
grep -E 'N: Name="Surface Laptop SE' /proc/bus/input/devices ||
	echo "Warning: the module loaded but no Surface Laptop SE input device appeared. Is this a Surface Laptop SE? Check: dmesg | grep -i $N"
echo ">>> Installed $N $V. It loads at boot and rebuilds on kernel updates."
