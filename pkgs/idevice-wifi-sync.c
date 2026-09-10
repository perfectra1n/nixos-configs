/*
 * idevice-wifi-sync — flip the one lockdown key that makes an iPhone reachable over Wi-Fi.
 *
 * WHY THIS EXISTS: libimobiledevice's own tools cannot SET a lockdown value in a named
 * domain (ideviceinfo is get-only), and every guide that says `idevicepair wifi on` is
 * wrong — that subcommand has never existed in any release, upstream or fork; it exits
 * "Invalid command" non-fatally, which is why the myth survives. The only other CLI that
 * can do this is pymobiledevice3, whose pyimg4 dependency genuinely breaks against
 * asn1 3.x. So we make the single call ourselves: the same lockdownd_set_value() that
 * upstream's idevicename.c uses for DeviceName, aimed at the wireless_lockdown domain.
 *
 * The key is what Finder exposes as "Show this iPhone when on Wi-Fi". Without it the phone
 * never advertises _apple-mobdev2._tcp, so usbmuxd2 cannot discover it and the nightly job
 * in modules/ios-backup.nix polls `idevice_id -n` until it gives up — every night, forever,
 * while USB backups keep working fine. That asymmetry makes it a confusing thing to debug,
 * hence a dedicated tool rather than a documented manual step.
 *
 * Exit: 0 = enabled (or set as asked), 1 = disabled/unset (status only), 2 = error.
 */
/* nanosleep() is POSIX, not ISO C — needed explicitly because we build with -std=c11. */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>

#define WL_DOMAIN "com.apple.mobile.wireless_lockdown"
#define WL_KEY    "EnableWifiConnections"

static void usage(const char *me)
{
	fprintf(stderr,
		"Usage: %s <on|off|status> [-u UDID]\n"
		"\n"
		"Enable, disable, or report iOS Wi-Fi lockdown connections\n"
		"(%s / %s) — what Finder calls\n"
		"\"Show this iPhone when on Wi-Fi\".\n"
		"\n"
		"Requires a USB pairing first (idevicepair pair). The setting lives on the\n"
		"device and persists across reboots, so this is a once-per-device operation.\n"
		"\n"
		"Exit: 0 = enabled, 1 = disabled/unset (status), 2 = error.\n",
		me, WL_DOMAIN, WL_KEY);
}

/*
 * Current value: 1 = on, 0 = off, -1 = absent/unreadable. An absent key means the same
 * thing in practice as false, but it is reported distinctly so `status` can say "unset"
 * instead of implying somebody deliberately turned it off.
 */
static int read_flag(lockdownd_client_t client)
{
	plist_t node = NULL;
	int out = -1;

	if (lockdownd_get_value(client, WL_DOMAIN, WL_KEY, &node) != LOCKDOWN_E_SUCCESS || !node)
		return -1;

	if (plist_get_node_type(node) == PLIST_BOOLEAN) {
		uint8_t v = 0;
		plist_get_bool_val(node, &v);
		out = v ? 1 : 0;
	}
	plist_free(node);
	return out;
}

static const char *lockdown_hint(lockdownd_error_t err)
{
	switch (err) {
	case LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING:
		return " — unlock the phone and accept the Trust dialog";
	case LOCKDOWN_E_USER_DENIED_PAIRING:
		return " — Trust was declined on the device";
	case LOCKDOWN_E_INVALID_HOST_ID:
		return " — device is paired, but not with this host; run: idevicepair pair";
	case LOCKDOWN_E_MISSING_PAIR_RECORD:
		return " — not paired at all; plug in over USB and run: idevicepair pair";
	case LOCKDOWN_E_PASSWORD_PROTECTED:
		return " — the device is locked; unlock it and retry";
	default:
		return "";
	}
}

int main(int argc, char **argv)
{
	const char *udid = NULL;
	const char *cmd = NULL;
	int want;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-u") || !strcmp(argv[i], "--udid")) {
			if (++i >= argc) {
				fprintf(stderr, "ERROR: -u needs a UDID\n");
				return 2;
			}
			udid = argv[i];
		} else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			usage(argv[0]);
			return 0;
		} else if (!cmd) {
			cmd = argv[i];
		} else {
			fprintf(stderr, "ERROR: unexpected argument '%s'\n", argv[i]);
			return 2;
		}
	}

	if (!cmd) {
		usage(argv[0]);
		return 2;
	}
	if (!strcmp(cmd, "on"))
		want = 1;
	else if (!strcmp(cmd, "off"))
		want = 0;
	else if (!strcmp(cmd, "status"))
		want = -1;
	else {
		fprintf(stderr, "ERROR: unknown command '%s'\n", cmd);
		usage(argv[0]);
		return 2;
	}

	/*
	 * Prefer USB (the default when both are offered): enabling this key over the network
	 * is impossible on a device that does not have it yet, and USB is where pairing lives
	 * anyway. NETWORK is still included so `status` works against an already-enabled phone
	 * that is not plugged in — which is exactly what ios:status wants to check.
	 */
	idevice_t device = NULL;
	idevice_error_t ierr = idevice_new_with_options(&device, udid,
		IDEVICE_LOOKUP_USBMUX | IDEVICE_LOOKUP_NETWORK);
	if (ierr != IDEVICE_E_SUCCESS) {
		fprintf(stderr, "ERROR: no device found%s%s (idevice error %d)\n",
			udid ? " with udid " : "", udid ? udid : "", (int)ierr);
		return 2;
	}

	lockdownd_client_t client = NULL;
	lockdownd_error_t lerr =
		lockdownd_client_new_with_handshake(device, &client, "idevice-wifi-sync");
	if (lerr != LOCKDOWN_E_SUCCESS) {
		fprintf(stderr, "ERROR: lockdown handshake failed (error %d)%s\n",
			(int)lerr, lockdown_hint(lerr));
		idevice_free(device);
		return 2;
	}

	int rc = 2;
	int current = read_flag(client);

	if (want < 0) {
		printf("%s\n", current == 1 ? "on" : current == 0 ? "off" : "unset");
		rc = (current == 1) ? 0 : 1;
	} else if (current == want) {
		/* Idempotent: ios:pair re-runs this, and a no-op must not look like a failure. */
		printf("already %s\n", want ? "on" : "off");
		rc = 0;
	} else {
		/* set_value takes ownership of the plist, as in upstream's idevicename.c. */
		lerr = lockdownd_set_value(client, WL_DOMAIN, WL_KEY,
			plist_new_bool((uint8_t)want));
		if (lerr != LOCKDOWN_E_SUCCESS) {
			fprintf(stderr, "ERROR: could not set %s/%s (lockdown error %d)%s\n",
				WL_DOMAIN, WL_KEY, (int)lerr, lockdown_hint(lerr));
		} else {
			/*
			 * Verify, because a write that reports success but does not stick (seen on
			 * supervised/MDM-restricted devices) would strand the nightly job in
			 * permanent DISCOVERY-TIMEOUT while this tool claimed it had worked. One
			 * retry covers lockdownd taking a moment to settle the preference.
			 */
			int now = read_flag(client);
			if (now != want) {
				struct timespec ts = { .tv_sec = 0, .tv_nsec = 300000000L };
				nanosleep(&ts, NULL);
				now = read_flag(client);
			}
			if (now != want) {
				fprintf(stderr,
					"ERROR: device accepted the write but %s is still %s"
					" — is this device supervised/MDM-restricted?\n",
					WL_KEY, now == 1 ? "on" : now == 0 ? "off" : "unset");
			} else {
				printf("%s -> %s\n", WL_KEY, want ? "on" : "off");
				rc = 0;
			}
		}
	}

	lockdownd_client_free(client);
	idevice_free(device);
	return rc;
}
