#!/bin/bash
# Record everything a keypress does, to find where a hotkey disappears.
# Usage: sudo bash capture-keys.sh [seconds] [output-dir]
# Captures evtest on every input device, EC query debug messages, i8042
# interrupt traffic and acpi_listen, then restores the debug settings.
# Raw keyboard bytes are NOT unmasked (that would log passwords); set
# /sys/module/i8042/parameters/unmask_kbd_data yourself if you need them.
set -u
SECS=${1:-25}
OUT=${2:-./key-capture-$(date +%Y%m%d-%H%M%S)}
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
command -v evtest >/dev/null || apt-get install -y evtest acpid
mkdir -p "$OUT"
DD=/proc/dynamic_debug/control

systemctl start acpid 2>/dev/null
echo 1 > /sys/module/i8042/parameters/debug
echo 'file drivers/acpi/ec.c +p' > $DD
for e in /dev/input/event*; do
	timeout "$SECS" evtest "$e" > "$OUT/evtest-$(basename "$e").log" 2>&1 &
done
command -v acpi_listen >/dev/null && timeout "$SECS" acpi_listen > "$OUT/acpi_listen.log" 2>&1 &
timeout "$SECS" dmesg -w > "$OUT/dmesg.log" 2>&1 &

echo ">>> Recording for $SECS s. Press each key a different number of times"
echo "    (key 1 once, key 2 twice, ...) with pauses, so the logs can be matched up."
wait

echo 0 > /sys/module/i8042/parameters/debug
echo 'file drivers/acpi/ec.c -p' > $DD
[ -n "${SUDO_UID:-}" ] && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT"

echo ">>> Summary"
echo "EC queries:";  grep -oE 'Query\(0x[0-9a-f]+\) started' "$OUT/dmesg.log" | sort | uniq -c
echo "Key events:";  grep -h 'EV_KEY' "$OUT"/evtest-*.log | grep -oE '\(KEY_[A-Z0-9_]+\), value [01]' | sort | uniq -c
echo "Unknown keys:"; grep -c 'Unknown key' "$OUT/dmesg.log"
echo ">>> Logs in $OUT"
