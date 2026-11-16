#!/bin/bash
# Install (or upgrade) the Surface Laptop SE hotkey driver with DKMS.
# Usage: sudo bash install.sh
#
# The new version is built before anything is removed. If you are upgrading
# from a different version and the build fails, the driver you have installed
# is left alone. If you are reinstalling the same version, that version has to
# be removed first so it rebuilds cleanly, so a failed build leaves you
# without it.
set -e
N=surface_laptop_se_buttons
SRC="$(dirname "$(readlink -f "$0")")/dkms"
V=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$SRC/dkms.conf")
KERNEL=$(uname -r)

# Print the command that installs headers matching the kernel packages in use.
# Ubuntu and Mint can run either the plain or the HWE kernel, and the headers
# metapackage has to match (linux-image-generic-hwe-24.04 needs
# linux-headers-generic-hwe-24.04).
headers_hint() {
	local pkg=
	if ! command -v dpkg-query >/dev/null; then
		echo "see the README for your distro"
		return
	fi
	# shellcheck disable=SC2016  # ${...} is dpkg-query's format, not ours
	pkg=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-generic-hwe-*' 2>/dev/null |
		awk '$1 == "ii" { print $2; exit }')
	if [ -n "$pkg" ]; then
		echo "sudo apt install linux-headers-${pkg#linux-image-}"
	elif dpkg-query -W -f='${db:Status-Abbrev}\n' linux-image-generic 2>/dev/null | grep -q '^ii'; then
		echo "sudo apt install linux-headers-generic"
	elif dpkg-query -W -f='${db:Status-Abbrev}\n' linux-image-amd64 2>/dev/null | grep -q '^ii'; then
		echo "sudo apt install linux-headers-amd64"
	else
		echo "sudo apt install linux-headers-$KERNEL"
	fi
}

# Check everything before changing anything.
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
[ -n "$V" ] || { echo "Could not read PACKAGE_VERSION from $SRC/dkms.conf."; exit 1; }
command -v dkms >/dev/null || { echo "Install dkms and kernel headers first (see README)."; exit 1; }
KBUILD="/lib/modules/$KERNEL/build"
[ -d "$KBUILD" ] || {
	echo "No kernel headers for the running kernel ($KERNEL): $KBUILD is missing."
	echo "Install them with: $(headers_hint)"
	echo "Then run this again."
	exit 1
}

# Every version of this driver that DKMS or /usr/src knows about.
# dkms status prints "name/version, kernel, arch: state" (DKMS 3) or
# "name, version, kernel, arch: state" (DKMS 2). Either way, take the version.
dkms_status=$(dkms status 2>/dev/null || true)
old_versions=$(
	{
		echo "$dkms_status" | sed -n -E "s#^$N(/|, )([^,:]+).*#\2#p"
		for old in /usr/src/$N-*; do
			[ -d "$old" ] && echo "${old##*/$N-}"
		done
	} | sort -u
)
# Only the versions DKMS reports as installed for the running kernel are a
# driver you can actually use. The rest may just be added or built.
installed_here=$(
	echo "$dkms_status" |
		sed -n -E "s#^$N(/|, )([^,:]+), ([^,:]+), [^:]*: installed.*#\2 \3#p" |
		while read -r ver kern; do
			if [ "$kern" = "$KERNEL" ]; then
				echo "$ver"
			fi
		done
)
same_registered=0
v_was_installed=0
others=
others_installed=
for ov in $old_versions; do
	if [ "$ov" = "$V" ]; then
		same_registered=1
	else
		others="$others $ov"
	fi
done
for iv in $installed_here; do
	if [ "$iv" = "$V" ]; then
		v_was_installed=1
	else
		others_installed="$others_installed $iv"
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
rc=0
dkms build -m $N -v "$V" || rc=$?
if [ "$rc" -ne 0 ]; then
	echo
	log=/var/lib/dkms/$N/$V/build/make.log
	if [ "$rc" != 77 ] && [ -f "$log" ]; then
		echo "Last lines of $log:"
		tail -n 20 "$log"
		echo
	fi
	# Put things back the way they were: don't leave the failed version registered.
	dkms remove -m $N -v "$V" --all 2>/dev/null || true
	rm -rf "/usr/src/$N-$V"
	if [ "$rc" = 77 ]; then
		# DKMS exits 77 when BUILD_EXCLUSIVE_KERNEL_MIN skips this kernel.
		echo "Kernel $KERNEL is older than 6.7, which this driver doesn't support. Nothing was built."
	elif [ -n "$others_installed" ]; then
		echo "Build failed; your existing driver is still installed"
	elif [ "$same_registered" = 1 ] && [ "$v_was_installed" = 1 ]; then
		echo "Build failed. Version $V had to be removed to rebuild it, so no driver is installed now."
		echo "A module that is already loaded keeps working until you reboot."
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
if ! dkms install -m $N -v "$V"; then
	echo
	echo "dkms install failed. No driver is installed now."
	[ -n "$others" ] && echo "The older version(s) (${others# }) were already removed."
	echo "A module that is already loaded keeps working until you reboot."
	echo "To recover, fix the error above and run this again: sudo bash install.sh"
	echo "(To go back to an earlier version, run install.sh from that version of this repo.)"
	exit 1
fi
rmmod $N 2>/dev/null || true

# Reads the value of mok_certificate from the DKMS framework config. The last
# assignment wins. A quoted value ends at its closing quote, and an unquoted
# one at the first whitespace, so trailing comments and spaces never get in.
read_mok_certificate() {
	local line v last=
	while IFS= read -r line; do
		if [[ $line =~ ^[[:space:]]*mok_certificate=[[:space:]]*(.*)$ ]]; then
			v=${BASH_REMATCH[1]}
			if [[ $v =~ ^\"([^\"]*)\" ]]; then
				v=${BASH_REMATCH[1]}
			elif [[ $v =~ ^\'([^\']*)\' ]]; then
				v=${BASH_REMATCH[1]}
			else
				v=${v%%[[:space:]]*}
			fi
			last=$v
		fi
	done < <(cat /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf 2>/dev/null)
	echo "$last"
}

if ! modprobe $N; then
	if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
		# Which certificate does DKMS sign with? A mok_certificate set in
		# /etc/dkms/framework.conf (or framework.conf.d) wins. The ${kernelver}
		# placeholder DKMS allows in it is replaced here.
		mok=$(read_mok_certificate)
		mok=${mok//'${kernelver}'/$KERNEL}
		mok=${mok//'$kernelver'/$KERNEL}
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
		# Read what mokutil says instead of its exit code: the exit code of
		# --test-key differs between mokutil versions and distro patches.
		out=$(mokutil --test-key "$mok" 2>&1 || true)
		case "$out" in
		*"is already enrolled"*)
			echo "    Secure Boot is on, but $mok is already enrolled,"
			echo "    so the key isn't what's blocking it. Look at: dmesg | tail"
			;;
		*"is not enrolled"*)
			echo "    Secure Boot is on and $mok isn't enrolled yet."
			echo "    Run this, set a one-time password when asked, and reboot:"
			echo "      sudo mokutil --import $mok"
			echo "    On the blue MOK Manager screen choose Enroll MOK -> Continue -> Yes,"
			echo "    then enter that password. See \"With Secure Boot on\" in the README."
			;;
		*"enrollment request"*)
			echo "    A request to enrol $mok is already queued."
			echo "    Reboot, and on the blue MOK Manager screen choose"
			echo "    Enroll MOK -> Continue -> Yes, then enter the password you set."
			;;
		*)
			echo "    Secure Boot is on, but I couldn't tell whether $mok is enrolled."
			echo "    mokutil --test-key said:"
			echo "$out" | sed 's/^/      /'
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
