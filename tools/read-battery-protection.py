#!/usr/bin/env python3
"""Show the Surface Laptop SE's battery-protection state (read-only).

The embedded controller keeps its battery-protection registers in a
shared-memory window at 0xFE708000 (DSDT: EC0 OperationRegion EMEM).
Only reads are done here, one byte at a time like the firmware's own
ByteAcc field. Needs root: sudo python3 read-battery-protection.py

  BPMS  mode: 2 means protection is on (WSID.BPMN turns it off)
  BPRP  policy: EC0._INI sets 0x10 at boot
  BPRS  status bits, as decoded by WSID.BPMS
"""
import mmap
import os

BASE = 0xFE708000
REGS = {
    "BPMS (mode, 2 = protection on)": 0xFC0,
    "BPRP (policy)": 0xFE0,
    "BPRS (status bits)": 0xFE2,
}
BAT = "/sys/class/power_supply/BAT1/"

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
for name, off in REGS.items():
    val = mm[off]
    print(f"{name:32s} 0x{val:02X}  (bits {val:08b})")
mm.close()
os.close(fd)

with open(BAT + "status") as s, open(BAT + "capacity") as c:
    print(f"battery: {s.read().strip()}, {c.read().strip()}%")
