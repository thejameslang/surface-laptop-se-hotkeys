# Context for Claude Code sessions

Project history and state, so a new session can continue without redoing the
investigation. Last updated 2026-09-18.

## The machine

- Microsoft Surface Laptop SE (Gemini Lake), BIOS 11.6.139.
- Ran Pop!_OS 24.04 with COSMIC (Wayland) on the stock Pop kernel 7.1.5
  (not linux-surface). Secure Boot was off.
- Next OS: **Linux Mint 22.3 Cinnamon** (recommended 2026-09-18; kernel 6.14,
  so the driver works as-is). LMDE 7 (kernel 6.12) would also run the driver,
  and LMDE 6 (kernel 6.1) is too old.
- Why Mint: the owner uses **Citrix Workspace** and **Omnissa Horizon** for
  work. Both vendors test on Ubuntu 24.04 (Mint 22.3's base) and support only
  **X11, not Wayland**. Citrix lists Debian 11/12 only; Horizon lists Ubuntu
  20.04/22.04/24.04 and RHEL 8.10/9.4, with no Debian. COSMIC is Wayland-only.
  Install the vendors' Ubuntu `.deb` packages and use the Cinnamon X11
  session.
- Decision (2026-09-18): Mint 22.3 Cinnamon despite the vendor lists. EPA
  and Citrix Teams optimization also officially list only Ubuntu, but the owner
  has run Citrix (with EPA) and Horizon on Mint and Pop!_OS without problems,
  so their employer's EPA policy doesn't check OS identity.
  Fallback if EPA ever blocks: ask IT about new OS checks, else Ubuntu 24.04
  LTS with the "Ubuntu on Xorg" session. Avoid Ubuntu 26.04 and Wayland
  sessions for these apps.
- Keyboard: plain PS/2, `AT Translated Set 2 keyboard` on i8042. There's no
  Surface Aggregator (SAM), so `surface_aggregator`, `surface_hid` and
  `surface_kbd` are irrelevant. `surface_gpe` logs "no compatible Microsoft
  Surface device found".

## Hotkeys: solved

Volume, brightness and power keys never reach i8042. The EC raises `_Qxx`
queries that `Notify(\_SB.BIND, code)`. `BIND` is `_HID "MSHW0040"`, and no
driver bound it:

- `surfacepro3_button` requires the object name `VGBI` and `_DSM` OEM
  platform revision 0 (UUID 6fd05c69-cde3-49f4-95ed-ab1665498035, rev 1,
  fn 2). This device is named `BIND` and returns `0x4E`.
- `soc_button_array` accepts a nonzero revision but needs GPIOs, and `BIND`
  has no `_CRS`.

Event map, confirmed by EC dynamic-debug traces (`file drivers/acpi/ec.c +p`)
with a different press count per key:

| Key | EC query | Notify |
|---|---|---|
| Vol Up | `_QD1`/`_QD2` | 0xC0/0xC1 |
| Vol Down | `_QD3`/`_QD4` | 0xC2/0xC3 |
| Power | `_QD5`/`_QD6` | 0xC6/0xC7 |
| Bright Up | `_Q16`/`_Q17` | 0xCA/0xCB |
| Bright Down | `_Q1B`/`_Q1C` | 0xCC/0xCD |

The power fixed event was also unhandled
(`No installed handler for fixed event - PowerButton`), so the driver's
KEY_POWER is what makes the power key work.

Fix: `dkms/surface_laptop_se_buttons.c` (v0.3), a platform driver matching
`MSHW0040` with a DMI gate for "Surface Laptop SE". Install with
`sudo bash install.sh`. All five keys tested working: volume and brightness
show the OSD, and a short Power press gets COSMIC's power response
(verified 2026-09-18).

Other keys, handled by atkbd already:
- Mute `e0 20` → KEY_MUTE
- Play/Pause `e0 22` → KEY_PLAYPAUSE
- Search `e0 65` → KEY_SEARCH. It needs a desktop shortcut. On COSMIC the
  owner chose to bind it in Settings → Keyboard → Keyboard Shortcuts →
  Custom; they don't want it scripted.
- Menu (context menu) key: works (verified in Firefox). COSMIC Files ignores
  it, which is a COSMIC limitation (pop-os/cosmic-files#856), not a driver issue.

## Lessons from this project

- **Hold-to-repeat:** the EC sends a true press, then a release on key-up.
  Adding `EV_REP` made the kernel emit repeats (verified in evtest), but
  COSMIC ignores them. libinput drops kernel repeats, and COSMIC doesn't
  repeat volume/brightness shortcuts on any keyboard
  (pop-os/cosmic-epoch#384). That's not a driver bug. The owner declined a
  fake-tap workaround.
- **Power key must never share an input device that has `EV_REP`.** logind
  acts on `value > 0`, so repeats would retrigger the power action. v0.3
  keeps Power on its own device. The upstream patch has no `EV_REP` at all.
- **Driver API history:** `.remove` returns void from 6.11 (`.remove_new`
  before that); `acpi_dev_install_notify_handler` gained a context argument
  in 6.7. v0.3 has an untested fallback for 6.7–6.10.

## Battery charge limit: not available

- `system76-power` says "Not running System76 firmware with charge threshold
  support". BAT1 has no `charge_control_*` files.
- The DSDT device `WSID` (`MSHW0127`) exposes battery protection:
  - `BPMP`: get policy
  - `BPMS`: get status
  - `BPMN`: disable protection
  - `BPMC`: empty stub

  There's no method to set a threshold.
- EC shared memory (EMEM) at 0xFE708000: `BPMS` +0xFC0, `BPRP` +0xFE0
  (set to 0x10 by `EC0._INI`), `BPRS` +0xFE2.
  `tools/read-battery-protection.py` reads these, read-only via /dev/mem.
- Result after a night plugged in (2026-09-17/18): BPMS 0x01, BPRP 0x10,
  BPRS 0x00, and the battery charged to 100%. Protection did not engage.
- Pending: a 3–4 day plugged-in test, and checking Surface UEFI for a
  "Battery Limit" option.
- Do NOT write EC registers or call `BPMN` (undocumented; this is the
  battery charger).

## Open items

- [ ] Kernel patch (`0001-*.patch`, `surfacepro3_button`, checkpatch clean,
      builds against 7.1): replace `YOUR NAME` in Signed-off-by (the owner
      must add it themselves), optionally boot-test a patched kernel, then
      send with the `git send-email` command in the README.
      Uses `Assisted-by: Claude:claude-opus-5` per the kernel's
      coding-assistants.rst.
- [ ] Post `github-issue-767-comment.md` on linux-surface#767. It isn't
      posted yet, and the owner posts it themselves.
- [ ] Repo is private. The owner may make it public for sharing.
- [ ] Battery protection long test (above).
- A published write-up page also exists:
  https://claude.ai/artifact/WF7ZL4q46oEKSZE8WFM9TW (private). Source:
  `where-the-volume-keys-went.html`.

## Useful commands

```sh
sudo evtest                                                    # per-device key events
echo 1 | sudo tee /sys/module/i8042/parameters/debug           # raw i8042 traffic in dmesg
echo 'file drivers/acpi/ec.c +p' | sudo tee /proc/dynamic_debug/control   # log EC queries
sudo acpidump > acpi.dat && acpixtract -a acpi.dat && iasl -d dsdt.dat    # decompile ACPI
readlink /sys/bus/platform/devices/MSHW0040:00/driver          # is the driver bound?
```

Privacy: `i8042.unmask_kbd_data` logs every keystroke. Enable it only
briefly. Don't commit a full `acpidump`: the MSDM table contains the Windows
product key.
