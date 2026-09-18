## Root cause found + working fix (DKMS module)

I tracked this down on a Surface Laptop SE (BIOS 11.6.139) running kernel 7.1.

**TL;DR:** these keys don't go through the keyboard. The EC reports them as ACPI notifications on `\_SB.BIND` (`_HID "MSHW0040"`), and no driver binds that device on the Laptop SE, so the events are silently dropped. The Laptop SE has no SAM, so `surface_aggregator` / `surface_hid` don't apply. The keyboard is a plain i8042 PS/2 device.

### Evidence

- evtest on the `AT Translated Set 2 keyboard` shows nothing for vol/brightness, and with `i8042.debug=1` they don't raise **any** i8042 interrupt. Fn+key gives plain F-keys. So a hwdb remap can't help.
- EC query trace (`echo 'file drivers/acpi/ec.c +p' > /proc/dynamic_debug/control`) shows one query per press and one per release:

| Key | EC query | DSDT action |
|---|---|---|
| Volume Up | `_QD1` / `_QD2` | `Notify (BIND, 0xC0 / 0xC1)` |
| Volume Down | `_QD3` / `_QD4` | `Notify (BIND, 0xC2 / 0xC3)` |
| Power | `_QD5` / `_QD6` | `Notify (BIND, 0xC6 / 0xC7)` |
| Brightness Up | `_Q16` / `_Q17` | `Notify (BIND, 0xCA / 0xCB)` |
| Brightness Down | `_Q1B` / `_Q1C` | `Notify (BIND, 0xCC / 0xCD)` |

- `MSHW0040:00` has no driver bound. Both candidate drivers reject it:
  - `surfacepro3_button`: the object is named `BIND`, not `VGBI`, **and** `_DSM` (`6fd05c69-cde3-49f4-95ed-ab1665498035`, rev 1, fn 2) returns OEM platform revision `0x4E`. The driver only accepts revision 0 (Pro 4 / Book 1).
  - `soc_button_array`: passes the revision check but `BIND` has no `_CRS`/GPIOs, so it fails with "no GPIO attached".
- Side effect: the power key is affected too (`ACPI Error: No installed handler for fixed event - PowerButton (2), disabling`).

Mute (`e0 20`), Play/Pause (`e0 22`) and Search (`e0 65` → `KEY_SEARCH`) are ordinary PS/2 keys and already work at the kernel level. Search may just need a shortcut bound in your DE.

### Workaround: out-of-tree module

A small platform driver that binds MSHW0040, only on DMI "Surface Laptop SE". The EC sends real press/release events (a held key stays pressed until you let go). Whether holding repeats is then up to your desktop. COSMIC currently doesn't repeat volume/brightness shortcuts on any keyboard (pop-os/cosmic-epoch#384). Needs kernel 6.7 or newer. With Secure Boot enabled the module must be signed with an enrolled MOK (Ubuntu/Mint DKMS does the signing; you enroll the key once).

```sh
sudo mkdir -p /usr/src/surface_laptop_se_buttons-0.3
# put the three files below in that directory, then:
sudo dkms install -m surface_laptop_se_buttons -v 0.3
sudo modprobe surface_laptop_se_buttons
```

<details><summary><code>surface_laptop_se_buttons.c</code></summary>

```c
// SPDX-License-Identifier: GPL-2.0-only
/*
 * Hotkey support for the Microsoft Surface Laptop SE.
 *
 * The EC reports volume, brightness and power keys as ACPI notifications on
 * \_SB.BIND (MSHW0040). This device has neither the "VGBI" name nor the zero
 * OEM platform revision that surfacepro3_button requires, and it has no GPIOs
 * for soc_button_array, so without this driver the events are dropped.
 *
 * See https://github.com/linux-surface/linux-surface/issues/767
 */

#include <linux/acpi.h>
#include <linux/dmi.h>
#include <linux/input.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/version.h>

#define SLSE_NOTIFY_PRESS_VOLUME_UP		0xc0
#define SLSE_NOTIFY_RELEASE_VOLUME_UP		0xc1
#define SLSE_NOTIFY_PRESS_VOLUME_DOWN		0xc2
#define SLSE_NOTIFY_RELEASE_VOLUME_DOWN		0xc3
#define SLSE_NOTIFY_PRESS_POWER			0xc6
#define SLSE_NOTIFY_RELEASE_POWER		0xc7
#define SLSE_NOTIFY_PRESS_BRIGHTNESS_UP		0xca
#define SLSE_NOTIFY_RELEASE_BRIGHTNESS_UP	0xcb
#define SLSE_NOTIFY_PRESS_BRIGHTNESS_DOWN	0xcc
#define SLSE_NOTIFY_RELEASE_BRIGHTNESS_DOWN	0xcd

static const struct dmi_system_id slse_dmi_table[] = {
	{
		.matches = {
			DMI_EXACT_MATCH(DMI_SYS_VENDOR, "Microsoft Corporation"),
			DMI_EXACT_MATCH(DMI_PRODUCT_NAME, "Surface Laptop SE"),
		},
	},
	{ }
};

/*
 * The EC only sends one press and one release per keystroke, so the hotkeys
 * rely on software autorepeat. The power key lives on a separate input device
 * without autorepeat, as logind acts on every repeat event of KEY_POWER.
 */
struct slse_buttons {
	struct input_dev *hotkeys;
	struct input_dev *power;
};

static void slse_notify(acpi_handle handle, u32 event, void *data)
{
	struct device *dev = data;
	struct slse_buttons *buttons = dev_get_drvdata(dev);
	struct input_dev *input = buttons->hotkeys;
	unsigned int key_code;
	bool pressed = !(event & 1);	/* even = press, odd = release */

	switch (event) {
	case SLSE_NOTIFY_PRESS_VOLUME_UP:
	case SLSE_NOTIFY_RELEASE_VOLUME_UP:
		key_code = KEY_VOLUMEUP;
		break;
	case SLSE_NOTIFY_PRESS_VOLUME_DOWN:
	case SLSE_NOTIFY_RELEASE_VOLUME_DOWN:
		key_code = KEY_VOLUMEDOWN;
		break;
	case SLSE_NOTIFY_PRESS_POWER:
	case SLSE_NOTIFY_RELEASE_POWER:
		key_code = KEY_POWER;
		input = buttons->power;
		break;
	case SLSE_NOTIFY_PRESS_BRIGHTNESS_UP:
	case SLSE_NOTIFY_RELEASE_BRIGHTNESS_UP:
		key_code = KEY_BRIGHTNESSUP;
		break;
	case SLSE_NOTIFY_PRESS_BRIGHTNESS_DOWN:
	case SLSE_NOTIFY_RELEASE_BRIGHTNESS_DOWN:
		key_code = KEY_BRIGHTNESSDOWN;
		break;
	default:
		dev_info_ratelimited(dev, "Unsupported event [0x%x]\n", event);
		return;
	}

	if (pressed && key_code == KEY_POWER)
		pm_wakeup_dev_event(dev, 0, true);

	input_report_key(input, key_code, pressed);
	input_sync(input);
}

static int slse_probe(struct platform_device *pdev)
{
	struct acpi_device *adev = ACPI_COMPANION(&pdev->dev);
	struct slse_buttons *buttons;
	struct input_dev *input;
	int error;

	if (!adev || !dmi_check_system(slse_dmi_table))
		return -ENODEV;

	buttons = devm_kzalloc(&pdev->dev, sizeof(*buttons), GFP_KERNEL);
	if (!buttons)
		return -ENOMEM;

	input = devm_input_allocate_device(&pdev->dev);
	if (!input)
		return -ENOMEM;

	input->name = "Surface Laptop SE Buttons";
	input->phys = "MSHW0040/buttons";
	input->id.bustype = BUS_HOST;
	__set_bit(EV_REP, input->evbit);
	input_set_capability(input, EV_KEY, KEY_VOLUMEUP);
	input_set_capability(input, EV_KEY, KEY_VOLUMEDOWN);
	input_set_capability(input, EV_KEY, KEY_BRIGHTNESSUP);
	input_set_capability(input, EV_KEY, KEY_BRIGHTNESSDOWN);

	error = input_register_device(input);
	if (error)
		return error;
	buttons->hotkeys = input;

	input = devm_input_allocate_device(&pdev->dev);
	if (!input)
		return -ENOMEM;

	input->name = "Surface Laptop SE Power Button";
	input->phys = "MSHW0040/power";
	input->id.bustype = BUS_HOST;
	input_set_capability(input, EV_KEY, KEY_POWER);

	error = input_register_device(input);
	if (error)
		return error;
	buttons->power = input;

	platform_set_drvdata(pdev, buttons);
	device_init_wakeup(&pdev->dev, true);

	error = acpi_dev_install_notify_handler(adev, ACPI_DEVICE_NOTIFY,
						slse_notify, &pdev->dev);
	if (error) {
		device_init_wakeup(&pdev->dev, false);
		return error;
	}

	dev_info(&pdev->dev, "Surface Laptop SE buttons [%s]\n",
		 acpi_device_bid(adev));
	return 0;
}

static void slse_remove(struct platform_device *pdev)
{
	acpi_dev_remove_notify_handler(ACPI_COMPANION(&pdev->dev),
				       ACPI_DEVICE_NOTIFY, slse_notify);
	device_init_wakeup(&pdev->dev, false);
}

static const struct acpi_device_id slse_acpi_ids[] = {
	{ "MSHW0040", 0 },
	{ }
};
MODULE_DEVICE_TABLE(acpi, slse_acpi_ids);

static struct platform_driver slse_driver = {
	.probe = slse_probe,
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 11, 0)
	.remove_new = slse_remove,
#else
	.remove = slse_remove,
#endif
	.driver = {
		.name = "surface_laptop_se_buttons",
		.acpi_match_table = slse_acpi_ids,
	},
};
module_platform_driver(slse_driver);

MODULE_DESCRIPTION("Surface Laptop SE hotkey driver");
MODULE_LICENSE("GPL");
```
</details>

<details><summary><code>Makefile</code> and <code>dkms.conf</code></summary>

```make
obj-m += surface_laptop_se_buttons.o
```

```sh
PACKAGE_NAME="surface_laptop_se_buttons"
PACKAGE_VERSION="0.3"
BUILT_MODULE_NAME[0]="surface_laptop_se_buttons"
DEST_MODULE_LOCATION[0]="/updates/dkms"
MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
AUTOINSTALL="yes"
```
</details>

Tested on Pop!_OS (COSMIC, kernel 7.1.5): volume up/down, brightness up/down and power all work, and the OSD shows.

### Upstream

I've prepared a patch that adds Laptop SE support (and the brightness events) to `surfacepro3_button` for platform-driver-x86, and will link it here once it's on the list.
