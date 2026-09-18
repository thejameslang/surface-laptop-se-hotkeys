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
