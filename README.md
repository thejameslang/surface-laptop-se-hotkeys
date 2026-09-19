# Surface Laptop SE hotkeys on Linux

Fixes the volume, brightness and power keys on the Microsoft Surface Laptop SE
([linux-surface#767](https://github.com/linux-surface/linux-surface/issues/767)).

The keyboard controller never sees these keys. The embedded controller sends
them as ACPI notifications to `\_SB.BIND` (`MSHW0040`), and no kernel driver
binds that device on the Laptop SE: `surfacepro3_button` rejects it (object
name isn't `VGBI`, and its `_DSM` reports OEM revision `0x4E`), and
`soc_button_array` rejects it (no GPIOs). So every keypress is dropped. This
repo has a small driver that binds the device and turns the notifications
into key events.

The full investigation is written up in
[`where-the-volume-keys-went.html`](where-the-volume-keys-went.html).

| Key | EC query | Notify code (press / release) | Key event |
|---|---|---|---|
| Volume Up | `_QD1` / `_QD2` | `0xC0` / `0xC1` | `KEY_VOLUMEUP` |
| Volume Down | `_QD3` / `_QD4` | `0xC2` / `0xC3` | `KEY_VOLUMEDOWN` |
| Power | `_QD5` / `_QD6` | `0xC6` / `0xC7` | `KEY_POWER` |
| Brightness Up | `_Q16` / `_Q17` | `0xCA` / `0xCB` | `KEY_BRIGHTNESSUP` |
| Brightness Down | `_Q1B` / `_Q1C` | `0xCC` / `0xCD` | `KEY_BRIGHTNESSDOWN` |

## Install

Needs kernel 6.11 or newer. It was tested on 7.1.5. Kernels 6.7–6.10 are
covered by a compatibility fallback that hasn't been tested.

1. Install DKMS and the headers for your running kernel:

   | Distro | Command |
   |---|---|
   | Pop!_OS, Ubuntu, Mint, LMDE, Debian | `sudo apt install dkms linux-headers-$(uname -r)` |
   | Fedora | `sudo dnf install dkms kernel-devel` |
   | Arch | `sudo pacman -S dkms linux-headers` |

2. Clone this repo and run the installer:

   ```sh
   git clone https://github.com/thejameslang/surface-laptop-se-hotkeys
   cd surface-laptop-se-hotkeys
   sudo bash install.sh
   ```

The module loads at boot, and DKMS rebuilds it on every kernel update. The
installer also removes any older version it finds.

### With Secure Boot on

The module has to be signed with a Machine Owner Key (MOK) that you enrol
once. DKMS generates the key and signs the module. Enrol it with:

```sh
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der   # Ubuntu, Pop!_OS, Mint (skip if the installer prompted you)
sudo mokutil --import /var/lib/dkms/mok.pub              # Debian, LMDE
```

Reboot, choose **Enroll MOK → Continue → Yes** on the blue MOK Manager
screen, and enter the password you set.

### Uninstall

```sh
sudo modprobe -r surface_laptop_se_buttons
sudo dkms remove -m surface_laptop_se_buttons -v 0.3 --all
sudo rm -rf /usr/src/surface_laptop_se_buttons-0.3
```

## Notes

- **Search key:** it already works in the kernel (`e0 65` → `KEY_SEARCH`).
  Bind it to something in your desktop's keyboard shortcut settings. On
  COSMIC, that's Settings → Keyboard → Keyboard Shortcuts → Custom.
- **Holding a key doesn't repeat on COSMIC.** That's a COSMIC limitation on
  every keyboard
  ([cosmic-epoch#384](https://github.com/pop-os/cosmic-epoch/issues/384)),
  not this driver.
- **No charge limit setting.** The firmware has no charge threshold that
  Linux can set, so desktop settings like Pop!_OS's 80% limit don't appear.
  The embedded controller has a built-in battery protection policy (`0x10`, set
  at boot), but the OS can only read its state or turn it off. In testing it
  didn't engage after a night plugged in. Check it with
  `sudo python3 tools/read-battery-protection.py`.

## Files

| Path | What it is |
|---|---|
| `CLAUDE.md` | Project context and open items for future Claude Code sessions |
| `dkms/` | Driver source, `Makefile`, `dkms.conf` |
| `install.sh` | DKMS installer and upgrader |
| `tools/capture-keys.sh` | Records evtest, EC queries, i8042 and ACPI events while you press keys, to diagnose hotkeys (needs sudo) |
| `evidence/` | Trimmed logs from the investigation (key events, EC traces, driver test, battery registers) |
| `tools/read-battery-protection.py` | Read-only check of the embedded controller's battery-protection registers (needs sudo) |
| `0001-platform-surface-surfacepro3_button-Add-support-for-.patch` | Upstream kernel patch that adds Laptop SE support to `surfacepro3_button`. Passes `checkpatch.pl`; not yet sent. |
| `github-issue-767-comment.md` | Draft comment for linux-surface#767 |
| `where-the-volume-keys-went.html` | Write-up of the investigation |
| `dsdt-surface-laptop-se.dsl` | Decompiled DSDT. EC `_Qxx` methods are near line 5070, the `BIND` device near line 7260. |

## Sending the kernel patch

Replace `YOUR NAME` in the `Signed-off-by:` line, then:

```sh
git send-email \
  --to="Chen Yu <yu.c.chen@intel.com>" \
  --to="Hans de Goede <hansg@kernel.org>" \
  --to="Ilpo Järvinen <ilpo.jarvinen@linux.intel.com>" \
  --to="Maximilian Luz <luzmaximilian@gmail.com>" \
  --cc=platform-driver-x86@vger.kernel.org \
  --cc=linux-kernel@vger.kernel.org \
  0001-platform-surface-surfacepro3_button-Add-support-for-.patch
```
