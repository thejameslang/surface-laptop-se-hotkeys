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

1. Install DKMS and the kernel headers:

   | Distro | Command |
   |---|---|
   | Debian, LMDE | `sudo apt install dkms linux-headers-amd64` |
   | Ubuntu, Pop!_OS | `sudo apt install dkms linux-headers-generic` |
   | Mint 22.0, 22.1 | `sudo apt install dkms linux-headers-generic` |
   | Mint 22.2, 22.3 | `sudo apt install dkms linux-headers-generic-hwe-24.04` |
   | Fedora | `sudo dnf install dkms kernel-devel-$(uname -r) kernel-devel` |
   | Arch | `sudo pacman -S dkms linux-headers` |

   These packages follow your kernel, so each kernel update also installs
   matching headers. DKMS needs those to rebuild the module for the new kernel.
   Headers for only the running kernel (`linux-headers-$(uname -r)`) would
   leave the next kernel without any, and the hotkeys would stop working after
   the update.

   On Ubuntu and Mint, the headers package has to match the kernel package you
   have. Mint 22.2 and 22.3 use the HWE kernel, so they need
   `linux-headers-generic-hwe-24.04`, while Mint 22.0 and 22.1 use
   `linux-headers-generic`. The pairs are
   `linux-image-generic-hwe-24.04` with `linux-headers-generic-hwe-24.04`, and
   `linux-image-generic` with `linux-headers-generic`. To see which you have,
   run `dpkg -l 'linux-image-generic*'`. If the headers are missing, `install.sh`
   works this out and prints the command. For another kernel flavour
   (lowlatency, LTS and so on), install the headers package for that flavour.
   On Fedora,
   `kernel-devel-$(uname -r)` covers the kernel you're running now, and
   `kernel-devel` covers the ones that follow.

2. Clone this repo and run the installer:

   ```sh
   git clone https://github.com/thejameslang/surface-laptop-se-hotkeys
   cd surface-laptop-se-hotkeys
   sudo bash install.sh
   ```

The module loads at boot, and DKMS rebuilds it on every kernel update. The
installer builds the new version first and only then removes any older one. If
you're upgrading from a different version and the build fails, the driver you
already have stays installed. If you're reinstalling the same version, that
version has to be removed first so it rebuilds cleanly, so a failed build
leaves you without it.

### With Secure Boot on

The module has to be signed with a Machine Owner Key (MOK) that you enrol
once. DKMS generates the key and signs the module. If the module can't load
because of Secure Boot, `install.sh` prints the right command for the key it
finds and stops. Otherwise, enrol the key yourself:

```sh
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der   # Ubuntu, Pop!_OS, Mint (skip if you already set a MOK password, see below)
sudo mokutil --import /var/lib/dkms/mok.pub              # Debian, LMDE, Fedora, Arch
```

Reboot, choose **Enroll MOK → Continue → Yes** on the blue MOK Manager
screen, and enter the password you set.

"Already set a MOK password" means Ubuntu's `update-secureboot-policy` asked you
for one. apt shows that prompt when it installs `dkms` or `shim-signed`, and
DKMS shows it the first time it has to create a signing key, which can happen
while `install.sh` runs `dkms`. `install.sh` has no password prompt of its own.

- **Fedora:** `/var/lib/dkms/mok.pub` is DKMS's default key location, which
  DKMS creates the first time it builds a module. I haven't tested this on
  Fedora.
- **Arch:** Arch doesn't set up Secure Boot signing for you, and most Arch
  Secure Boot setups don't use shim, so there may be no MOK Manager to enrol
  into. `/var/lib/dkms/mok.pub` is the key to enrol if you do use shim.
  Otherwise, turn Secure Boot off, or point DKMS at a key your setup already
  trusts with `mok_signing_key` and `mok_certificate` in
  `/etc/dkms/framework.conf`. I haven't tested this on Arch.
- **Kernel lockdown:** with Secure Boot on, the kernel locks down `/dev/mem`.
  `tools/read-battery-protection.py` reads it, so it fails there. Turn Secure
  Boot off to use it.

### Uninstall

Do this too once you run a kernel whose `surfacepro3_button` supports the
Laptop SE. Both drivers match `MSHW0040`, so you don't want both.

```sh
sudo modprobe -r surface_laptop_se_buttons
sudo dkms remove -m surface_laptop_se_buttons -v 0.4 --all
sudo rm -rf /usr/src/surface_laptop_se_buttons-0.4
```

## Notes

- **Search key:** it already works in the kernel (`e0 65` → `KEY_SEARCH`).
  Bind it to something in your desktop's keyboard shortcut settings. On
  COSMIC, that's Settings → Keyboard → Keyboard Shortcuts → Custom.
- **Holding a key doesn't repeat on COSMIC.** That's a COSMIC limitation on
  every keyboard
  ([cosmic-epoch#384](https://github.com/pop-os/cosmic-epoch/issues/384)),
  not this driver.
- **Wake from sleep:** only the Power key wakes the laptop. Volume and
  brightness presses while it's asleep are ignored on purpose, so a laptop in a
  bag doesn't wake up when something presses its keys. This differs from the
  upstream `surfacepro3_button` driver, which wakes on any key. The suspend and
  wake code hasn't been tested on the hardware yet.
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
| `0001-platform-surface-surfacepro3_button-Add-support-for-.patch` | Upstream kernel patch that adds Laptop SE support to `surfacepro3_button`. Passes `checkpatch.pl --strict` apart from the missing `Signed-off-by`. Not yet sent: it still needs `git commit --amend -s` and a test-apply on pdx86 `for-next` (see below). |
| `github-issue-767-comment.md` | Draft comment for linux-surface#767 |
| `where-the-volume-keys-went.html` | Write-up of the investigation |
| `dsdt-surface-laptop-se.dsl` | Decompiled DSDT. EC `_Qxx` methods are near line 5070, the `BIND` device near line 7260. |

## Sending the kernel patch

The patch has no `Signed-off-by:` line, and its author is set to the repo
owner's git identity. Before sending it:

1. Apply it to a checkout of the pdx86 `for-next` branch
   (`platform-drivers-x86` on git.kernel.org) with `git am`, and fix anything
   that doesn't apply. It was written against upstream commit `5798b46271e2`,
   and it no longer applies to current Linux master, because
   `57de5fb31981` changed the surrounding lines.
2. Add the sign-off with `git commit --amend -s`.
3. Regenerate the file with `git format-patch -1`.

Then send it:

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
