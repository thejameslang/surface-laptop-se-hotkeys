#!/bin/bash
# Record everything a keypress does, to find where a hotkey disappears.
# Usage: sudo bash capture-keys.sh [seconds] [output-dir]
#
# WARNING: this logs EVERY key pressed while it runs. evtest records the key
# names from every input device, including the keyboard, so anything you type
# during the capture (passwords included) ends up in the log files. Only press
# the keys you're testing, and delete the output folder when you're done.
# The i8042 raw data stays masked (unmask_kbd_data is left alone), but that
# does not hide the key names evtest records.
#
# Captures evtest on every input device, EC query debug messages, i8042
# interrupt traffic and acpi_listen. The debug settings are put back when it
# finishes, and also if you press Ctrl+C.
set -u
SECS=${1:-25}
OUT=${2:-./key-capture-$(date +%Y%m%d-%H%M%S)}
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }

# Offer to install missing tools instead of doing it silently.
missing=
command -v evtest >/dev/null || missing="evtest"
command -v acpi_listen >/dev/null || missing="$missing acpid"
if [ -n "$missing" ]; then
	echo "Missing packages:$missing"
	command -v apt-get >/dev/null || { echo "Install them with your package manager, then run this again."; exit 1; }
	read -r -p "Install with apt-get now? [y/N] " answer
	case "$answer" in
	[yY]*) apt-get install -y $missing ;;
	*) echo "Not installing. Without evtest there is nothing to record."; command -v evtest >/dev/null || exit 1 ;;
	esac
fi

echo "!!! Every key you press during the next $SECS seconds will be written to"
echo "!!! the logs in $OUT, including anything you type. Don't type passwords."
if [ -t 0 ]; then
	read -r -p "Press Enter to start, or Ctrl+C to cancel. "
fi

mkdir -p "$OUT"
DD=/proc/dynamic_debug/control
I8042=/sys/module/i8042/parameters/debug
prev_i8042=$(cat "$I8042" 2>/dev/null || echo 0)
started_acpid=0

# Put the debug settings back on exit, Ctrl+C or kill.
cleanup() {
	trap - EXIT INT TERM
	kill $(jobs -p) 2>/dev/null
	echo "$prev_i8042" > "$I8042" 2>/dev/null
	echo 'file drivers/acpi/ec.c -p' > "$DD" 2>/dev/null
	[ "$started_acpid" = 1 ] && systemctl stop acpid 2>/dev/null
	[ -n "${SUDO_UID:-}" ] && [ -d "$OUT" ] && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT"
}
trap cleanup EXIT
trap 'echo; echo ">>> Interrupted. Restoring debug settings."; exit 130' INT TERM

if ! systemctl is-active --quiet acpid 2>/dev/null; then
	systemctl start acpid 2>/dev/null && started_acpid=1
fi
echo 1 > "$I8042"
echo 'file drivers/acpi/ec.c +p' > "$DD"
for e in /dev/input/event*; do
	timeout "$SECS" evtest "$e" > "$OUT/evtest-$(basename "$e").log" 2>&1 &
done
command -v acpi_listen >/dev/null && timeout "$SECS" acpi_listen > "$OUT/acpi_listen.log" 2>&1 &
timeout "$SECS" dmesg -W > "$OUT/dmesg.log" 2>&1 &

echo ">>> Recording for $SECS s. Press each key a different number of times"
echo "    (key 1 once, key 2 twice, ...) with pauses, so the logs can be matched up."
wait

cleanup

echo ">>> Summary"
echo "EC queries:";  grep -oE 'Query\(0x[0-9a-f]+\) started' "$OUT/dmesg.log" | sort | uniq -c
echo "Key events:";  grep -h 'EV_KEY' "$OUT"/evtest-*.log | grep -oE '\(KEY_[A-Z0-9_]+\), value [01]' | sort | uniq -c
echo "Unknown keys:"; grep -c 'Unknown key' "$OUT/dmesg.log"
echo ">>> Logs in $OUT (they contain every key you pressed; delete them when done)"
